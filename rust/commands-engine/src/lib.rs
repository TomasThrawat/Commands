use jni::objects::{JClass, JString};
use jni::sys::{jboolean, jlong, jstring, JNI_FALSE, JNI_TRUE};
use jni::JNIEnv;
use serde::Serialize;
use std::collections::HashSet;
use std::io::Read;
use std::process::{Child, Command, ExitStatus, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{mpsc, Arc, Mutex, MutexGuard, OnceLock};
use std::thread;
use std::time::Duration;

const MAX_OUTPUT_BYTES: usize = 256 * 1024;
const READER_GRACE_PERIOD: Duration = Duration::from_secs(1);

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ExecutionResult {
    stdout: String,
    stderr: String,
    exit_code: i32,
    cancelled: bool,
}

struct ActiveCommand {
    id: i64,
    cancelled: Arc<AtomicBool>,
    child: Arc<Mutex<Option<Child>>>,
}

#[derive(Default)]
struct EngineState {
    active: Option<ActiveCommand>,
    pending_cancellations: HashSet<i64>,
    last_completed_command_id: Option<i64>,
}

static ENGINE: OnceLock<Mutex<EngineState>> = OnceLock::new();

fn engine() -> &'static Mutex<EngineState> {
    ENGINE.get_or_init(|| Mutex::new(EngineState::default()))
}

fn lock_engine() -> MutexGuard<'static, EngineState> {
    engine().lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

fn lock_child(child: &Mutex<Option<Child>>) -> MutexGuard<'_, Option<Child>> {
    child.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

#[derive(Default)]
struct OutputCapture {
    bytes: Vec<u8>,
    truncated: bool,
}

impl OutputCapture {
    fn push(&mut self, data: &[u8]) {
        let remaining = MAX_OUTPUT_BYTES.saturating_sub(self.bytes.len());
        let keep = data.len().min(remaining);
        self.bytes.extend_from_slice(&data[..keep]);
        if keep < data.len() {
            self.truncated = true;
        }
    }

    fn snapshot(&self) -> String {
        let mut value = String::from_utf8_lossy(&self.bytes).into_owned();
        if self.truncated {
            value.push_str("\n[output truncated at 256 KiB]");
        }
        value
    }
}

fn start_collector<R>(mut reader: R) -> (Arc<Mutex<OutputCapture>>, mpsc::Receiver<()>)
where
    R: Read + Send + 'static,
{
    let capture = Arc::new(Mutex::new(OutputCapture::default()));
    let reader_capture = Arc::clone(&capture);
    let (done_tx, done_rx) = mpsc::channel();

    thread::spawn(move || {
        let mut buffer = [0_u8; 8192];
        loop {
            match reader.read(&mut buffer) {
                Ok(0) => break,
                Ok(read) => {
                    let mut output = reader_capture
                        .lock()
                        .unwrap_or_else(|poisoned| poisoned.into_inner());
                    output.push(&buffer[..read]);
                }
                Err(_) => break,
            }
        }
        let _ = done_tx.send(());
    });

    (capture, done_rx)
}

fn snapshot(capture: &Mutex<OutputCapture>) -> String {
    capture
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .snapshot()
}

fn finish_command(command_id: i64) {
    let mut state = lock_engine();
    if state.active.as_ref().map(|active| active.id) == Some(command_id) {
        state.active = None;
    }
    state.pending_cancellations.remove(&command_id);
    state.last_completed_command_id = Some(command_id);
}

fn kill_child(child: &Arc<Mutex<Option<Child>>>) {
    if let Some(process) = lock_child(child).as_mut() {
        let _ = process.kill();
    }
}

fn cancel_command(command_id: i64) -> bool {
    if command_id <= 0 {
        return false;
    }

    let child_to_kill = {
        let mut state = lock_engine();
        let active_matches = state.active.as_ref().map(|active| active.id) == Some(command_id);
        if active_matches {
            let active = state.active.as_ref().expect("active command was just checked");
            active.cancelled.store(true, Ordering::Release);
            Some(Arc::clone(&active.child))
        } else if state.last_completed_command_id == Some(command_id) {
            return false;
        } else {
            state.pending_cancellations.insert(command_id);
            return true;
        }
    };

    if let Some(child) = child_to_kill {
        kill_child(&child);
    }
    true
}

fn destroy_engine() {
    let child_to_kill = {
        let state = lock_engine();
        state.active.as_ref().map(|active| {
            active.cancelled.store(true, Ordering::Release);
            Arc::clone(&active.child)
        })
    };

    if let Some(child) = child_to_kill {
        kill_child(&child);
    }
}

fn shell_path() -> &'static str {
    if cfg!(target_os = "android") {
        "/system/bin/sh"
    } else {
        "/bin/sh"
    }
}

fn cancelled_result() -> ExecutionResult {
    ExecutionResult {
        stdout: String::new(),
        stderr: String::new(),
        exit_code: -1,
        cancelled: true,
    }
}

fn run_command(command: &str, command_id: i64) -> Result<ExecutionResult, String> {
    if command.trim().is_empty() {
        return Err("Command is empty.".to_owned());
    }
    if command_id <= 0 {
        return Err("Invalid command ID.".to_owned());
    }

    let (cancelled, child_slot) = {
        let mut state = lock_engine();
        if state.active.is_some() {
            return Err("Another command is already running.".to_owned());
        }

        let cancelled = Arc::new(AtomicBool::new(
            state.pending_cancellations.remove(&command_id),
        ));
        let child_slot = Arc::new(Mutex::new(None));
        state.active = Some(ActiveCommand {
            id: command_id,
            cancelled: Arc::clone(&cancelled),
            child: Arc::clone(&child_slot),
        });
        (cancelled, child_slot)
    };

    if cancelled.load(Ordering::Acquire) {
        finish_command(command_id);
        return Ok(cancelled_result());
    }

    let command_path = if cfg!(target_os = "android") {
        "/system/bin:/system/xbin:/vendor/bin:/vendor/xbin".to_owned()
    } else {
        std::env::var("PATH").unwrap_or_default()
    };

    let mut process = Command::new(shell_path());
    process
        .arg("-c")
        .arg(command)
        .env("PATH", command_path)
        .env("LC_ALL", "C")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());

    let mut child = match process.spawn() {
        Ok(child) => child,
        Err(error) => {
            finish_command(command_id);
            return Err(format!("Unable to start shell: {error}"));
        }
    };

    let stdout = child.stdout.take().expect("stdout pipe was configured");
    let stderr = child.stderr.take().expect("stderr pipe was configured");
    let (stdout_capture, stdout_done) = start_collector(stdout);
    let (stderr_capture, stderr_done) = start_collector(stderr);

    {
        let mut slot = lock_child(&child_slot);
        *slot = Some(child);
    }

    if cancelled.load(Ordering::Acquire) {
        kill_child(&child_slot);
    }

    let wait_result: Result<ExitStatus, String> = loop {
        if cancelled.load(Ordering::Acquire) {
            kill_child(&child_slot);
        }

        let status = {
            let mut slot = lock_child(&child_slot);
            match slot.as_mut() {
                Some(child) => child.try_wait(),
                None => break Err("Command process was lost.".to_owned()),
            }
        };

        match status {
            Ok(Some(status)) => break Ok(status),
            Ok(None) => thread::sleep(Duration::from_millis(20)),
            Err(error) => break Err(format!("Unable to wait for shell: {error}")),
        }
    };

    if wait_result.is_err() {
        kill_child(&child_slot);
        if let Some(child) = lock_child(&child_slot).as_mut() {
            let _ = child.wait();
        }
    }

    // A detached child can inherit the output pipes. Do not make completion wait forever.
    let _ = stdout_done.recv_timeout(READER_GRACE_PERIOD);
    let _ = stderr_done.recv_timeout(READER_GRACE_PERIOD);

    let stdout = snapshot(&stdout_capture);
    let stderr = snapshot(&stderr_capture);
    let was_cancelled = cancelled.load(Ordering::Acquire);

    lock_child(&child_slot).take();
    finish_command(command_id);

    let status = wait_result?;
    Ok(ExecutionResult {
        stdout,
        stderr,
        exit_code: if was_cancelled {
            -1
        } else {
            status.code().unwrap_or(-1)
        },
        cancelled: was_cancelled,
    })
}

fn json_result(result: Result<ExecutionResult, String>) -> String {
    match result {
        Ok(result) => serde_json::to_string(&result)
            .unwrap_or_else(|_| r#"{"error":"Unable to serialize command result."}"#.to_owned()),
        Err(error) => serde_json::json!({ "error": error }).to_string(),
    }
}

fn new_java_string<'local>(env: &mut JNIEnv<'local>, value: String) -> jstring {
    match env.new_string(value) {
        Ok(value) => value.into_raw(),
        Err(_) => std::ptr::null_mut(),
    }
}

#[no_mangle]
pub extern "system" fn Java_com_hyouka_commands_CommandUserService_nativeExecute<'local>(
    mut env: JNIEnv<'local>,
    _class: JClass<'local>,
    command: JString<'local>,
    command_id: jlong,
) -> jstring {
    let command = match env.get_string(&command) {
        Ok(value) => value.to_string_lossy().into_owned(),
        Err(error) => {
            return new_java_string(
                &mut env,
                json_result(Err(format!("Unable to read command string: {error}"))),
            );
        }
    };

    new_java_string(&mut env, json_result(run_command(&command, command_id)))
}

#[no_mangle]
pub extern "system" fn Java_com_hyouka_commands_CommandUserService_nativeCancel<'local>(
    _env: JNIEnv<'local>,
    _class: JClass<'local>,
    command_id: jlong,
) -> jboolean {
    if cancel_command(command_id) {
        JNI_TRUE
    } else {
        JNI_FALSE
    }
}

#[no_mangle]
pub extern "system" fn Java_com_hyouka_commands_CommandUserService_nativeDestroy<'local>(
    _env: JNIEnv<'local>,
    _class: JClass<'local>,
) {
    destroy_engine();
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex as TestMutex;

    static TEST_LOCK: TestMutex<()> = TestMutex::new(());

    #[test]
    fn captures_stdout_stderr_and_exit_code() {
        let _guard = TEST_LOCK.lock().unwrap();
        let result = run_command("printf 'out'; printf 'err' >&2; exit 7", 101).unwrap();
        assert_eq!(result.stdout, "out");
        assert_eq!(result.stderr, "err");
        assert_eq!(result.exit_code, 7);
        assert!(!result.cancelled);
    }

    #[test]
    fn cancellation_can_arrive_before_execution() {
        let _guard = TEST_LOCK.lock().unwrap();
        assert!(cancel_command(102));
        let result = run_command("printf 'should-not-run'", 102).unwrap();
        assert!(result.cancelled);
        assert_eq!(result.stdout, "");
        assert_eq!(result.exit_code, -1);
    }

    #[test]
    fn running_command_can_be_cancelled() {
        let _guard = TEST_LOCK.lock().unwrap();
        let worker = thread::spawn(|| run_command("exec sleep 5", 103));
        thread::sleep(Duration::from_millis(150));
        assert!(cancel_command(103));
        let result = worker.join().unwrap().unwrap();
        assert!(result.cancelled);
        assert_eq!(result.exit_code, -1);
    }

    #[test]
    fn output_is_bounded_and_marked_as_truncated() {
        let _guard = TEST_LOCK.lock().unwrap();
        let result = run_command("head -c 300000 /dev/zero | tr '\\000' x", 104).unwrap();
        assert!(result.stdout.len() <= MAX_OUTPUT_BYTES + 64);
        assert!(result.stdout.ends_with("[output truncated at 256 KiB]"));
    }
}

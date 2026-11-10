package com.hyouka.commands;

import android.os.Bundle;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;

public final class CommandUserService extends ICommandService.Stub {
    private static final int MAX_OUTPUT_BYTES = 256 * 1024;

    private final Object commandLock = new Object();
    private Process activeProcess;
    private long activeCommandId = -1L;
    private long cancelledCommandId = -1L;
    private long lastCompletedCommandId = -1L;
    private boolean commandRunning;
    private boolean cancellationRequested;

    public CommandUserService() {
        super();
    }

    @Override
    public Bundle execute(String command, long commandId) {
        if (command == null || command.trim().isEmpty()) {
            throw new IllegalArgumentException("Command is empty.");
        }
        if (commandId <= 0L) {
            throw new IllegalArgumentException("Invalid command ID.");
        }

        synchronized (commandLock) {
            if (commandRunning) {
                throw new IllegalStateException("Another command is already running.");
            }
            commandRunning = true;
            activeCommandId = commandId;
            cancellationRequested = cancelledCommandId == commandId;
            cancelledCommandId = -1L;
        }

        Process process = null;

        try {
            if (isCancellationRequested(commandId)) {
                return cancelledResult();
            }

            ProcessBuilder builder = new ProcessBuilder("/system/bin/sh", "-c", command)
                    .redirectErrorStream(false);
            builder.environment().put(
                    "PATH",
                    "/system/bin:/system/xbin:/vendor/bin:/vendor/xbin"
            );
            builder.environment().put("LC_ALL", "C");

            process = builder.start();
            synchronized (commandLock) {
                activeProcess = process;
                if (activeCommandId == commandId && cancellationRequested) {
                    terminateProcess(process);
                }
            }

            Collector out = new Collector(process.getInputStream());
            Collector err = new Collector(process.getErrorStream());

            Thread outThread = new Thread(out, "commands-stdout");
            Thread errThread = new Thread(err, "commands-stderr");
            outThread.setDaemon(true);
            errThread.setDaemon(true);
            outThread.start();
            errThread.start();

            int exitCode = process.waitFor();
            outThread.join(1000L);
            errThread.join(1000L);

            boolean cancelled = isCancellationRequested(commandId);
            Bundle result = new Bundle();
            result.putString("stdout", out.snapshot());
            result.putString("stderr", err.snapshot());
            result.putInt("exitCode", cancelled ? -1 : exitCode);
            result.putBoolean("cancelled", cancelled);
            return result;
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new IllegalStateException("Command execution was interrupted.", e);
        } catch (Exception e) {
            String message = e.getMessage();
            throw new IllegalStateException(
                    message == null ? e.getClass().getSimpleName() : message,
                    e
            );
        } finally {
            if (process != null) {
                terminateProcess(process);
            }
            synchronized (commandLock) {
                if (activeCommandId == commandId) {
                    activeProcess = null;
                    activeCommandId = -1L;
                    commandRunning = false;
                    cancellationRequested = false;
                    lastCompletedCommandId = commandId;
                }
                if (cancelledCommandId == commandId) {
                    cancelledCommandId = -1L;
                }
            }
        }
    }

    @Override
    public boolean cancel(long commandId) {
        if (commandId <= 0L) {
            return false;
        }

        Process process;
        synchronized (commandLock) {
            if (commandRunning && activeCommandId == commandId) {
                cancellationRequested = true;
                process = activeProcess;
            } else {
                if (lastCompletedCommandId == commandId) {
                    return false;
                }
                // Remember cancellation if it races ahead of execute().
                cancelledCommandId = commandId;
                return true;
            }
        }

        if (process != null) {
            terminateProcess(process);
        }
        return true;
    }

    @Override
    public void destroy() {
        Process process;
        synchronized (commandLock) {
            process = activeProcess;
            if (process != null) {
                cancellationRequested = true;
            }
        }
        if (process != null) {
            terminateProcess(process);
        }
        System.exit(0);
    }

    private boolean isCancellationRequested(long commandId) {
        synchronized (commandLock) {
            return activeCommandId == commandId && cancellationRequested;
        }
    }

    private static Bundle cancelledResult() {
        Bundle result = new Bundle();
        result.putString("stdout", "");
        result.putString("stderr", "");
        result.putInt("exitCode", -1);
        result.putBoolean("cancelled", true);
        return result;
    }

    private static void terminateProcess(Process process) {
        try {
            process.destroyForcibly();
        } catch (Exception ignored) {
        }
        try {
            process.getInputStream().close();
        } catch (Exception ignored) {
        }
        try {
            process.getErrorStream().close();
        } catch (Exception ignored) {
        }
        try {
            process.getOutputStream().close();
        } catch (Exception ignored) {
        }
    }

    private static final class Collector implements Runnable {
        private final InputStream input;
        private final ByteArrayOutputStream bytes = new ByteArrayOutputStream();
        private boolean truncated;

        Collector(InputStream input) {
            this.input = input;
        }

        @Override
        public void run() {
            byte[] buffer = new byte[8192];
            int read;

            try {
                while ((read = input.read(buffer)) != -1) {
                    synchronized (bytes) {
                        int remaining = MAX_OUTPUT_BYTES - bytes.size();
                        if (remaining > 0) {
                            bytes.write(buffer, 0, Math.min(read, remaining));
                        }
                        if (read > remaining) {
                            truncated = true;
                        }
                    }
                }
            } catch (Exception ignored) {
            }
        }

        String snapshot() {
            synchronized (bytes) {
                String value = bytes.toString(StandardCharsets.UTF_8);
                return truncated ? value + "\n[output truncated at 256 KiB]" : value;
            }
        }
    }
}

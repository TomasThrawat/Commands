import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const CommandsApp());
}

class CommandsApp extends StatelessWidget {
  const CommandsApp({super.key});

  @override
  Widget build(BuildContext context) {
    const black = Colors.black;
    const white = Colors.white;

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Commands',
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: black,
        canvasColor: black,
        colorScheme: const ColorScheme.dark(
          surface: black,
          surfaceContainer: black,
          primary: white,
          onPrimary: black,
          secondary: white,
          onSecondary: black,
          onSurface: white,
        ),
        textTheme: const TextTheme(
          bodyLarge: TextStyle(color: white),
          bodyMedium: TextStyle(color: white),
          bodySmall: TextStyle(color: white),
          titleLarge: TextStyle(color: white),
          titleMedium: TextStyle(color: white),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: black,
          foregroundColor: white,
          elevation: 0,
        ),
        inputDecorationTheme: const InputDecorationTheme(
          filled: true,
          fillColor: black,
          enabledBorder: OutlineInputBorder(
            borderSide: BorderSide(color: white),
          ),
          focusedBorder: OutlineInputBorder(
            borderSide: BorderSide(color: white, width: 2),
          ),
          labelStyle: TextStyle(color: white),
          hintStyle: TextStyle(color: white),
        ),
      ),
      home: const CommandsPage(),
    );
  }
}

class CommandsPage extends StatefulWidget {
  const CommandsPage({super.key});

  @override
  State<CommandsPage> createState() => _CommandsPageState();
}

class _CommandsPageState extends State<CommandsPage> {
  static const channel = MethodChannel('com.hyouka.commands/shizuku');

  final commandController = TextEditingController();
  final outputController = ScrollController();

  bool running = false;
  bool installed = false;
  bool shizukuRunning = false;
  bool permission = false;

  String status = 'Checking Shizuku...';
  String lastCommand = '';
  String stdoutText = '';
  String stderrText = '';
  String? errorText;
  int? exitCode;
  bool timedOut = false;

  @override
  void initState() {
    super.initState();
    refreshStatus();
  }

  @override
  void dispose() {
    commandController.dispose();
    outputController.dispose();
    super.dispose();
  }

  Future<void> refreshStatus() async {
    try {
      final raw = await channel.invokeMethod<Map<dynamic, dynamic>>('status');
      final data = Map<String, dynamic>.from(raw ?? const {});
      if (!mounted) return;

      installed = data['installed'] == true;
      shizukuRunning = data['running'] == true;
      permission = data['permission'] == true;

      setState(() {
        status = _statusText();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        status = e.toString();
      });
    }
  }

  String _statusText() {
    if (!installed) return 'Shizuku is not installed.';
    if (!shizukuRunning) return 'Shizuku is installed but not running.';
    if (!permission) return 'Shizuku permission is required.';
    return 'Shizuku is ready.';
  }

  Future<void> requestPermission() async {
    try {
      final granted = await channel.invokeMethod<bool>('requestPermission');
      await refreshStatus();
      if (!mounted) return;
      showMessage(granted == true
          ? 'Shizuku permission granted.'
          : 'Shizuku permission was not granted.');
    } on PlatformException catch (e) {
      if (!mounted) return;
      showMessage(e.message ?? e.code);
    }
  }

  Future<void> runCommand() async {
    final command = commandController.text.trim();
    if (command.isEmpty || running) return;

    FocusManager.instance.primaryFocus?.unfocus();

    setState(() {
      running = true;
      lastCommand = command;
      stdoutText = '';
      stderrText = '';
      errorText = null;
      exitCode = null;
      timedOut = false;
    });

    try {
      final raw = await channel.invokeMethod<Map<dynamic, dynamic>>(
        'runCommand',
        <String, dynamic>{
          'command': command,
          'timeoutMs': 120000,
        },
      );
      final data = Map<String, dynamic>.from(raw ?? const {});

      if (!mounted) return;
      setState(() {
        stdoutText = data['stdout'] as String? ?? '';
        stderrText = data['stderr'] as String? ?? '';
        exitCode = (data['exitCode'] as num?)?.toInt();
        timedOut = data['timedOut'] == true;
      });
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() {
        errorText = e.message ?? e.code;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        errorText = e.toString();
      });
    } finally {
      if (!mounted) return;
      setState(() {
        running = false;
      });
      await refreshStatus();
      await Future<void>.delayed(const Duration(milliseconds: 80));
      if (outputController.hasClients) {
        outputController.animateTo(
          outputController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
        );
      }
    }
  }

  String visibleOutput() {
    final buffer = StringBuffer()
      ..writeln('Commands')
      ..writeln()
      ..writeln('Command:')
      ..writeln(lastCommand)
      ..writeln()
      ..writeln('Exit code: ' + (exitCode?.toString() ?? '-'))
      ..writeln()
      ..writeln('STDOUT:')
      ..writeln(stdoutText.isEmpty ? '(empty)' : stdoutText)
      ..writeln()
      ..writeln('STDERR:')
      ..writeln(stderrText.isEmpty ? '(empty)' : stderrText);

    if (timedOut) {
      buffer
        ..writeln()
        ..writeln('TIMEOUT:')
        ..writeln('120 seconds');
    }

    if (errorText != null) {
      buffer
        ..writeln()
        ..writeln('ERROR:')
        ..writeln(errorText);
    }

    return buffer.toString();
  }

  Future<void> saveOutput() async {
    try {
      final raw = await channel.invokeMethod<Map<dynamic, dynamic>>(
        'saveOutput',
        <String, dynamic>{'content': visibleOutput()},
      );
      final data = Map<String, dynamic>.from(raw ?? const {});
      if (!mounted) return;

      showMessage(data['success'] == true
          ? 'Saved as commands.txt in Downloads.'
          : 'Save failed.');
    } on PlatformException catch (e) {
      if (!mounted) return;
      showMessage(e.message ?? e.code);
    }
  }

  void showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          backgroundColor: Colors.black,
          behavior: SnackBarBehavior.floating,
          content: Text(
            message,
            style: const TextStyle(color: Colors.white),
          ),
        ),
      );
  }

  Widget label(String text) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget block(String title, String text) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        label(title),
        const SizedBox(height: 8),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.black,
            border: Border.all(color: Colors.white),
          ),
          child: SelectionArea(
            child: Text(
              text.isEmpty ? '(empty)' : text,
              style: const TextStyle(
                color: Colors.white,
                fontFamily: 'monospace',
                fontSize: 13,
              ),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Commands'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: refreshStatus,
            icon: const Icon(Icons.refresh, color: Colors.white),
          ),
        ],
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.startFloat,
      floatingActionButton: FloatingActionButton.extended(
        onPressed: saveOutput,
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        side: const BorderSide(color: Colors.white),
        icon: const Icon(Icons.save_outlined),
        label: const Text('Save Output'),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 110),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.black,
                  border: Border.all(color: Colors.white),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.terminal, color: Colors.white),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        status,
                        style: const TextStyle(color: Colors.white),
                      ),
                    ),
                    if (installed && shizukuRunning && !permission)
                      OutlinedButton(
                        onPressed: requestPermission,
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white,
                          side: const BorderSide(color: Colors.white),
                        ),
                        child: const Text('Grant'),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              label('Shell command'),
              const SizedBox(height: 8),
              TextField(
                controller: commandController,
                enabled: !running,
                minLines: 1,
                maxLines: 5,
                keyboardType: TextInputType.multiline,
                style: const TextStyle(
                  color: Colors.white,
                  fontFamily: 'monospace',
                ),
                decoration: const InputDecoration(
                  hintText: 'Enter a shell command',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerRight,
                child: OutlinedButton.icon(
                  onPressed: running ? null : runCommand,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: const BorderSide(color: Colors.white),
                  ),
                  icon: running
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.play_arrow, color: Colors.white),
                  label: Text(running ? 'Running...' : 'Run'),
                ),
              ),
              const SizedBox(height: 20),
              if (lastCommand.isNotEmpty) ...[
                block('Command being run', lastCommand),
                const SizedBox(height: 14),
                block('STDOUT', stdoutText),
                const SizedBox(height: 14),
                block('STDERR', stderrText),
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.black,
                    border: Border.all(color: Colors.white),
                  ),
                  child: Row(
                    children: [
                      const Text(
                        'Exit code',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        exitCode?.toString() ?? (running ? 'running' : '-'),
                        style: const TextStyle(
                          color: Colors.white,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              if (timedOut) ...[
                const SizedBox(height: 12),
                const Text(
                  'The command reached the 120-second timeout.',
                  style: TextStyle(color: Colors.white),
                ),
              ],
              if (errorText != null) ...[
                const SizedBox(height: 12),
                block('ERROR', errorText!),
              ],
              const SizedBox(height: 22),
              label('Output'),
              const SizedBox(height: 8),
              Container(
                height: 260,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.black,
                  border: Border.all(color: Colors.white),
                ),
                child: Scrollbar(
                  controller: outputController,
                  thumbVisibility: true,
                  child: SingleChildScrollView(
                    controller: outputController,
                    child: SelectionArea(
                      child: Text(
                        visibleOutput(),
                        style: const TextStyle(
                          color: Colors.white,
                          fontFamily: 'monospace',
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

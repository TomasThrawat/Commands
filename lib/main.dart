import 'dart:async';

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

  Timer? statusTimer;
  bool running = false;
  bool installed = false;
  bool shizukuRunning = false;
  bool permission = false;
  bool loadingStatus = true;

  String lastCommand = '';
  String stdoutText = '';
  String stderrText = '';
  String? errorText;
  int? exitCode;
  bool timedOut = false;

  bool get hasOutput =>
      lastCommand.isNotEmpty ||
      stdoutText.isNotEmpty ||
      stderrText.isNotEmpty ||
      errorText != null;

  @override
  void initState() {
    super.initState();
    refreshStatus();
    statusTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => refreshStatus(silent: true),
    );
  }

  @override
  void dispose() {
    statusTimer?.cancel();
    commandController.dispose();
    outputController.dispose();
    super.dispose();
  }

  Future<void> refreshStatus({bool silent = false}) async {
    if (!silent && mounted) {
      setState(() => loadingStatus = true);
    }

    try {
      final raw = await channel.invokeMethod<Map<dynamic, dynamic>>('status');
      final data = Map<String, dynamic>.from(raw ?? const {});

      if (!mounted) return;

      setState(() {
        installed = data['installed'] == true;
        shizukuRunning = data['running'] == true;
        permission = data['permission'] == true;
        loadingStatus = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => loadingStatus = false);
      if (!silent) showMessage(e.toString());
    }
  }

  Future<void> requestPermission() async {
    try {
      final granted = await channel.invokeMethod<bool>('requestPermission');
      await refreshStatus();
      if (!mounted) return;

      showMessage(
        granted == true
            ? 'Shizuku permission granted.'
            : 'Shizuku permission was not granted.',
      );
    } on PlatformException catch (e) {
      if (!mounted) return;
      showMessage(e.message ?? e.code);
      await refreshStatus(silent: true);
    }
  }

  Future<void> openShizuku() async {
    try {
      await channel.invokeMethod('openShizuku');
    } on PlatformException catch (e) {
      if (!mounted) return;
      showMessage(e.message ?? e.code);
    }
  }

  Future<void> runCommand() async {
    final command = commandController.text.trim();

    if (!permission || command.isEmpty || running) return;

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
      setState(() => errorText = e.message ?? e.code);
    } catch (e) {
      if (!mounted) return;
      setState(() => errorText = e.toString());
    } finally {
      if (!mounted) return;

      setState(() => running = false);
      await refreshStatus(silent: true);
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
    final buffer = StringBuffer();

    if (lastCommand.isNotEmpty) {
      buffer
        ..writeln(r'$ $lastCommand')
        ..writeln();
    }

    if (stdoutText.isNotEmpty) {
      buffer.write(stdoutText);
      if (!stdoutText.endsWith('\n')) buffer.writeln();
    }

    if (stderrText.isNotEmpty) {
      buffer
        ..writeln('[stderr]')
        ..write(stderrText);
      if (!stderrText.endsWith('\n')) buffer.writeln();
    }

    if (exitCode != null) {
      buffer
        ..writeln()
        ..writeln('[exit code: $exitCode]');
    }

    if (timedOut) {
      buffer
        ..writeln()
        ..writeln('[timeout: 120 seconds]');
    }

    if (errorText != null) {
      buffer
        ..writeln()
        ..writeln('[error]')
        ..writeln(errorText);
    }

    final text = buffer.toString();
    return text.isEmpty ? 'No output yet.' : text;
  }

  Future<void> saveOutput() async {
    if (!hasOutput) return;

    try {
      final raw = await channel.invokeMethod<Map<dynamic, dynamic>>(
        'saveOutput',
        <String, dynamic>{'content': visibleOutput()},
      );
      final data = Map<String, dynamic>.from(raw ?? const {});

      if (!mounted) return;
      showMessage(
        data['success'] == true
            ? 'Saved to Downloads/Commands/commands.txt'
            : 'Save failed.',
      );
    } on PlatformException catch (e) {
      if (!mounted) return;
      showMessage(e.message ?? e.code);
    }
  }

  void clearOutput() {
    setState(() {
      lastCommand = '';
      stdoutText = '';
      stderrText = '';
      errorText = null;
      exitCode = null;
      timedOut = false;
    });
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

  String get statusTitle {
    if (!installed) return 'Shizuku not installed';
    if (!shizukuRunning) return 'Shizuku not running';
    if (!permission) return 'Permission required';
    return 'Shizuku ready';
  }

  String get statusSubtitle {
    if (!installed) {
      return 'Install and start Shizuku before running commands.';
    }
    if (!shizukuRunning) {
      return 'Open Shizuku and start its service.';
    }
    if (!permission) {
      return 'Grant Commands access in the Shizuku permission dialog.';
    }
    return 'The command runner is ready.';
  }

  Widget outlinedButton({
    required String text,
    required VoidCallback? onPressed,
    required IconData icon,
  }) {
    return OutlinedButton.icon(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        foregroundColor: Colors.white,
        disabledForegroundColor: Colors.white38,
        side: const BorderSide(color: Colors.white),
      ),
      icon: Icon(icon, color: Colors.white, size: 18),
      label: Text(text),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ready = installed && shizukuRunning && permission;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Commands'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: () => refreshStatus(),
            icon: const Icon(Icons.refresh, color: Colors.white),
          ),
          IconButton(
            tooltip: 'Clear output',
            onPressed: hasOutput ? clearOutput : null,
            icon: const Icon(Icons.delete_sweep_outlined, color: Colors.white),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.black,
                  border: Border.all(color: Colors.white),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          ready
                              ? Icons.verified_outlined
                              : Icons.lock_outline,
                          color: Colors.white,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            statusTitle,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        if (loadingStatus)
                          const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      statusSubtitle,
                      style: const TextStyle(
                        color: Colors.white70,
                        height: 1.35,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        if (installed && !shizukuRunning)
                          outlinedButton(
                            text: 'Open Shizuku',
                            onPressed: openShizuku,
                            icon: Icons.open_in_new,
                          ),
                        if (installed && shizukuRunning && !permission)
                          outlinedButton(
                            text: 'Grant Permission',
                            onPressed: requestPermission,
                            icon: Icons.security_outlined,
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Container(
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: Colors.black,
                    border: Border.all(color: Colors.white),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                        child: Row(
                          children: [
                            const Icon(Icons.terminal, color: Colors.white),
                            const SizedBox(width: 8),
                            const Expanded(
                              child: Text(
                                'Terminal',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            Text(
                              ready ? 'READY' : 'LOCKED',
                              style: TextStyle(
                                color: ready ? Colors.white : Colors.white54,
                                fontFamily: 'monospace',
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Scrollbar(
                            controller: outputController,
                            thumbVisibility: true,
                            child: SingleChildScrollView(
                              controller: outputController,
                              padding: const EdgeInsets.fromLTRB(4, 6, 4, 12),
                              child: SelectionArea(
                                child: Text(
                                  visibleOutput(),
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontFamily: 'monospace',
                                    fontSize: 13,
                                    height: 1.35,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const Divider(height: 1, color: Colors.white24),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Expanded(
                              child: TextField(
                                controller: commandController,
                                enabled: ready && !running,
                                minLines: 1,
                                maxLines: 4,
                                keyboardType: TextInputType.multiline,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontFamily: 'monospace',
                                  fontSize: 13,
                                ),
                                decoration: InputDecoration(
                                  filled: true,
                                  fillColor: Colors.black,
                                  hintText: ready
                                      ? 'Type a shell command'
                                      : 'Grant Shizuku permission first',
                                  hintStyle:
                                      const TextStyle(color: Colors.white38),
                                  prefixText: r'$ ',
                                  prefixStyle: const TextStyle(
                                    color: Colors.white54,
                                    fontFamily: 'monospace',
                                  ),
                                  enabledBorder: const OutlineInputBorder(
                                    borderSide:
                                        BorderSide(color: Colors.white54),
                                  ),
                                  focusedBorder: const OutlineInputBorder(
                                    borderSide:
                                        BorderSide(color: Colors.white),
                                  ),
                                  disabledBorder: const OutlineInputBorder(
                                    borderSide:
                                        BorderSide(color: Colors.white24),
                                  ),
                                ),
                                onSubmitted: (_) => runCommand(),
                              ),
                            ),
                            const SizedBox(width: 8),
                            IconButton.filled(
                              tooltip: 'Run command',
                              onPressed: ready && !running ? runCommand : null,
                              style: IconButton.styleFrom(
                                foregroundColor: Colors.black,
                                backgroundColor: Colors.white,
                                disabledForegroundColor: Colors.white38,
                                disabledBackgroundColor: Colors.white12,
                              ),
                              icon: running
                                  ? const SizedBox(
                                      width: 20,
                                      height: 20,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Colors.black,
                                      ),
                                    )
                                  : const Icon(Icons.play_arrow),
                            ),
                            const SizedBox(width: 4),
                            IconButton(
                              tooltip: 'Save output',
                              onPressed: hasOutput ? saveOutput : null,
                              icon: const Icon(
                                Icons.save_outlined,
                                color: Colors.white,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

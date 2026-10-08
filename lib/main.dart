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


enum _SettingsSection {
  system,
  global,
  secure,
  prop,
}

extension on _SettingsSection {
  String get title {
    switch (this) {
      case _SettingsSection.system:
        return 'System';
      case _SettingsSection.global:
        return 'Global';
      case _SettingsSection.secure:
        return 'Secure';
      case _SettingsSection.prop:
        return 'Prop';
    }
  }
}

class _SettingEntry {
  const _SettingEntry({
    required this.key,
    required this.value,
  });

  final String key;
  final String value;
}

class _CommandResult {
  const _CommandResult({
    required this.exitCode,
    required this.output,
    required this.timedOut,
  });

  final int? exitCode;
  final String output;
  final bool timedOut;

  bool get success => exitCode == 0 && !timedOut;
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
  String outputText = '';

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

      setState(() {
        installed = data['installed'] == true;
        shizukuRunning = data['running'] == true;
        permission = data['permission'] == true;
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
      showMessage(
        granted == true
            ? 'Shizuku permission granted.'
            : 'Shizuku permission was not granted.',
      );
    } on PlatformException catch (e) {
      if (!mounted) return;
      showMessage(e.message ?? e.code);
    }
  }

  String _shellQuote(String value) {
    return "'" + value.replaceAll("'", "'\"'\"'") + "'";
  }

  Future<_CommandResult> _runRawCommand(String command) async {
    try {
      final raw = await channel.invokeMethod<Map<dynamic, dynamic>>(
        'runCommand',
        <String, dynamic>{
          'command': command,
          'timeoutMs': 120000,
        },
      );
      final data = Map<String, dynamic>.from(raw ?? const {});
      final stdout = data['stdout'] as String? ?? '';
      final stderr = data['stderr'] as String? ?? '';
      final combined = stdout.isEmpty
          ? stderr
          : stderr.isEmpty
              ? stdout
              : '$stdout\n$stderr';

      return _CommandResult(
        exitCode: (data['exitCode'] as num?)?.toInt(),
        output: combined,
        timedOut: data['timedOut'] == true,
      );
    } on PlatformException catch (e) {
      return _CommandResult(
        exitCode: -1,
        output: e.message ?? e.code,
        timedOut: false,
      );
    } catch (e) {
      return _CommandResult(
        exitCode: -1,
        output: e.toString(),
        timedOut: false,
      );
    }
  }

  Future<void> runCommand() async {
    final command = commandController.text.trim();
    if (command.isEmpty || running || !canRun) return;

    FocusManager.instance.primaryFocus?.unfocus();

    setState(() {
      running = true;
      outputText = '';
    });

    final result = await _runRawCommand(command);

    if (!mounted) return;

    setState(() {
      outputText = result.output.isNotEmpty
          ? result.output
          : result.timedOut
              ? 'Command timed out after 120 seconds.'
              : '';
      running = false;
    });

    await refreshStatus();
    await Future<void>.delayed(const Duration(milliseconds: 80));
    if (outputController.hasClients) {
      await outputController.animateTo(
        outputController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOut,
      );
    }
  }

  Future<List<_SettingEntry>> _loadSection(
    _SettingsSection section,
  ) async {
    final command = switch (section) {
      _SettingsSection.system => 'settings list system',
      _SettingsSection.global => 'settings list global',
      _SettingsSection.secure => 'settings list secure',
      _SettingsSection.prop => 'getprop',
    };
    final result = await _runRawCommand(command);
    if (!result.success && result.output.trim().isNotEmpty) {
      throw StateError(result.output.trim());
    }

    final entries = <_SettingEntry>[];
    for (final rawLine in result.output.split('\n')) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;

      if (section == _SettingsSection.prop) {
        final match = RegExp(r'^\[([^\]]+)\]:\s*\[(.*)\]$').firstMatch(line);
        if (match != null) {
          entries.add(
            _SettingEntry(
              key: match.group(1) ?? '',
              value: match.group(2) ?? '',
            ),
          );
        }
        continue;
      }

      final separator = line.indexOf('=');
      if (separator <= 0) continue;
      entries.add(
        _SettingEntry(
          key: line.substring(0, separator),
          value: line.substring(separator + 1),
        ),
      );
    }

    entries.sort(
      (a, b) => a.key.toLowerCase().compareTo(b.key.toLowerCase()),
    );
    return entries;
  }

  Future<void> _openSection(_SettingsSection section) async {
    if (!canRun) {
      showMessage('Shizuku permission is required.');
      return;
    }

    final future = _loadSection(section);

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: Colors.black,
          surfaceTintColor: Colors.black,
          title: Text(
            section.title,
            style: const TextStyle(color: Colors.white),
          ),
          content: SizedBox(
            width: double.maxFinite,
            height: MediaQuery.sizeOf(context).height * 0.62,
            child: FutureBuilder<List<_SettingEntry>>(
              future: future,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Center(
                    child: CircularProgressIndicator(color: Colors.white),
                  );
                }

                if (snapshot.hasError) {
                  return SingleChildScrollView(
                    child: SelectableText(
                      snapshot.error.toString(),
                      style: const TextStyle(
                        color: Colors.white,
                        fontFamily: 'monospace',
                        fontSize: 13,
                      ),
                    ),
                  );
                }

                final entries = snapshot.data ?? const <_SettingEntry>[];
                if (entries.isEmpty) {
                  return const Center(
                    child: Text(
                      'No values found.',
                      style: TextStyle(color: Colors.white),
                    ),
                  );
                }

                return Scrollbar(
                  thumbVisibility: true,
                  child: ListView.separated(
                    itemCount: entries.length,
                    separatorBuilder: (_, __) => const Divider(
                      color: Colors.white24,
                      height: 1,
                    ),
                    itemBuilder: (context, index) {
                      final entry = entries[index];
                      return ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 2,
                        ),
                        title: Text(
                          entry.key,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontFamily: 'monospace',
                            fontSize: 13,
                          ),
                        ),
                        subtitle: Text(
                          entry.value.isEmpty ? '(empty)' : entry.value,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white70,
                            fontFamily: 'monospace',
                            fontSize: 12,
                          ),
                        ),
                        onTap: () async {
                          Navigator.of(dialogContext).pop();
                          await _editEntry(section, entry);
                        },
                      );
                    },
                  ),
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              style: TextButton.styleFrom(foregroundColor: Colors.white),
              child: const Text('Cancel'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _editEntry(
    _SettingsSection section,
    _SettingEntry entry,
  ) async {
    final keyController = TextEditingController(text: entry.key);
    final valueController = TextEditingController(text: entry.value);
    String? errorMessage;

    try {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) {
          return StatefulBuilder(
            builder: (context, setDialogState) {
              final key = keyController.text.trim();
              final readOnlyProp =
                  section == _SettingsSection.prop && key.startsWith('ro.');
              final canApply = key.isNotEmpty && !readOnlyProp;

              return AlertDialog(
                backgroundColor: Colors.black,
                surfaceTintColor: Colors.black,
                title: Text(
                  section.title + ' value',
                  style: const TextStyle(color: Colors.white),
                ),
                content: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextField(
                        controller: keyController,
                        readOnly: true,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontFamily: 'monospace',
                        ),
                        decoration: const InputDecoration(
                          labelText: 'Key',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: valueController,
                        minLines: 2,
                        maxLines: 8,
                        autofocus: true,
                        style: const TextStyle(
                          color: Colors.white,
                          fontFamily: 'monospace',
                        ),
                        decoration: const InputDecoration(
                          labelText: 'Value',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      if (readOnlyProp) ...[
                        const SizedBox(height: 10),
                        const Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            'Read-only property.',
                            style: TextStyle(color: Colors.white70),
                          ),
                        ),
                      ],
                      if (errorMessage != null) ...[
                        const SizedBox(height: 10),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: SelectableText(
                            errorMessage!,
                            style: const TextStyle(
                              color: Colors.white,
                              fontFamily: 'monospace',
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(dialogContext).pop(),
                    style: TextButton.styleFrom(foregroundColor: Colors.white),
                    child: const Text('Cancel'),
                  ),
                  TextButton(
                    onPressed: canApply
                        ? () async {
                            final value = valueController.text;
                            final command = section == _SettingsSection.prop
                                ? 'setprop ' +
                                    _shellQuote(key) +
                                    ' ' +
                                    _shellQuote(value)
                                : 'settings put ' +
                                    section.name +
                                    ' ' +
                                    _shellQuote(key) +
                                    ' ' +
                                    _shellQuote(value);

                            final result = await _runRawCommand(command);
                            if (!context.mounted) return;

                            if (result.success) {
                              Navigator.of(dialogContext).pop();
                              showMessage('Applied.');
                            } else {
                              setDialogState(() {
                                errorMessage = result.output.isEmpty
                                    ? 'Apply failed.'
                                    : result.output;
                              });
                            }
                          }
                        : null,
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.white,
                      disabledForegroundColor: Colors.white38,
                    ),
                    child: const Text('Apply'),
                  ),
                ],
              );
            },
          );
        },
      );
    } finally {
      keyController.dispose();
      valueController.dispose();
    }
  }

  Future<void> saveOutput() async {
    try {
      final raw = await channel.invokeMethod<Map<dynamic, dynamic>>(
        'saveOutput',
        <String, dynamic>{'content': outputText},
      );
      final data = Map<String, dynamic>.from(raw ?? const {});

      if (!mounted) return;
      showMessage(
        data['success'] == true
            ? 'Saved as commands.txt in Downloads.'
            : 'Save failed.',
      );
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

  Widget sectionButton(_SettingsSection section, IconData icon) {
    return OutlinedButton.icon(
      onPressed: canRun ? () => _openSection(section) : null,
      style: OutlinedButton.styleFrom(
        foregroundColor: Colors.white,
        disabledForegroundColor: Colors.white38,
        side: const BorderSide(color: Colors.white),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),
      icon: Icon(icon, color: canRun ? Colors.white : Colors.white38),
      label: Text(section.title),
    );
  }

  @override
  Widget build(BuildContext context) {
    final canRun = installed && shizukuRunning && permission;

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
        onPressed: outputText.isEmpty ? null : saveOutput,
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        disabledForegroundColor: Colors.white38,
        shape: RoundedRectangleBorder(
          side: BorderSide(
            color: outputText.isEmpty ? Colors.white38 : Colors.white,
          ),
          borderRadius: BorderRadius.circular(16),
        ),
        icon: const Icon(Icons.save_outlined),
        label: const Text('Save Output'),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: Colors.black,
                  border: Border.all(color: Colors.white),
                ),
                child: Row(
                  children: [
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
                    if (!installed || !shizukuRunning)
                      OutlinedButton(
                        onPressed: () => channel.invokeMethod('openShizuku'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white,
                          side: const BorderSide(color: Colors.white),
                        ),
                        child: const Text('Open Shizuku'),
                      ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: GridView.count(
                crossAxisCount: 2,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
                childAspectRatio: 3.1,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                children: [
                  sectionButton(_SettingsSection.system, Icons.tune),
                  sectionButton(_SettingsSection.global, Icons.public),
                  sectionButton(_SettingsSection.secure, Icons.lock_outline),
                  sectionButton(_SettingsSection.prop, Icons.settings),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
              child: TextField(
                controller: commandController,
                enabled: !running && canRun,
                minLines: 1,
                maxLines: 5,
                keyboardType: TextInputType.multiline,
                style: const TextStyle(
                  color: Colors.white,
                  fontFamily: 'monospace',
                ),
                decoration: InputDecoration(
                  hintText: canRun
                      ? 'Enter a shell command'
                      : 'Shizuku permission required',
                  border: const OutlineInputBorder(),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
              child: Align(
                alignment: Alignment.centerRight,
                child: OutlinedButton.icon(
                  onPressed: running || !canRun ? null : runCommand,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    disabledForegroundColor: Colors.white54,
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
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Scrollbar(
                  controller: outputController,
                  thumbVisibility: true,
                  child: SingleChildScrollView(
                    controller: outputController,
                    padding: const EdgeInsets.only(top: 6, bottom: 96),
                    child: SelectionArea(
                      child: Align(
                        alignment: Alignment.topLeft,
                        child: Text(
                          outputText,
                          style: const TextStyle(
                            color: Colors.white,
                            fontFamily: 'monospace',
                            fontSize: 13,
                            height: 1.45,
                          ),
                        ),
                      ),
                    ),
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

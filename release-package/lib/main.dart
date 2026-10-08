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
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Commands',
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: Colors.black,
        canvasColor: Colors.black,
        colorScheme: const ColorScheme.dark(
          surface: Colors.black,
          surfaceContainer: Colors.black,
          primary: Colors.white,
          onPrimary: Colors.black,
          secondary: Colors.white,
          onSecondary: Colors.black,
          onSurface: Colors.white,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          elevation: 0,
        ),
        inputDecorationTheme: const InputDecorationTheme(
          filled: true,
          fillColor: Colors.black,
          enabledBorder: OutlineInputBorder(
            borderSide: BorderSide(color: Colors.white),
          ),
          focusedBorder: OutlineInputBorder(
            borderSide: BorderSide(color: Colors.white, width: 2),
          ),
          labelStyle: TextStyle(color: Colors.white),
          hintStyle: TextStyle(color: Colors.white),
        ),
      ),
      home: const CommandsPage(),
    );
  }
}

enum _SettingsSection {
  system('System'),
  global('Global'),
  secure('Secure'),
  prop('Prop');

  const _SettingsSection(this.title);
  final String title;
}

class _SettingEntry {
  const _SettingEntry({required this.key, required this.value});
  final String key;
  final String value;
}

class _CommandResult {
  const _CommandResult({
    required this.stdout,
    required this.stderr,
    required this.exitCode,
    required this.timedOut,
  });

  final String stdout;
  final String stderr;
  final int exitCode;
  final bool timedOut;
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
  String terminalText = '';

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

  bool get authorized => installed && shizukuRunning && permission;

  String _statusText() {
    if (!installed) return 'Shizuku is not installed.';
    if (!shizukuRunning) return 'Shizuku is installed but not running.';
    if (!permission) return 'Shizuku permission is required.';
    return 'Shizuku is ready.';
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
      setState(() => status = e.toString());
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
      if (mounted) showMessage(e.message ?? e.code);
    }
  }

  Future<_CommandResult> _runShell(String command) async {
    final raw = await channel.invokeMethod<Map<dynamic, dynamic>>(
      'runCommand',
      <String, dynamic>{'command': command, 'timeoutMs': 120000},
    );
    final data = Map<String, dynamic>.from(raw ?? const {});
    return _CommandResult(
      stdout: data['stdout'] as String? ?? '',
      stderr: data['stderr'] as String? ?? '',
      exitCode: (data['exitCode'] as num?)?.toInt() ?? -1,
      timedOut: data['timedOut'] == true,
    );
  }

  Future<void> runCommand() async {
    final command = commandController.text.trim();
    if (command.isEmpty || running) return;

    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      running = true;
      terminalText = '';
    });

    try {
      final result = await _runShell(command);
      final parts = <String>[
        if (result.stdout.isNotEmpty) result.stdout.trimRight(),
        if (result.stderr.isNotEmpty) result.stderr.trimRight(),
        if (result.timedOut) 'Command timed out after 120 seconds.',
        if (!result.timedOut &&
            result.exitCode != 0 &&
            result.stdout.isEmpty &&
            result.stderr.isEmpty)
          'Command failed with exit code ' + result.exitCode.toString() + '.',
      ];
      if (!mounted) return;
      setState(() => terminalText = parts.join('\n'));
    } on PlatformException catch (e) {
      if (mounted) setState(() => terminalText = e.message ?? e.code);
    } catch (e) {
      if (mounted) setState(() => terminalText = e.toString());
    } finally {
      if (!mounted) return;
      setState(() => running = false);
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

  Future<void> _openSettingsSection(_SettingsSection section) async {
    if (!authorized) {
      showMessage('Shizuku must be running and authorized first.');
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (_) => _SectionDialog(
        section: section,
        channel: channel,
        parentContext: context,
      ),
    );
  }

  Widget _sectionButton(_SettingsSection section) {
    return OutlinedButton(
      onPressed: authorized ? () => _openSettingsSection(section) : null,
      style: OutlinedButton.styleFrom(
        foregroundColor: Colors.white,
        disabledForegroundColor: Colors.white38,
        side: const BorderSide(color: Colors.white),
        padding: const EdgeInsets.symmetric(vertical: 15, horizontal: 14),
        alignment: Alignment.centerLeft,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              section.title,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const Icon(Icons.chevron_right, color: Colors.white),
        ],
      ),
    );
  }

  Future<void> saveOutput() async {
    try {
      final raw = await channel.invokeMethod<Map<dynamic, dynamic>>(
        'saveOutput',
        <String, dynamic>{'content': terminalText},
      );
      final data = Map<String, dynamic>.from(raw ?? const {});
      if (!mounted) return;
      showMessage(
        data['success'] == true
            ? 'Saved as commands.txt in Downloads.'
            : 'Save failed.',
      );
    } on PlatformException catch (e) {
      if (mounted) showMessage(e.message ?? e.code);
    }
  }

  void showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          backgroundColor: Colors.black,
          content: Text(message, style: const TextStyle(color: Colors.white)),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Commands'),
        actions: [
          IconButton(
            onPressed: refreshStatus,
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh, color: Colors.white),
          ),
        ],
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.startFloat,
      floatingActionButton: FloatingActionButton.extended(
        onPressed: saveOutput,
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        shape: RoundedRectangleBorder(
          side: const BorderSide(color: Colors.white),
          borderRadius: BorderRadius.circular(16),
        ),
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
              const SizedBox(height: 18),
              const Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Settings',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              _sectionButton(_SettingsSection.system),
              const SizedBox(height: 8),
              _sectionButton(_SettingsSection.global),
              const SizedBox(height: 8),
              _sectionButton(_SettingsSection.secure),
              const SizedBox(height: 8),
              _sectionButton(_SettingsSection.prop),
              const SizedBox(height: 18),
              const Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Shell command',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: commandController,
                enabled: authorized && !running,
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
                  onPressed: authorized && !running ? runCommand : null,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    disabledForegroundColor: Colors.white38,
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
              const SizedBox(height: 14),
              const Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Output',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(height: 6),
              SizedBox(
                height: 260,
                child: Scrollbar(
                  controller: outputController,
                  thumbVisibility: true,
                  child: SingleChildScrollView(
                    controller: outputController,
                    child: SelectionArea(
                      child: Align(
                        alignment: Alignment.topLeft,
                        child: Text(
                          terminalText,
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
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionDialog extends StatefulWidget {
  const _SectionDialog({
    required this.section,
    required this.channel,
    required this.parentContext,
  });

  final _SettingsSection section;
  final MethodChannel channel;
  final BuildContext parentContext;

  @override
  State<_SectionDialog> createState() => _SectionDialogState();
}

class _SectionDialogState extends State<_SectionDialog> {
  List<_SettingEntry> entries = const [];
  bool loading = true;
  String? error;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  String _shellQuote(String value) {
    return "'" + value.replaceAll("'", "'\\''") + "'";
  }

  String _readCommand() {
    switch (widget.section) {
      case _SettingsSection.system:
        return 'settings list system';
      case _SettingsSection.global:
        return 'settings list global';
      case _SettingsSection.secure:
        return 'settings list secure';
      case _SettingsSection.prop:
        return 'getprop';
    }
  }

  String _writePrefix() {
    if (widget.section == _SettingsSection.prop) return 'setprop';
    return 'settings put ' + widget.section.title.toLowerCase();
  }

  String _getCommand(String key) {
    if (widget.section == _SettingsSection.prop) {
      return 'getprop ' + _shellQuote(key);
    }
    return 'settings get ' +
        widget.section.title.toLowerCase() +
        ' ' +
        _shellQuote(key);
  }

  Future<_CommandResult> _run(String command) async {
    final raw = await widget.channel.invokeMethod<Map<dynamic, dynamic>>(
      'runCommand',
      <String, dynamic>{'command': command, 'timeoutMs': 120000},
    );
    final data = Map<String, dynamic>.from(raw ?? const {});
    return _CommandResult(
      stdout: data['stdout'] as String? ?? '',
      stderr: data['stderr'] as String? ?? '',
      exitCode: (data['exitCode'] as num?)?.toInt() ?? -1,
      timedOut: data['timedOut'] == true,
    );
  }

  List<_SettingEntry> _parse(String raw) {
    final values = <_SettingEntry>[];
    for (final rawLine in raw.split('\n')) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;

      if (widget.section == _SettingsSection.prop) {
        if (!line.startsWith('[')) continue;
        final keyEnd = line.indexOf(']');
        final valueStart = line.indexOf('[', keyEnd + 1);
        if (keyEnd <= 1 || valueStart < 0 || !line.endsWith(']')) continue;
        values.add(
          _SettingEntry(
            key: line.substring(1, keyEnd),
            value: line.substring(valueStart + 1, line.length - 1),
          ),
        );
      } else {
        final equals = line.indexOf('=');
        if (equals <= 0) continue;
        values.add(
          _SettingEntry(
            key: line.substring(0, equals),
            value: line.substring(equals + 1),
          ),
        );
      }
    }
    values.sort((a, b) => a.key.compareTo(b.key));
    return values;
  }

  Future<void> _reload() async {
    if (mounted) {
      setState(() {
        loading = true;
        error = null;
      });
    }

    try {
      final result = await _run(_readCommand());
      if (!mounted) return;

      if (result.exitCode != 0 && result.stdout.trim().isEmpty) {
        setState(() {
          loading = false;
          error = result.stderr.trim().isEmpty
              ? 'Unable to read ' + widget.section.title + '.'
              : result.stderr.trim();
        });
        return;
      }

      final parsed = _parse(result.stdout);
      setState(() {
        loading = false;
        entries = parsed;
        error = parsed.isEmpty ? 'No values were returned.' : null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        loading = false;
        error = e.toString();
      });
    }
  }

  Future<void> _editEntry(_SettingEntry entry) async {
    final controller = TextEditingController(text: entry.value);
    final readOnly =
        widget.section == _SettingsSection.prop && entry.key.startsWith('ro.');

    try {
      final apply = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: Colors.black,
          title: Text(
            entry.key,
            style: const TextStyle(color: Colors.white),
          ),
          content: TextField(
            controller: controller,
            readOnly: readOnly,
            autofocus: !readOnly,
            minLines: 1,
            maxLines: 8,
            style: const TextStyle(
              color: Colors.white,
              fontFamily: 'monospace',
            ),
            decoration: InputDecoration(
              labelText: readOnly ? 'Read-only value' : 'Value',
              border: const OutlineInputBorder(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text(
                'Cancel',
                style: TextStyle(color: Colors.white),
              ),
            ),
            if (!readOnly)
              TextButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text(
                  'Apply',
                  style: TextStyle(color: Colors.white),
                ),
              ),
          ],
        ),
      );

      if (apply != true || readOnly) return;

      final command = _writePrefix() +
          ' ' +
          _shellQuote(entry.key) +
          ' ' +
          _shellQuote(controller.text);

      final result = await _run(command);
      if (!mounted) return;

      if (result.exitCode != 0) {
        showMessage(
          result.stderr.trim().isEmpty ? 'Apply failed.' : result.stderr.trim(),
        );
        return;
      }

      final verified = await _run(_getCommand(entry.key));
      if (!mounted) return;

      if (verified.exitCode != 0) {
        showMessage(
          verified.stderr.trim().isEmpty
              ? 'Value was applied, but verification failed.'
              : verified.stderr.trim(),
        );
      } else if (verified.stdout.trim() == controller.text) {
        showMessage('Value applied.');
      } else {
        showMessage('The system returned a different value after Apply.');
      }

      await _reload();
    } catch (e) {
      if (mounted) showMessage(e.toString());
    } finally {
      controller.dispose();
    }
  }

  void showMessage(String message) {
    ScaffoldMessenger.of(widget.parentContext)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          backgroundColor: Colors.black,
          content: Text(message, style: const TextStyle(color: Colors.white)),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.black,
      insetPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 24),
      child: SizedBox(
        width: 700,
        height: MediaQuery.sizeOf(context).height * 0.82,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.section.title,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 21,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: loading ? null : _reload,
                    tooltip: 'Refresh',
                    icon: const Icon(Icons.refresh, color: Colors.white),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    tooltip: 'Close',
                    icon: const Icon(Icons.close, color: Colors.white),
                  ),
                ],
              ),
            ),
            const Divider(color: Colors.white24, height: 1),
            Expanded(
              child: loading
                  ? const Center(
                      child: CircularProgressIndicator(color: Colors.white),
                    )
                  : error != null
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: Text(
                              error!,
                              textAlign: TextAlign.center,
                              style: const TextStyle(color: Colors.white),
                            ),
                          ),
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.fromLTRB(12, 8, 12, 20),
                          itemCount: entries.length,
                          separatorBuilder: (_, __) => const Divider(
                            color: Colors.white12,
                            height: 1,
                          ),
                          itemBuilder: (context, index) {
                            final entry = entries[index];
                            final readOnly =
                                widget.section == _SettingsSection.prop &&
                                entry.key.startsWith('ro.');

                            return Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  flex: 5,
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 10,
                                      horizontal: 8,
                                    ),
                                    child: SelectableText(
                                      entry.key,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontFamily: 'monospace',
                                        fontSize: 12,
                                      ),
                                    ),
                                  ),
                                ),
                                Expanded(
                                  flex: 5,
                                  child: InkWell(
                                    onTap: () => _editEntry(entry),
                                    borderRadius: BorderRadius.circular(8),
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        vertical: 10,
                                        horizontal: 8,
                                      ),
                                      child: Row(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Expanded(
                                            child: Text(
                                              entry.value.isEmpty
                                                  ? '(empty)'
                                                  : entry.value,
                                              style: const TextStyle(
                                                color: Colors.white,
                                                fontFamily: 'monospace',
                                                fontSize: 12,
                                              ),
                                            ),
                                          ),
                                          const SizedBox(width: 6),
                                          Icon(
                                            readOnly
                                                ? Icons.lock_outline
                                                : Icons.edit_outlined,
                                            color: Colors.white54,
                                            size: 16,
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            );
                          },
                        ),
            ),
          ],
        ),
      ),
    );
  }
}

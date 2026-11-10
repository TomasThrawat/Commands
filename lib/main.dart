import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

int _commandSequence = 0;

int _nextCommandId() => ++_commandSequence;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const CommandsApp());
}

const MethodChannel _platformChannel =
    MethodChannel('com.hyouka.commands/shizuku');

Color _surfaceColor(BuildContext context) =>
    Theme.of(context).colorScheme.surface;

Color _textColor(BuildContext context) =>
    Theme.of(context).colorScheme.onSurface;

Color _mutedTextColor(BuildContext context, double opacity) =>
    _textColor(context).withAlpha((255 * opacity).round());

ThemeData _buildAppTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final surface = dark ? Colors.black : Colors.white;
  final foreground = dark ? Colors.white : Colors.black;
  final scheme = dark
      ? const ColorScheme.dark(
          surface: Colors.black,
          surfaceContainer: Colors.black,
          primary: Colors.white,
          onPrimary: Colors.black,
          secondary: Colors.white,
          onSecondary: Colors.black,
          onSurface: Colors.white,
        )
      : const ColorScheme.light(
          surface: Colors.white,
          surfaceContainer: Colors.white,
          primary: Colors.black,
          onPrimary: Colors.white,
          secondary: Colors.black,
          onSecondary: Colors.white,
          onSurface: Colors.black,
        );
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    scaffoldBackgroundColor: surface,
    canvasColor: surface,
    colorScheme: scheme,
    appBarTheme: AppBarTheme(
      backgroundColor: surface,
      foregroundColor: foreground,
      elevation: 0,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: surface,
      enabledBorder: OutlineInputBorder(
        borderSide: BorderSide(color: foreground),
      ),
      focusedBorder: OutlineInputBorder(
        borderSide: BorderSide(color: foreground, width: 2),
      ),
      labelStyle: TextStyle(color: foreground),
      hintStyle: TextStyle(color: foreground),
    ),
  );
}

class _CommandHistoryItem {
  const _CommandHistoryItem({
    required this.command,
    required this.output,
    required this.exitCode,
    required this.cancelled,
    required this.timestamp,
  });

  final String command;
  final String output;
  final int exitCode;
  final bool cancelled;
  final DateTime timestamp;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'command': command,
        'output': output,
        'exitCode': exitCode,
        'cancelled': cancelled,
        'timestamp': timestamp.toIso8601String(),
      };

  factory _CommandHistoryItem.fromJson(Map<String, dynamic> json) {
    return _CommandHistoryItem(
      command: (json['command'] as String? ?? '').substring(
        0,
        (json['command'] as String? ?? '').length.clamp(0, 4096).toInt(),
      ),
      output: (json['output'] as String? ?? '').substring(
        0,
        (json['output'] as String? ?? '').length.clamp(0, 8000).toInt(),
      ),
      exitCode: (json['exitCode'] as num?)?.toInt() ?? -1,
      cancelled: json['cancelled'] == true,
      timestamp: DateTime.tryParse(json['timestamp'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}

class _SettingChange {
  const _SettingChange({
    required this.section,
    required this.key,
    required this.previousValue,
    required this.currentValue,
    required this.timestamp,
  });

  final String section;
  final String key;
  final String previousValue;
  final String currentValue;
  final DateTime timestamp;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'section': section,
        'key': key,
        'previousValue': previousValue,
        'currentValue': currentValue,
        'timestamp': timestamp.toIso8601String(),
      };

  factory _SettingChange.fromJson(Map<String, dynamic> json) =>
      _SettingChange(
        section: json['section'] as String? ?? '',
        key: json['key'] as String? ?? '',
        previousValue: json['previousValue'] as String? ?? '',
        currentValue: json['currentValue'] as String? ?? '',
        timestamp: DateTime.tryParse(json['timestamp'] as String? ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0),
      );
}

class _AppPreferences extends ChangeNotifier {
  ThemeMode themeMode = ThemeMode.dark;
  double fontScale = 1;
  String lastCommand = '';
  List<_CommandHistoryItem> history = const [];
  List<_SettingChange> changes = const [];
  Timer? _saveTimer;

  Future<void> load() async {
    try {
      final raw = await _platformChannel.invokeMethod<Map<dynamic, dynamic>>(
        'loadPreferences',
      );
      final data = Map<String, dynamic>.from(raw ?? const {});
      final themeName = data['themeMode'] as String? ?? 'dark';
      themeMode = ThemeMode.values.firstWhere(
        (mode) => mode.name == themeName,
        orElse: () => ThemeMode.dark,
      );
      final scale = (data['fontScale'] as num?)?.toDouble() ?? 1;
      fontScale = scale.isFinite ? scale.clamp(0.85, 1.4).toDouble() : 1;
      lastCommand = (data['lastCommand'] as String? ?? '').substring(
        0,
        (data['lastCommand'] as String? ?? '').length.clamp(0, 4096).toInt(),
      );
      history = _decodeList(data['historyJson'], _CommandHistoryItem.fromJson)
          .cast<_CommandHistoryItem>()
          .take(20)
          .toList();
      changes = _decodeList(data['changesJson'], _SettingChange.fromJson)
          .cast<_SettingChange>()
          .take(100)
          .toList();
    } catch (_) {
      // Keep safe defaults when stored data is missing or malformed.
    }
    notifyListeners();
  }

  List<T> _decodeList<T>(dynamic raw, T Function(Map<String, dynamic>) parse) {
    if (raw is! String || raw.isEmpty) return <T>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <T>[];
      return decoded
          .whereType<Map>()
          .map((item) => parse(Map<String, dynamic>.from(item)))
          .toList();
    } catch (_) {
      return <T>[];
    }
  }

  void setLastCommand(String value) {
    final safe = value.substring(0, value.length.clamp(0, 4096).toInt());
    if (safe == lastCommand) return;
    lastCommand = safe;
    _scheduleSave();
  }

  void setAppearance(ThemeMode mode, double scale) {
    themeMode = mode;
    fontScale = scale.clamp(0.85, 1.4).toDouble();
    notifyListeners();
    _scheduleSave();
  }

  void addHistory(_CommandHistoryItem item) {
    history = <_CommandHistoryItem>[
      _CommandHistoryItem(
        command: item.command.substring(0, item.command.length.clamp(0, 4096).toInt()),
        output: item.output.substring(0, item.output.length.clamp(0, 4000).toInt()),
        exitCode: item.exitCode,
        cancelled: item.cancelled,
        timestamp: item.timestamp,
      ),
      ...history,
    ].take(20).toList();
    notifyListeners();
    _scheduleSave();
  }

  void clearHistory() {
    history = const [];
    notifyListeners();
    _scheduleSave();
  }

  void recordSettingChange({
    required String section,
    required String key,
    required String previousValue,
    required String currentValue,
  }) {
    changes = <_SettingChange>[
      _SettingChange(
        section: section,
        key: key,
        previousValue: previousValue,
        currentValue: currentValue,
        timestamp: DateTime.now(),
      ),
      ...changes,
    ].take(100).toList();
    notifyListeners();
    _scheduleSave();
  }

  _SettingChange? latestChange(String section, String key) {
    for (final change in changes) {
      if (change.section == section && change.key == key) return change;
    }
    return null;
  }

  String exportBackup() => jsonEncode(<String, dynamic>{
        'schemaVersion': 1,
        'createdAt': DateTime.now().toIso8601String(),
        'themeMode': themeMode.name,
        'fontScale': fontScale,
        'lastCommand': lastCommand,
        'history': history.map((item) => item.toJson()).toList(),
        'changes': changes.map((item) => item.toJson()).toList(),
      });

  bool restoreBackup(String content) {
    try {
      final decoded = jsonDecode(content);
      if (decoded is! Map) return false;
      final data = Map<String, dynamic>.from(decoded);
      if (data['schemaVersion'] != 1) return false;
      final themeName = data['themeMode'] as String? ?? 'dark';
      if (!ThemeMode.values.any((mode) => mode.name == themeName)) return false;
      final rawScale = data['fontScale'];
      if (rawScale is! num || !rawScale.toDouble().isFinite) return false;
      final rawHistory = data['history'];
      final rawChanges = data['changes'];
      if (rawHistory is! List || rawChanges is! List) return false;
      if (rawHistory.length > 20 || rawChanges.length > 100) return false;
      themeMode = ThemeMode.values.firstWhere((mode) => mode.name == themeName);
      fontScale = rawScale.toDouble().clamp(0.85, 1.4).toDouble();
      final command = data['lastCommand'] as String? ?? '';
      lastCommand = command.substring(0, command.length.clamp(0, 4096).toInt());
      history = rawHistory
          .whereType<Map>()
          .map((item) => _CommandHistoryItem.fromJson(
                Map<String, dynamic>.from(item),
              ))
          .toList();
      changes = rawChanges
          .whereType<Map>()
          .map((item) => _SettingChange.fromJson(
                Map<String, dynamic>.from(item),
              ))
          .toList();
      notifyListeners();
      _scheduleSave();
      return true;
    } catch (_) {
      return false;
    }
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 350), _saveNow);
  }

  Future<void> _saveNow() async {
    try {
      await _platformChannel.invokeMethod<bool>(
        'savePreferences',
        <String, dynamic>{
          'themeMode': themeMode.name,
          'fontScale': fontScale,
          'lastCommand': lastCommand,
          'historyJson': jsonEncode(history.map((item) => item.toJson()).toList()),
          'changesJson': jsonEncode(changes.map((item) => item.toJson()).toList()),
        },
      );
    } catch (_) {
      // The app remains usable if the Android preference store is unavailable.
    }
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    super.dispose();
  }
}

class CommandsApp extends StatefulWidget {
  const CommandsApp({super.key});

  @override
  State<CommandsApp> createState() => _CommandsAppState();
}

class _CommandsAppState extends State<CommandsApp> {
  final _AppPreferences preferences = _AppPreferences();

  @override
  void initState() {
    super.initState();
    preferences.load();
  }

  @override
  void dispose() {
    preferences.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: preferences,
      builder: (context, _) => MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'Commands',
        theme: _buildAppTheme(Brightness.light),
        darkTheme: _buildAppTheme(Brightness.dark),
        themeMode: preferences.themeMode,
        builder: (context, child) {
          final systemScale = MediaQuery.textScalerOf(context).scale(1);
          return MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(systemScale * preferences.fontScale),
            ),
            child: child ?? const SizedBox.shrink(),
          );
        },
        home: CommandsPage(preferences: preferences),
      ),
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
    required this.cancelled,
  });

  final String stdout;
  final String stderr;
  final int exitCode;
  final bool cancelled;
}

enum _HomeAction { preferences, history, exportBackup, importBackup, diagnostics }

class CommandsPage extends StatefulWidget {
  const CommandsPage({super.key, required this.preferences});

  final _AppPreferences preferences;

  @override
  State<CommandsPage> createState() => _CommandsPageState();
}

class _CommandsPageState extends State<CommandsPage> {
  static const channel = _platformChannel;

  final commandController = TextEditingController();
  final outputController = ScrollController();
  final commandFocusNode = FocusNode();

  bool running = false;
  bool stopping = false;
  int? activeCommandId;
  bool installed = false;
  bool shizukuRunning = false;
  bool permission = false;
  bool serviceConnected = false;
  bool serviceBinding = false;
  bool refreshingStatus = false;

  String status = 'Checking Shizuku...';
  String terminalText = '';

  @override
  void initState() {
    super.initState();
    commandController.text = widget.preferences.lastCommand;
    widget.preferences.addListener(_syncPreferences);
    refreshStatus();
  }

  void _syncPreferences() {
    if (!mounted) return;
    if (!commandFocusNode.hasFocus &&
        commandController.text != widget.preferences.lastCommand) {
      commandController.value = TextEditingValue(
        text: widget.preferences.lastCommand,
        selection: TextSelection.collapsed(
          offset: widget.preferences.lastCommand.length,
        ),
      );
    }
  }

  @override
  void dispose() {
    widget.preferences.removeListener(_syncPreferences);
    commandController.dispose();
    commandFocusNode.dispose();
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
    if (refreshingStatus) return;
    refreshingStatus = true;
    try {
      final raw = await channel.invokeMethod<Map<dynamic, dynamic>>('status');
      final data = Map<String, dynamic>.from(raw ?? const {});
      if (!mounted) return;
      setState(() {
        installed = data['installed'] == true;
        shizukuRunning = data['running'] == true;
        permission = data['permission'] == true;
        serviceConnected = data['serviceConnected'] == true;
        serviceBinding = data['binding'] == true;
        status = _statusText();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => status = 'Unable to check Shizuku: ' + e.toString());
    } finally {
      refreshingStatus = false;
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
    } catch (e) {
      if (mounted) showMessage('Permission request failed: ' + e.toString());
    }
  }

  Future<_CommandResult> _runShell(String command, int commandId) async {
    final raw = await channel.invokeMethod<Map<dynamic, dynamic>>(
      'runCommand',
      <String, dynamic>{'command': command, 'commandId': commandId},
    );
    final data = Map<String, dynamic>.from(raw ?? const {});
    return _CommandResult(
      stdout: data['stdout'] as String? ?? '',
      stderr: data['stderr'] as String? ?? '',
      exitCode: (data['exitCode'] as num?)?.toInt() ?? -1,
      cancelled: data['cancelled'] == true,
    );
  }

  bool _requiresConfirmation(String command) {
    final pattern = RegExp(
      r'(^|[;&|]\s*)(rm|rmdir|dd|mkfs|reboot|shutdown|poweroff|wipe|resetprop|setprop)\b|\b(settings\s+delete|pm\s+(uninstall|clear|disable-user)|am\s+force-stop)\b',
      caseSensitive: false,
    );
    return pattern.hasMatch(command);
  }

  Future<void> runCommand() async {
    final command = commandController.text.trim();
    if (command.isEmpty || running) return;

    if (_requiresConfirmation(command)) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text('Confirm command'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'This command can change device settings or remove data. Review it before continuing.',
              ),
              const SizedBox(height: 12),
              SelectableText(command),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text('Run command'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }

    await _executeCommand(command);
  }

  Future<void> _executeCommand(String command) async {
    if (command.isEmpty || running || !authorized) return;
    final commandId = _nextCommandId();
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      running = true;
      stopping = false;
      activeCommandId = commandId;
      terminalText = '';
    });

    try {
      final result = await _runShell(command, commandId);
      final parts = <String>[
        if (result.stdout.isNotEmpty) result.stdout.trimRight(),
        if (result.stderr.isNotEmpty) result.stderr.trimRight(),
        if (result.cancelled) 'Command cancelled.',
        if (!result.cancelled && result.exitCode != 0)
          'Command failed with exit code ' +
              result.exitCode.toString() +
              (result.stdout.isEmpty && result.stderr.isEmpty
                  ? ' (no output was returned).'
                  : '.'),
      ];
      if (!mounted) return;
      setState(() => terminalText = parts.join('\n'));
      widget.preferences.addHistory(
        _CommandHistoryItem(
          command: command,
          output: terminalText,
          exitCode: result.exitCode,
          cancelled: result.cancelled,
          timestamp: DateTime.now(),
        ),
      );
    } on PlatformException catch (e) {
      if (mounted) {
        setState(() => terminalText = e.message ?? e.code);
        widget.preferences.addHistory(
          _CommandHistoryItem(command: command, output: terminalText, exitCode: -1, cancelled: false, timestamp: DateTime.now()),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => terminalText = e.toString());
        widget.preferences.addHistory(
          _CommandHistoryItem(command: command, output: terminalText, exitCode: -1, cancelled: false, timestamp: DateTime.now()),
        );
      }
    } finally {
      if (!mounted) return;
      setState(() {
        running = false;
        stopping = false;
        activeCommandId = null;
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

  Future<void> cancelCommand() async {
    final commandId = activeCommandId;
    if (commandId == null || stopping) return;

    setState(() => stopping = true);
    try {
      final accepted = await channel.invokeMethod<bool>(
        'cancelCommand',
        <String, dynamic>{'commandId': commandId},
      );
      if (!mounted) return;
      if (accepted != true) {
        setState(() => stopping = false);
        showMessage('Command is no longer running.');
      }
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() => stopping = false);
      showMessage(e.message ?? e.code);
    } catch (e) {
      if (!mounted) return;
      setState(() => stopping = false);
      showMessage(e.toString());
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
        preferences: widget.preferences,
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
    } catch (e) {
      if (mounted) showMessage('Unable to save output: $e');
    }
  }

  Future<void> _showPreferences() async {
    var selectedTheme = widget.preferences.themeMode;
    var selectedScale = widget.preferences.fontScale;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text('App preferences'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              DropdownButtonFormField<ThemeMode>(
                value: selectedTheme,
                decoration: const InputDecoration(labelText: 'Appearance'),
                items: ThemeMode.values
                    .map((mode) => DropdownMenuItem<ThemeMode>(
                          value: mode,
                          child: Text(mode.name[0].toUpperCase() + mode.name.substring(1)),
                        ))
                    .toList(),
                onChanged: (value) => setDialogState(
                  () => selectedTheme = value ?? ThemeMode.dark,
                ),
              ),
              const SizedBox(height: 20),
              Text('Text size: ${(selectedScale * 100).round()}%'),
              Slider(
                value: selectedScale,
                min: 0.85,
                max: 1.4,
                divisions: 11,
                label: '${(selectedScale * 100).round()}%',
                onChanged: (value) => setDialogState(() => selectedScale = value),
              ),
              Text('Preferences are saved automatically on this device.'),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text('Cancel'),
            ),
            TextButton(
              onPressed: () {
                widget.preferences.setAppearance(selectedTheme, selectedScale);
                Navigator.of(dialogContext).pop();
              },
              child: Text('Save'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showHistory() async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Command history'),
        content: SizedBox(
          width: 600,
          height: MediaQuery.sizeOf(context).height * 0.55,
          child: widget.preferences.history.isEmpty
              ? const Center(child: Text('No commands saved yet.'))
              : ListView.separated(
                  itemCount: widget.preferences.history.length,
                  separatorBuilder: (_, __) => Divider(),
                  itemBuilder: (context, index) {
                    final item = widget.preferences.history[index];
                    final date = item.timestamp.millisecondsSinceEpoch == 0
                        ? 'Unknown date'
                        : item.timestamp.toLocal().toString().split('.').first;
                    return ListTile(
                      title: Text(item.command, maxLines: 2, overflow: TextOverflow.ellipsis),
                      subtitle: Text(
                        '$date · ${item.cancelled ? 'Cancelled' : item.exitCode == 0 ? 'Success' : 'Exit ${item.exitCode}'}\n${item.output}',
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                      isThreeLine: true,
                      onTap: () {
                        commandController.text = item.command;
                        widget.preferences.setLastCommand(item.command);
                        Navigator.of(dialogContext).pop();
                        showMessage('Command loaded into the editor. Review it before running.');
                      },
                    );
                  },
                ),
        ),
        actions: [
          if (widget.preferences.history.isNotEmpty)
            TextButton(
              onPressed: () async {
                final clear = await showDialog<bool>(
                  context: dialogContext,
                  builder: (confirmContext) => AlertDialog(
                    title: Text('Clear command history?'),
                    content: Text('This removes the saved command history from this device.'),
                    actions: [
                      TextButton(onPressed: () => Navigator.of(confirmContext).pop(false), child: Text('Cancel')),
                      TextButton(onPressed: () => Navigator.of(confirmContext).pop(true), child: Text('Clear')),
                    ],
                  ),
                );
                if (clear == true) {
                  widget.preferences.clearHistory();
                  if (mounted) Navigator.of(dialogContext).pop();
                }
              },
              child: Text('Clear history'),
            ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _exportBackup() async {
    try {
      final saved = await channel.invokeMethod<Map<dynamic, dynamic>>(
        'exportBackup',
        <String, dynamic>{'content': widget.preferences.exportBackup()},
      );
      if (!mounted) return;
      final data = Map<String, dynamic>.from(saved ?? const {});
      showMessage(data['success'] == true
          ? 'Backup saved as commands-backup.json in Downloads.'
          : 'Backup could not be saved.');
    } on PlatformException catch (e) {
      if (mounted) showMessage(e.message ?? e.code);
    } catch (e) {
      if (mounted) showMessage('Backup export failed: $e');
    }
  }

  Future<void> _importBackup() async {
    try {
      final content = await channel.invokeMethod<String>('importBackup');
      if (!mounted || content == null || content.isEmpty) return;
      Map<String, dynamic> preview;
      try {
        final decoded = jsonDecode(content);
        if (decoded is! Map) throw const FormatException('Backup must be a JSON object.');
        preview = Map<String, dynamic>.from(decoded);
      } catch (e) {
        showMessage('Invalid backup file: $e');
        return;
      }
      final historyCount = preview['history'] is List ? (preview['history'] as List).length : 0;
      final accepted = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text('Restore app backup?'),
          content: Text(
            'This backup contains $historyCount command-history items. It will replace app preferences and local history only. It will not execute commands or change Android settings.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: Text('Cancel')),
            TextButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: Text('Restore')),
          ],
        ),
      );
      if (accepted != true || !mounted) return;
      if (!widget.preferences.restoreBackup(content)) {
        showMessage('Backup format or version is not supported.');
      } else {
        showMessage('App preferences and history restored.');
      }
    } on PlatformException catch (e) {
      if (mounted && e.code != 'BACKUP_IMPORT_CANCELLED') showMessage(e.message ?? e.code);
    } catch (e) {
      if (mounted) showMessage('Backup import failed: $e');
    }
  }

  Future<void> _showDiagnostics() async {
    await refreshStatus();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Shizuku diagnostics'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _diagnosticLine('Installed', installed),
            _diagnosticLine('Service running', shizukuRunning),
            _diagnosticLine('Permission granted', permission),
            _diagnosticLine('UserService connected', serviceConnected),
            _diagnosticLine('Connection pending', serviceBinding),
            const SizedBox(height: 10),
            Text(status),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: Text('Close')),
        ],
      ),
    );
  }

  Widget _diagnosticLine(String label, bool value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          children: [
            Expanded(child: Text(label)),
            Icon(value ? Icons.check_circle_outline : Icons.error_outline, size: 18),
            const SizedBox(width: 6),
            Text(value ? 'Yes' : 'No'),
          ],
        ),
      );

  void _handleHomeAction(_HomeAction action) {
    switch (action) {
      case _HomeAction.preferences:
        _showPreferences();
        break;
      case _HomeAction.history:
        _showHistory();
        break;
      case _HomeAction.exportBackup:
        _exportBackup();
        break;
      case _HomeAction.importBackup:
        _importBackup();
        break;
      case _HomeAction.diagnostics:
        _showDiagnostics();
        break;
    }
  }

  void showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          backgroundColor: _surfaceColor(context),
          content: Text(message, style: TextStyle(color: _textColor(context))),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Commands'),
        actions: [
          PopupMenuButton<_HomeAction>(
            tooltip: 'More options',
            onSelected: _handleHomeAction,
            itemBuilder: (context) => const [
              PopupMenuItem(value: _HomeAction.preferences, child: Text('App preferences')),
              PopupMenuItem(value: _HomeAction.history, child: Text('Command history')),
              PopupMenuItem(value: _HomeAction.exportBackup, child: Text('Export backup')),
              PopupMenuItem(value: _HomeAction.importBackup, child: Text('Import backup')),
              PopupMenuItem(value: _HomeAction.diagnostics, child: Text('Shizuku diagnostics')),
            ],
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: terminalText.isEmpty ? null : saveOutput,
              style: OutlinedButton.styleFrom(
                foregroundColor: _textColor(context),
                side: BorderSide(color: _textColor(context)),
                padding: const EdgeInsets.symmetric(
                  vertical: 15,
                  horizontal: 16,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              icon: Icon(Icons.save_outlined),
              label: Text('Save Output'),
            ),
          ),
        ),
      ),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: refreshStatus,
          color: _textColor(context),
          backgroundColor: _surfaceColor(context),
          child: SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!authorized) ...[
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: _surfaceColor(context),
                      border: Border.all(color: _textColor(context)),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.terminal, color: _textColor(context)),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            status,
                            style: TextStyle(color: _textColor(context)),
                          ),
                        ),
                        if (installed && shizukuRunning && !permission)
                          OutlinedButton(
                            onPressed: requestPermission,
                            style: OutlinedButton.styleFrom(
                              foregroundColor: _textColor(context),
                              side: BorderSide(color: _textColor(context)),
                            ),
                            child: Text('Grant'),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 18),
                ],
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Settings',
                        style: TextStyle(
                          color: _textColor(context),
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    if (authorized)
                      Icon(
                        Icons.check_circle_outline,
                        color: _textColor(context),
                        size: 19,
                      ),
                  ],
                ),
                const SizedBox(height: 10),
                PopupMenuButton<_SettingsSection>(
                  tooltip: 'Choose settings section',
                  onSelected: _openSettingsSection,
                  color: _surfaceColor(context),
                  itemBuilder: (context) => _SettingsSection.values
                      .map(
                        (section) => PopupMenuItem<_SettingsSection>(
                          value: section,
                          enabled: authorized,
                          child: Text(
                            section.title,
                            style: TextStyle(color: _textColor(context)),
                          ),
                        ),
                      )
                      .toList(),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      vertical: 15,
                      horizontal: 14,
                    ),
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: authorized ? _textColor(context) : _mutedTextColor(context, 0.38),
                      ),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.tune,
                          color: authorized ? _textColor(context) : _mutedTextColor(context, 0.38),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'Choose settings section',
                            style: TextStyle(
                              color: authorized ? _textColor(context) : _mutedTextColor(context, 0.38),
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        Icon(
                          Icons.expand_more,
                          color: authorized ? _textColor(context) : _mutedTextColor(context, 0.38),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                Divider(color: _mutedTextColor(context, 0.24), height: 1),
                const SizedBox(height: 18),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Shell command',
                        style: TextStyle(
                          color: _textColor(context),
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    Icon(
                      Icons.terminal,
                      color: _textColor(context),
                      size: 19,
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: commandController,
                  focusNode: commandFocusNode,
                  onChanged: widget.preferences.setLastCommand,
                  enabled: authorized && !running,
                  minLines: 1,
                  maxLines: 5,
                  keyboardType: TextInputType.multiline,
                  style: TextStyle(
                    color: _textColor(context),
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
                    onPressed: !authorized || (running && stopping)
                        ? null
                        : running
                            ? cancelCommand
                            : runCommand,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: _textColor(context),
                      disabledForegroundColor: _mutedTextColor(context, 0.38),
                      side: BorderSide(color: _textColor(context)),
                    ),
                    icon: running
                        ? Icon(Icons.stop, color: _textColor(context))
                        : Icon(Icons.play_arrow, color: _textColor(context)),
                    label: Text(
                      running ? (stopping ? 'Stopping...' : 'Stop') : 'Run',
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Divider(color: _mutedTextColor(context, 0.24), height: 1),
                const SizedBox(height: 18),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Output',
                        style: TextStyle(
                          color: _textColor(context),
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    Icon(
                      terminalText.isEmpty
                          ? Icons.article_outlined
                          : Icons.article,
                      color: _textColor(context),
                      size: 19,
                    ),
                  ],
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
                            style: TextStyle(
                              color: _textColor(context),
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
      ),
    );
  }
}

class _SectionDialog extends StatefulWidget {
  const _SectionDialog({
    required this.section,
    required this.channel,
    required this.parentContext,
    required this.preferences,
  });

  final _SettingsSection section;
  final MethodChannel channel;
  final BuildContext parentContext;
  final _AppPreferences preferences;

  @override
  State<_SectionDialog> createState() => _SectionDialogState();
}

class _SectionDialogState extends State<_SectionDialog> {
  List<_SettingEntry> entries = const [];
  List<_SettingEntry> visibleEntries = const [];
  bool loading = true;
  bool _reloadInProgress = false;
  String? error;
  bool searching = false;
  final searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    searchController.dispose();
    super.dispose();
  }

  String _shellQuote(String value) =>
      "'" + value.replaceAll("'", "'\\''") + "'";

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

  String _deleteCommand(String key) {
    if (widget.section == _SettingsSection.prop) {
      return "if command -v resetprop >/dev/null 2>&1; then resetprop -d " +
          _shellQuote(key) +
          "; else echo 'resetprop is unavailable; property deletion needs a compatible root utility.' >&2; exit 127; fi";
    }
    return 'settings delete ' +
        widget.section.title.toLowerCase() +
        ' ' +
        _shellQuote(key);
  }

  Future<_CommandResult> _run(String command) async {
    final raw = await widget.channel.invokeMethod<Map<dynamic, dynamic>>(
      'runCommand',
      <String, dynamic>{
        'command': command,
        'commandId': _nextCommandId(),
      },
    );
    final data = Map<String, dynamic>.from(raw ?? const {});
    return _CommandResult(
      stdout: data['stdout'] as String? ?? '',
      stderr: data['stderr'] as String? ?? '',
      exitCode: (data['exitCode'] as num?)?.toInt() ?? -1,
      cancelled: data['cancelled'] == true,
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

  void _applySearch() {
    final query = searchController.text.trim().toLowerCase();
    visibleEntries = query.isEmpty
        ? entries
        : entries
            .where(
              (entry) =>
                  entry.key.toLowerCase().contains(query) ||
                  entry.value.toLowerCase().contains(query),
            )
            .toList(growable: false);
  }

  Future<void> _reload() async {
    if (_reloadInProgress) return;
    _reloadInProgress = true;
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
              ? 'Unable to read ' + widget.section.title +
                  ' (exit code ' + result.exitCode.toString() + ').'
              : result.stderr.trim();
        });
        return;
      }

      final parsed = _parse(result.stdout);
      setState(() {
        loading = false;
        entries = parsed;
        _applySearch();
        error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        loading = false;
        error = e.toString();
      });
    } finally {
      _reloadInProgress = false;
    }
  }

  TextSpan _highlightedSpan(String value, String query, TextStyle style) {
    if (query.isEmpty) return TextSpan(text: value, style: style);
    final lower = value.toLowerCase();
    final needle = query.toLowerCase();
    final spans = <TextSpan>[];
    var cursor = 0;
    while (true) {
      final match = lower.indexOf(needle, cursor);
      if (match < 0) {
        if (cursor < value.length) {
          spans.add(TextSpan(text: value.substring(cursor)));
        }
        break;
      }
      if (match > cursor) {
        spans.add(TextSpan(text: value.substring(cursor, match)));
      }
      spans.add(
        TextSpan(
          text: value.substring(match, match + needle.length),
          style: TextStyle(
            backgroundColor: Theme.of(context).colorScheme.primary.withAlpha(70),
            fontWeight: FontWeight.w700,
          ),
        ),
      );
      cursor = match + needle.length;
    }
    return TextSpan(style: style, children: spans);
  }

  Future<void> _editEntry(_SettingEntry entry) async {
    final controller = TextEditingController(text: entry.value);
    final readOnly =
        widget.section == _SettingsSection.prop && entry.key.startsWith('ro.');

    try {
      final apply = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          backgroundColor: _surfaceColor(dialogContext),
          title: Text(
            entry.key,
            style: TextStyle(color: _textColor(dialogContext)),
          ),
          content: TextField(
            controller: controller,
            readOnly: readOnly,
            autofocus: !readOnly,
            minLines: 1,
            maxLines: 8,
            style: TextStyle(
              color: _textColor(dialogContext),
              fontFamily: 'monospace',
            ),
            decoration: InputDecoration(
              labelText: readOnly ? 'Read-only value' : 'Value',
              border: const OutlineInputBorder(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            if (!readOnly)
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: const Text('Apply'),
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
        showMessage(_failureDetails(result));
        return;
      }

      final verified = await _run(_getCommand(entry.key));
      if (!mounted) return;
      final actualValue = verified.stdout.trim();
      if (verified.exitCode != 0) {
        showMessage(
          verified.stderr.trim().isEmpty
              ? 'Value was applied, but verification failed (exit code ' +
                  verified.exitCode.toString() + ').'
              : verified.stderr.trim(),
        );
      } else if (actualValue == controller.text) {
        showMessage('Value applied and verified.');
      } else {
        showMessage('Value was applied, but the system returned a different value.');
      }
      if (actualValue != entry.value) {
        widget.preferences.recordSettingChange(
          section: widget.section.title,
          key: entry.key,
          previousValue: entry.value,
          currentValue: actualValue,
        );
      }
      await _reload();
    } catch (e) {
      if (mounted) showMessage('Unable to apply value: $e');
    } finally {
      controller.dispose();
    }
  }

  String _failureDetails(_CommandResult result) {
    final details = result.stderr.trim().isNotEmpty
        ? result.stderr.trim()
        : result.stdout.trim().isNotEmpty
            ? result.stdout.trim()
            : 'Command failed with exit code ${result.exitCode}.';
    return details;
  }

  Future<void> _deleteEntry(_SettingEntry entry) async {
    final readOnly =
        widget.section == _SettingsSection.prop && entry.key.startsWith('ro.');
    if (readOnly) {
      showMessage('Read-only ro.* properties cannot be deleted here.');
      return;
    }

    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete setting?'),
        content: Text(
          'Delete "${entry.key}" from ${widget.section.title}? The stored value will be removed from Android settings.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (accepted != true || !mounted) return;

    try {
      final result = await _run(_deleteCommand(entry.key));
      if (!mounted) return;
      if (result.exitCode != 0) {
        showMessage(_failureDetails(result));
        return;
      }

      final verified = await _run(_getCommand(entry.key));
      if (!mounted) return;
      final remaining = verified.stdout.trim();
      final removed = widget.section == _SettingsSection.prop
          ? remaining.isEmpty
          : remaining.isEmpty || remaining.toLowerCase() == 'null';
      if (verified.exitCode != 0 || !removed) {
        showMessage(
          verified.stderr.trim().isNotEmpty
              ? verified.stderr.trim()
              : 'Delete ran, but the value is still present or could not be verified.',
        );
        await _reload();
        return;
      }

      widget.preferences.recordSettingChange(
        section: widget.section.title,
        key: entry.key,
        previousValue: entry.value,
        currentValue: '(deleted)',
      );
      await _reload();
      if (mounted) showMessage('Setting deleted.');
    } catch (e) {
      if (mounted) showMessage('Unable to delete setting: $e');
    }
  }

  void showMessage(String message) {
    ScaffoldMessenger.of(widget.parentContext)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          backgroundColor: _surfaceColor(widget.parentContext),
          content: Text(
            message,
            style: TextStyle(color: _textColor(widget.parentContext)),
          ),
        ),
      );
  }

  Widget _buildEntry(_SettingEntry entry) {
    final readOnly =
        widget.section == _SettingsSection.prop && entry.key.startsWith('ro.');
    final change = widget.preferences.latestChange(widget.section.title, entry.key);
    final query = searchController.text.trim();
    final textStyle = TextStyle(
      color: _textColor(context),
      fontFamily: 'monospace',
      fontSize: 12,
    );

    return RepaintBoundary(
      child: Tooltip(
        message: readOnly
            ? 'Read-only property. Long-press is unavailable.'
            : 'Tap the value to edit. Long-press anywhere on this row to delete.',
        child: GestureDetector(
          key: ValueKey('setting-row-${entry.key}'),
          behavior: HitTestBehavior.opaque,
          onLongPress: () => _deleteEntry(entry),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 5,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
                  child: Text.rich(
                    _highlightedSpan(entry.key, query, textStyle),
                    key: ValueKey('setting-key-${entry.key}'),
                  ),
                ),
              ),
              Expanded(
                flex: 5,
                child: InkWell(
                  onTap: () => _editEntry(entry),
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Text.rich(
                                _highlightedSpan(
                                  entry.value.isEmpty ? '(empty)' : entry.value,
                                  query,
                                  textStyle,
                                ),
                                key: ValueKey('setting-value-${entry.key}'),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Icon(
                              readOnly ? Icons.lock_outline : Icons.edit_outlined,
                              color: _mutedTextColor(context, 0.54),
                              size: 16,
                            ),
                          ],
                        ),
                        if (change != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              'Before: ${change.previousValue}  →  Now: ${change.currentValue}',
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.primary,
                                fontSize: 10,
                              ),
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
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: _surfaceColor(context),
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
                      style: TextStyle(
                        color: _textColor(context),
                        fontSize: 21,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: loading ? null : () => setState(() => searching = true),
                    tooltip: 'Search',
                    icon: Icon(Icons.search, color: _textColor(context)),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    tooltip: 'Close',
                    icon: Icon(Icons.close, color: _textColor(context)),
                  ),
                ],
              ),
            ),
            Divider(color: _mutedTextColor(context, 0.24), height: 1),
            if (searching)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 2),
                child: TextField(
                  controller: searchController,
                  autofocus: true,
                  onChanged: (_) => setState(_applySearch),
                  style: TextStyle(
                    color: _textColor(context),
                    fontFamily: 'monospace',
                  ),
                  decoration: InputDecoration(
                    prefixIcon: Icon(Icons.search, color: _textColor(context)),
                    hintText: 'Search by key or value',
                    suffixIcon: IconButton(
                      onPressed: () {
                        searchController.clear();
                        setState(() {
                          searching = false;
                          _applySearch();
                        });
                      },
                      tooltip: 'Close search',
                      icon: Icon(Icons.close, color: _textColor(context)),
                    ),
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Tap a value to edit · Long-press a row to delete',
                      style: TextStyle(
                        color: _mutedTextColor(context, 0.7),
                        fontSize: 11,
                      ),
                    ),
                  ),
                  Text(
                    '${visibleEntries.length} results',
                    style: TextStyle(
                      color: _mutedTextColor(context, 0.7),
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: RefreshIndicator(
                onRefresh: _reload,
                color: _textColor(context),
                backgroundColor: _surfaceColor(context),
                child: loading
                    ? ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        children: [
                          SizedBox(
                            height: 320,
                            child: Center(
                              child: CircularProgressIndicator(
                                color: _textColor(context),
                              ),
                            ),
                          ),
                        ],
                      )
                    : error != null
                        ? ListView(
                            physics: const AlwaysScrollableScrollPhysics(),
                            children: [
                              SizedBox(
                                height: 320,
                                child: Center(
                                  child: Padding(
                                    padding: const EdgeInsets.all(24),
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          error!,
                                          textAlign: TextAlign.center,
                                          style: TextStyle(color: _textColor(context)),
                                        ),
                                        const SizedBox(height: 12),
                                        OutlinedButton.icon(
                                          onPressed: _reload,
                                          icon: const Icon(Icons.refresh),
                                          label: const Text('Try again'),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          )
                        : visibleEntries.isEmpty
                            ? ListView(
                                physics: const AlwaysScrollableScrollPhysics(),
                                children: [
                                  SizedBox(
                                    height: 300,
                                    child: Center(
                                      child: Text(
                                        searchController.text.isEmpty
                                            ? 'No values were returned.'
                                            : 'No matching settings.',
                                        style: TextStyle(color: _textColor(context)),
                                      ),
                                    ),
                                  ),
                                ],
                              )
                            : ListView.separated(
                                physics: const AlwaysScrollableScrollPhysics(),
                                padding: const EdgeInsets.fromLTRB(12, 8, 12, 20),
                                itemCount: visibleEntries.length,
                                separatorBuilder: (_, __) => Divider(
                                  color: _mutedTextColor(context, 0.12),
                                  height: 1,
                                ),
                                itemBuilder: (context, index) =>
                                    _buildEntry(visibleEntries[index]),
                              ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

import 'dart:async';
import 'dart:convert';

import 'package:commands/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.hyouka.commands/shizuku');
  Completer<Map<String, dynamic>>? pendingShellResult;
  Map<String, dynamic>? lastRunArguments;
  Map<String, dynamic>? lastCancelArguments;
  Map<String, dynamic>? lastSavedPreferences;
  String? lastExportContent;
  bool systemBrightnessDeleted = false;
  bool globalSettingDeleted = false;
  bool secureSettingDeleted = false;
  bool propSettingDeleted = false;
  int statusCallCount = 0;
  final executedCommands = <String>[];

  Map<String, dynamic> shellResult({
    String stdout = '',
    String stderr = '',
    int exitCode = 0,
    bool cancelled = false,
  }) => <String, dynamic>{
    'stdout': stdout,
    'stderr': stderr,
    'exitCode': exitCode,
    'cancelled': cancelled,
  };

  setUp(() {
    pendingShellResult = null;
    lastRunArguments = null;
    lastCancelArguments = null;
    lastSavedPreferences = null;
    lastExportContent = null;
    systemBrightnessDeleted = false;
    globalSettingDeleted = false;
    secureSettingDeleted = false;
    propSettingDeleted = false;
    statusCallCount = 0;
    executedCommands.clear();

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'status') {
        statusCallCount++;
        return <String, dynamic>{
          'installed': true,
          'running': true,
          'permission': true,
          'serviceConnected': false,
          'binding': false,
        };
      }

      if (call.method == 'loadPreferences') {
        return <String, dynamic>{
          'themeMode': 'dark',
          'fontScale': 1.0,
          'lastCommand': '',
          'historyJson': '[]',
          'changesJson': '[]',
        };
      }

      if (call.method == 'savePreferences') {
        lastSavedPreferences = Map<String, dynamic>.from(
          call.arguments as Map<dynamic, dynamic>,
        );
        return true;
      }

      if (call.method == 'exportBackup') {
        lastExportContent = (call.arguments as Map<dynamic, dynamic>)['content'] as String;
        return <String, dynamic>{'success': true, 'filename': 'commands-backup.json'};
      }

      if (call.method == 'importBackup') {
        return jsonEncode(<String, dynamic>{
          'schemaVersion': 1,
          'themeMode': 'light',
          'fontScale': 1.1,
          'lastCommand': 'echo restored',
          'history': <dynamic>[
            <String, dynamic>{
              'command': 'echo previous',
              'output': 'previous output',
              'exitCode': 0,
              'cancelled': false,
              'timestamp': DateTime(2026, 1, 1).toIso8601String(),
            },
          ],
          'changes': <dynamic>[],
        });
      }

      if (call.method == 'cancelCommand') {
        lastCancelArguments = Map<String, dynamic>.from(
          call.arguments as Map<dynamic, dynamic>,
        );
        return true;
      }

      if (call.method == 'runCommand') {
        final args = Map<String, dynamic>.from(
          call.arguments as Map<dynamic, dynamic>,
        );
        lastRunArguments = args;
        final command = args['command'] as String;
        executedCommands.add(command);

        if (command == 'sleep 180' && pendingShellResult != null) {
          return pendingShellResult!.future;
        }
        if (command == 'echo history-test') return shellResult(stdout: 'history output\n');
        if (command == "settings list system") {
          final brightness = systemBrightnessDeleted ? '' : 'screen_brightness=150\n';
          return shellResult(stdout: '${brightness}font_scale=1.0\n');
        }
        if (command == "settings get system 'screen_brightness'") {
          return shellResult(stdout: systemBrightnessDeleted ? 'null\n' : '150\n');
        }
        if (command == "settings delete system 'screen_brightness'") {
          systemBrightnessDeleted = true;
          return shellResult(stdout: 'Deleted 1 rows\n');
        }
        if (command == 'settings list global') {
          return shellResult(stdout: globalSettingDeleted ? '' : 'airplane_mode_on=0\n');
        }
        if (command == "settings get global 'airplane_mode_on'") {
          return shellResult(stdout: globalSettingDeleted ? 'null\n' : '0\n');
        }
        if (command == "settings delete global 'airplane_mode_on'") {
          globalSettingDeleted = true;
          return shellResult(stdout: 'Deleted 1 rows\n');
        }
        if (command == 'settings list secure') {
          return shellResult(stdout: secureSettingDeleted ? '' : 'accessibility_enabled=0\n');
        }
        if (command == "settings get secure 'accessibility_enabled'") {
          return shellResult(stdout: secureSettingDeleted ? 'null\n' : '0\n');
        }
        if (command == "settings delete secure 'accessibility_enabled'") {
          secureSettingDeleted = true;
          return shellResult(stdout: 'Deleted 1 rows\n');
        }
        if (command == 'getprop') {
          return shellResult(
            stdout: [
              if (!propSettingDeleted) '[persist.sys.test]: [1]',
              '[ro.build.version.sdk]: [35]',
              '',
            ].join('\n'),
          );
        }
        if (command == "getprop 'persist.sys.test'") {
          return shellResult(stdout: propSettingDeleted ? '' : '1\n');
        }
        if (command == "resetprop -d 'persist.sys.test'") {
          propSettingDeleted = true;
          return shellResult();
        }
        if (command == "getprop 'ro.build.version.sdk'") {
          return shellResult(stdout: '35\n');
        }
        if (command == 'settings get system font_scale') {
          return shellResult(stdout: '1.0\n');
        }
      }

      return <String, dynamic>{
        'stdout': '',
        'stderr': '',
        'exitCode': 0,
        'cancelled': false,
        'success': true,
      };
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Future<void> openSection(WidgetTester tester, String section) async {
    await tester.tap(find.text('Choose settings section'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(section).last);
    await tester.pumpAndSettle();
  }

  testWidgets('shell commands have no timeout and can be stopped manually',
      (tester) async {
    pendingShellResult = Completer<Map<String, dynamic>>();
    await tester.pumpWidget(const CommandsApp());
    await tester.pumpAndSettle();

    final commandField = find.byWidgetPredicate(
      (widget) =>
          widget is TextField &&
          widget.decoration?.hintText == 'Enter a shell command',
    );
    await tester.enterText(commandField, 'sleep 180');
    await tester.tap(find.text('Run'));
    await tester.pump();

    expect(lastRunArguments, isNotNull);
    final commandId = lastRunArguments!['commandId'];
    expect(
      lastRunArguments,
      <String, dynamic>{'command': 'sleep 180', 'commandId': commandId},
    );
    expect(commandId, isA<int>());
    expect(find.text('Stop'), findsOneWidget);

    await tester.tap(find.text('Stop'));
    await tester.pump();
    expect(lastCancelArguments?['commandId'], commandId);

    pendingShellResult!.complete(<String, dynamic>{
      'stdout': '',
      'stderr': '',
      'exitCode': -1,
      'cancelled': true,
    });
    await tester.pumpAndSettle();
    expect(find.textContaining('Command cancelled.'), findsOneWidget);
  });

  testWidgets('groups settings sections and keeps Save at the bottom',
      (tester) async {
    await tester.pumpWidget(const CommandsApp());
    await tester.pumpAndSettle();

    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('Choose settings section'), findsOneWidget);
    expect(find.text('System'), findsNothing);
    expect(find.text('Global'), findsNothing);
    expect(find.text('Secure'), findsNothing);
    expect(find.text('Prop'), findsNothing);
    expect(find.byType(RefreshIndicator), findsOneWidget);
    expect(find.byTooltip('Refresh'), findsNothing);
    expect(find.byType(FloatingActionButton), findsNothing);
    expect(find.text('Save Output'), findsOneWidget);
    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold).first);
    expect(scaffold.bottomNavigationBar, isA<SafeArea>());

    await tester.tap(find.text('Choose settings section'));
    await tester.pumpAndSettle();
    expect(find.text('System'), findsOneWidget);
    expect(find.text('Global'), findsOneWidget);
    expect(find.text('Secure'), findsOneWidget);
    expect(find.text('Prop'), findsOneWidget);
  });

  testWidgets('pulling down refreshes Shizuku status', (tester) async {
    await tester.pumpWidget(const CommandsApp());
    await tester.pumpAndSettle();
    final initialCalls = statusCallCount;

    await tester.drag(
      find.byType(SingleChildScrollView).first,
      const Offset(0, 360),
    );
    await tester.pump();
    await tester.pumpAndSettle();

    expect(statusCallCount, greaterThan(initialCalls));
  });

  testWidgets('System reads values and tapping a value opens editor',
      (tester) async {
    await tester.pumpWidget(const CommandsApp());
    await tester.pumpAndSettle();
    await openSection(tester, 'System');

    expect(find.byType(RefreshIndicator), findsNWidgets(2));
    expect(find.byKey(const ValueKey('setting-key-screen_brightness')), findsOneWidget);
    expect(find.byKey(const ValueKey('setting-value-screen_brightness')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('setting-value-screen_brightness')));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('Apply'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);
  });

  testWidgets('search filters settings and highlights matching text', (tester) async {
    await tester.pumpWidget(const CommandsApp());
    await tester.pumpAndSettle();
    await openSection(tester, 'System');

    expect(find.byTooltip('Search'), findsOneWidget);
    await tester.tap(find.byTooltip('Search'));
    await tester.pumpAndSettle();

    final searchField = find.byWidgetPredicate(
      (widget) =>
          widget is TextField &&
          widget.decoration?.hintText == 'Search by key or value',
    );
    expect(searchField, findsOneWidget);
    await tester.enterText(searchField, 'screen');
    await tester.pump();

    expect(find.byKey(const ValueKey('setting-key-screen_brightness')), findsOneWidget);
    expect(find.byKey(const ValueKey('setting-key-font_scale')), findsNothing);
  });

  testWidgets('long-press deletes an item in each of the four sections',
      (tester) async {
    await tester.pumpWidget(const CommandsApp());
    await tester.pumpAndSettle();

    final cases = <(String, String, String)>[
      ('System', 'screen_brightness', "settings delete system 'screen_brightness'"),
      ('Global', 'airplane_mode_on', "settings delete global 'airplane_mode_on'"),
      ('Secure', 'accessibility_enabled', "settings delete secure 'accessibility_enabled'"),
      ('Prop', 'persist.sys.test', "resetprop -d 'persist.sys.test'"),
    ];

    for (final item in cases) {
      await openSection(tester, item.$1);
      final row = find.byKey(ValueKey('setting-row-${item.$2}'));
      expect(row, findsOneWidget);
      await tester.longPress(row);
      await tester.pumpAndSettle();
      expect(find.text('Delete setting?'), findsOneWidget);
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      if (item.$1 == 'Prop') {
        expect(
          executedCommands.any((command) => command.contains(item.$3)),
          isTrue,
        );
      } else {
        expect(executedCommands, contains(item.$3));
      }
      expect(find.byKey(ValueKey('setting-row-${item.$2}')), findsNothing);
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
    }
  });

  testWidgets('read-only Prop entries cannot be deleted', (tester) async {
    await tester.pumpWidget(const CommandsApp());
    await tester.pumpAndSettle();
    await openSection(tester, 'Prop');

    await tester.longPress(find.byKey(const ValueKey('setting-row-ro.build.version.sdk')));
    await tester.pumpAndSettle();

    expect(find.text('Delete setting?'), findsNothing);
    expect(find.textContaining('Read-only ro.* properties cannot be deleted'), findsOneWidget);
    expect(executedCommands.any((command) => command.contains('ro.build.version.sdk')), isFalse);
  });

  testWidgets('dangerous shell commands require confirmation before execution',
      (tester) async {
    await tester.pumpWidget(const CommandsApp());
    await tester.pumpAndSettle();

    final commandField = find.byWidgetPredicate(
      (widget) =>
          widget is TextField &&
          widget.decoration?.hintText == 'Enter a shell command',
    );
    await tester.enterText(commandField, 'rm -rf /tmp/example');
    await tester.tap(find.text('Run'));
    await tester.pumpAndSettle();

    expect(find.text('Confirm command'), findsOneWidget);
    expect(executedCommands, isEmpty);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(executedCommands, isEmpty);
  });

  testWidgets('command history stores completed commands and can reload one',
      (tester) async {
    await tester.pumpWidget(const CommandsApp());
    await tester.pumpAndSettle();

    final commandField = find.byWidgetPredicate(
      (widget) =>
          widget is TextField &&
          widget.decoration?.hintText == 'Enter a shell command',
    );
    await tester.enterText(commandField, 'echo history-test');
    await tester.tap(find.text('Run'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('More options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Command history'));
    await tester.pumpAndSettle();
    final historyEntry = find.widgetWithText(ListTile, 'echo history-test');
    expect(historyEntry, findsOneWidget);
    await tester.tap(historyEntry);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(commandField).controller!.text, 'echo history-test');
  });

  testWidgets('app preferences autosave and backup export/import work',
      (tester) async {
    await tester.pumpWidget(const CommandsApp());
    await tester.pumpAndSettle();

    final commandField = find.byWidgetPredicate(
      (widget) =>
          widget is TextField &&
          widget.decoration?.hintText == 'Enter a shell command',
    );
    await tester.enterText(commandField, 'echo autosaved');
    await tester.pump(const Duration(milliseconds: 400));
    expect(lastSavedPreferences?['lastCommand'], 'echo autosaved');

    await tester.tap(find.byTooltip('More options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Export backup'));
    await tester.pumpAndSettle();
    expect(lastExportContent, isNotNull);
    expect(jsonDecode(lastExportContent!)['schemaVersion'], 1);

    await tester.tap(find.byTooltip('More options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Import backup'));
    await tester.pumpAndSettle();
    expect(find.text('Restore app backup?'), findsOneWidget);
    await tester.tap(find.text('Restore'));
    await tester.pumpAndSettle();
    expect(tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode, ThemeMode.light);
    expect(tester.widget<TextField>(commandField).controller!.text, 'echo restored');
  });

  testWidgets('Shizuku diagnostics display permission and service state',
      (tester) async {
    await tester.pumpWidget(const CommandsApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('More options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Shizuku diagnostics'));
    await tester.pumpAndSettle();

    expect(find.text('Shizuku diagnostics'), findsOneWidget);
    expect(find.text('Permission granted'), findsOneWidget);
    expect(find.text('UserService connected'), findsOneWidget);
  });
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:commands/main.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.hyouka.commands/shizuku');
  Completer<Map<String, dynamic>>? pendingShellResult;
  Map<String, dynamic>? lastRunArguments;
  Map<String, dynamic>? lastCancelArguments;
  int statusCallCount = 0;

  setUp(() {
    pendingShellResult = null;
    lastRunArguments = null;
    lastCancelArguments = null;
    statusCallCount = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'status') {
        statusCallCount++;
        return <String, dynamic>{
          'installed': true,
          'running': true,
          'permission': true,
        };
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
        if (command == 'sleep 180' && pendingShellResult != null) {
          return pendingShellResult!.future;
        }

        if (command == 'settings list system') {
          return <String, dynamic>{
            'stdout': 'screen_brightness=150\nfont_scale=1.0\n',
            'stderr': '',
            'exitCode': 0,
            'cancelled': false,
          };
        }

        if (command == "settings get system 'screen_brightness'") {
          return <String, dynamic>{
            'stdout': '150\n',
            'stderr': '',
            'exitCode': 0,
            'cancelled': false,
          };
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
    expect(find.text('Shizuku is ready.'), findsNothing);

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

    await tester.tap(find.text('Choose settings section'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('System').last);
    await tester.pumpAndSettle();

    expect(find.byType(RefreshIndicator), findsNWidgets(2));
    expect(find.byTooltip('Refresh'), findsNothing);
    expect(find.text('screen_brightness'), findsOneWidget);
    expect(find.text('150'), findsOneWidget);

    await tester.tap(find.text('150'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('Apply'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);
  });

  testWidgets('settings sections provide searchable values', (tester) async {
    await tester.pumpWidget(const CommandsApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Choose settings section'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('System').last);
    await tester.pumpAndSettle();

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

    expect(find.text('screen_brightness'), findsOneWidget);
    expect(find.text('font_scale'), findsNothing);
  });
}

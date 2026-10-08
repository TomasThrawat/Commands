import 'package:flutter/material.dart';
import 'package:commands/main.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.hyouka.commands/shizuku');

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'status') {
        return <String, dynamic>{
          'installed': true,
          'running': true,
          'permission': true,
        };
      }

      if (call.method != 'runCommand') {
        return <String, dynamic>{'success': true};
      }

      final args = Map<String, dynamic>.from(
        call.arguments as Map<dynamic, dynamic>,
      );
      final command = args['command'] as String;

      if (command == 'settings list system') {
        return <String, dynamic>{
          'stdout': 'screen_brightness=150\nfont_scale=1.0\n',
          'stderr': '',
          'exitCode': 0,
          'timedOut': false,
        };
      }

      if (command == "settings get system 'screen_brightness'") {
        return <String, dynamic>{
          'stdout': '150\n',
          'stderr': '',
          'exitCode': 0,
          'timedOut': false,
        };
      }

      if (command == "settings put system 'screen_brightness' '180'") {
        return <String, dynamic>{
          'stdout': '',
          'stderr': '',
          'exitCode': 0,
          'timedOut': false,
        };
      }

      return <String, dynamic>{
        'stdout': '',
        'stderr': '',
        'exitCode': 0,
        'timedOut': false,
      };
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  testWidgets('renders settings sections', (tester) async {
    await tester.pumpWidget(const CommandsApp());
    await tester.pumpAndSettle();

    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('System'), findsOneWidget);
    expect(find.text('Global'), findsOneWidget);
    expect(find.text('Secure'), findsOneWidget);
    expect(find.text('Prop'), findsOneWidget);
  });

  testWidgets('System reads values and tapping a value opens editor',
      (tester) async {
    await tester.pumpWidget(const CommandsApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('System'));
    await tester.pumpAndSettle();

    expect(find.text('screen_brightness'), findsOneWidget);
    expect(find.text('150'), findsOneWidget);

    await tester.tap(find.text('150'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('Apply'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);
  });
}


  testWidgets('settings sections provide searchable values', (tester) async {
    await tester.pumpWidget(const CommandsApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('System'));
    await tester.pumpAndSettle();

    expect(find.byTooltip('Search'), findsOneWidget);

    await tester.tap(find.byTooltip('Search'));
    await tester.pumpAndSettle();

    expect(find.byType(TextField), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'screen');
    await tester.pump();

    expect(find.text('screen_brightness'), findsOneWidget);
    expect(find.text('font_scale'), findsNothing);
  });

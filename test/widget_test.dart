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

      if (call.method == 'runCommand') {
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

        return <String, dynamic>{
          'stdout': '',
          'stderr': '',
          'exitCode': 0,
          'timedOut': false,
        };
      }

      return <String, dynamic>{'success': true};
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  testWidgets('renders live settings sections', (tester) async {
    await tester.pumpWidget(const CommandsApp());
    await tester.pumpAndSettle();

    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('System'), findsOneWidget);
    expect(find.text('Global'), findsOneWidget);
    expect(find.text('Secure'), findsOneWidget);
    expect(find.text('Prop'), findsOneWidget);
  });

  testWidgets('System reads values and tapping value opens editor',
      (tester) async {
    await tester.pumpWidget(const CommandsApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('System'));
    await tester.pumpAndSettle();

    expect(find.text('screen_brightness'), findsOneWidget);
    expect(find.text('150'), findsOneWidget);

    await tester.tap(find.text('150'));
    await tester.pumpAndSettle();

    expect(find.text('Value'), findsOneWidget);
    expect(find.text('Apply'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);
  });
}

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

  testWidgets('renders the terminal and settings sections', (tester) async {
    await tester.pumpWidget(const CommandsApp());
    await tester.pumpAndSettle();

    expect(find.text('Commands'), findsOneWidget);
    expect(find.text('System'), findsOneWidget);
    expect(find.text('Global'), findsOneWidget);
    expect(find.text('Secure'), findsOneWidget);
    expect(find.text('Prop'), findsOneWidget);
    expect(find.text('Shell command'), findsOneWidget);
    expect(find.text('Save Output'), findsOneWidget);
    expect(find.text('Command being run'), findsNothing);
    expect(find.text('STDOUT'), findsNothing);
    expect(find.text('STDERR'), findsNothing);
    expect(find.text('Exit code'), findsNothing);
  });
}

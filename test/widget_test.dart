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
      return <String, dynamic>{'success': true};
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  testWidgets('renders the Shizuku-ready command terminal UI', (tester) async {
    await tester.pumpWidget(const CommandsApp());
    await tester.pump();

    expect(find.text('Commands'), findsOneWidget);
    expect(find.text('Shizuku ready'), findsOneWidget);
    expect(find.text('Terminal'), findsOneWidget);
    expect(find.text('READY'), findsOneWidget);
    expect(find.text('Type a shell command'), findsOneWidget);
    expect(find.byTooltip('Save output'), findsOneWidget);
  });
}

import 'package:commands/main.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.hyouka.commands/shizuku');

  setUp(() {
    channel.setMockMethodCallHandler((call) async {
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
    channel.setMockMethodCallHandler(null);
  });

  testWidgets('renders Commands UI', (tester) async {
    await tester.pumpWidget(const CommandsApp());
    await tester.pumpAndSettle();

    expect(find.text('Commands'), findsOneWidget);
    expect(find.text('Shell command'), findsOneWidget);
    expect(find.text('Save Output'), findsOneWidget);
  });
}

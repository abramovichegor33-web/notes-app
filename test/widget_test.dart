import 'package:flutter_test/flutter_test.dart';
import 'package:my_notes/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('NotesApp smoke test', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({'user_vault_id': 'TEST-123'});
    await tester.pumpWidget(const NotesApp());
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_quill/flutter_quill.dart';

void main() {
  test('QuillController document assignment works', () {
    final c = QuillController.basic();
    expect(c.document.toPlainText().trim(), isEmpty);

    c.document = Document.fromJson([
      {'insert': 'Updated text\n'}
    ]);
    expect(c.document.toPlainText().trim(), 'Updated text');
  });
}

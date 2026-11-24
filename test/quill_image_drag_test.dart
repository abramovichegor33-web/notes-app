import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';

void moveImageInDocument(QuillController controller, String imageSource, int targetOffset) {
  int currentImageOffset = -1;
  int cur = 0;
  for (final op in controller.document.toDelta().toList()) {
    if (op.data is Map && (op.data as Map)['image'] == imageSource) {
      currentImageOffset = cur;
      break;
    }
    cur += (op.length ?? 1);
  }

  if (currentImageOffset == -1) return;

  // If dropped in the same position, do nothing
  if (targetOffset >= currentImageOffset && targetOffset <= currentImageOffset + 2) {
    return;
  }

  // 1. Delete old image
  int deleteLength = 1;
  final docLen = controller.document.length;
  if (currentImageOffset + 1 < docLen - 1) {
    final nextChar = controller.document.getPlainText(currentImageOffset + 1, 1);
    if (nextChar == '\n') {
      deleteLength = 2;
    }
  }

  controller.replaceText(currentImageOffset, deleteLength, '', null);

  // 2. Adjust target offset
  int adjustedTarget = targetOffset;
  if (targetOffset > currentImageOffset) {
    adjustedTarget = targetOffset - deleteLength;
  }
  adjustedTarget = adjustedTarget.clamp(0, controller.document.length - 1);

  // 3. Insert image cleanly
  final plainText = controller.document.toPlainText();
  final needsLeadingNewline = adjustedTarget > 0 &&
      adjustedTarget <= plainText.length &&
      plainText[adjustedTarget - 1] != '\n';

  final needsTrailingNewline = adjustedTarget >= plainText.length ||
      plainText[adjustedTarget] != '\n';

  int insertPos = adjustedTarget;
  if (needsLeadingNewline) {
    controller.replaceText(insertPos, 0, '\n', null);
    insertPos += 1;
  }

  controller.replaceText(insertPos, 0, BlockEmbed.image(imageSource), null);
  insertPos += 1;

  if (needsTrailingNewline) {
    controller.replaceText(insertPos, 0, '\n', null);
    insertPos += 1;
  }

  controller.updateSelection(
    TextSelection.collapsed(offset: insertPos),
    ChangeSource.local,
  );
}

void main() {
  test('Move image down between paragraphs', () {
    final doc = Document();
    doc.insert(0, "Paragraph 1\n");
    doc.insert(12, BlockEmbed.image("image1.png"));
    doc.insert(13, "\n");
    doc.insert(14, "Paragraph 2\nParagraph 3\n");

    final controller = QuillController(
      document: doc,
      selection: const TextSelection.collapsed(offset: 0),
    );

    // Target is start of Paragraph 3 (index of 'Paragraph 3')
    final targetOffset = controller.document.toPlainText().indexOf("Paragraph 3");

    moveImageInDocument(controller, "image1.png", targetOffset);

    final plain = controller.document.toPlainText();
    expect(plain, equals("Paragraph 1\nParagraph 2\n\uFFFC\nParagraph 3\n\n"));
  });

  test('Move image up to the beginning of document', () {
    final doc = Document();
    doc.insert(0, "Paragraph 1\nParagraph 2\n");
    final p2End = doc.length - 1;
    doc.insert(p2End, BlockEmbed.image("image2.png"));
    doc.insert(p2End + 1, "\n");

    final controller = QuillController(
      document: doc,
      selection: const TextSelection.collapsed(offset: 0),
    );

    moveImageInDocument(controller, "image2.png", 0);

    final plain = controller.document.toPlainText();
    expect(plain, equals("\uFFFC\nParagraph 1\nParagraph 2\n\n"));
  });

  test('Move image into the middle of text splits line cleanly', () {
    final doc = Document();
    doc.insert(0, "Hello World\n");
    doc.insert(12, BlockEmbed.image("image3.png"));
    doc.insert(13, "\n");

    final controller = QuillController(
      document: doc,
      selection: const TextSelection.collapsed(offset: 0),
    );

    // Move to offset 5 (between 'Hello' and ' World')
    moveImageInDocument(controller, "image3.png", 5);

    final plain = controller.document.toPlainText();
    expect(plain, equals("Hello\n\uFFFC\n World\n\n"));
  });
}

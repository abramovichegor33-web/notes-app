import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:image/image.dart' as img;
import 'package:my_notes/notes_screen.dart';

void main() {
  test('Image package can decode and compress to JPG', () {
    final image = img.Image(width: 100, height: 100);
    img.fill(image, color: img.ColorRgb8(255, 0, 0));
    final jpg = img.encodeJpg(image, quality: 80);
    expect(jpg.isNotEmpty, true);
    expect(jpg[0], 0xFF);
    expect(jpg[1], 0xD8); // JPEG SOI marker
  });
  test('QuillController document assignment works', () {
    final c = QuillController.basic();
    expect(c.document.toPlainText().trim(), isEmpty);

    c.document = Document.fromJson([
      {'insert': 'Updated text\n'}
    ]);
    expect(c.document.toPlainText().trim(), 'Updated text');
  });

  test('Swapping image source in Document delta works', () {
    final c = QuillController.basic();
    c.document = Document.fromJson([
      {
        'insert': {'image': 'data:image/png;base64,OLD'}
      },
      {'insert': '\n'}
    ]);

    final jsonList = c.document.toDelta().toJson();
    for (final item in jsonList) {
      final insert = item['insert'];
      if (insert is Map && insert['image'] == 'data:image/png;base64,OLD') {
        insert['image'] = 'https://cloud.com/image.png';
      }
    }
    c.document = Document.fromJson(jsonList);

    final updated = c.document.toDelta().toJson();
    expect(updated[0]['insert']['image'], 'https://cloud.com/image.png');
  });

  test('AppImageCache stores and retrieves image bytes', () {
    final bytes = Uint8List.fromList([1, 2, 3, 4]);
    const url = 'https://cloud.com/test.png';
    AppImageCache.put(url, bytes);
    expect(AppImageCache.get(url), bytes);
  });

  test('dart:ui instantiateImageCodec is available and functional', () async {
    // 1x1 transparent PNG bytes
    final transparentPng = [
      0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
      0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
      0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
      0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
      0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
      0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82
    ];
    final bytes = Uint8List.fromList(transparentPng);
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    expect(frame.image.width, 1);
    expect(frame.image.height, 1);
  });
}

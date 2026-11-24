import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_notes/note_model.dart';
import 'package:my_notes/notes_screen.dart';
import 'package:my_notes/vault_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('CanvasImage serialization and deserialization', () {
    final img = CanvasImage(
      id: 'img_123',
      url: 'https://example.com/test.jpg',
      x: 140.5,
      y: 280.0,
      width: 320.0,
      height: 240.0,
      naturalWidth: 640.0,
      naturalHeight: 480.0,
      aspectRatio: 640.0 / 480.0,
    );

    final json = img.toJson();
    expect(json['id'], equals('img_123'));
    expect(json['url'], equals('https://example.com/test.jpg'));
    expect(json['x'], equals(140.5));
    expect(json['y'], equals(280.0));
    expect(json['width'], equals(320.0));
    expect(json['height'], equals(240.0));
    expect(json['naturalWidth'], equals(640.0));
    expect(json['naturalHeight'], equals(480.0));
    expect(json['aspectRatio'], equals(640.0 / 480.0));

    final parsed = CanvasImage.fromJson(json);
    expect(parsed.id, equals(img.id));
    expect(parsed.url, equals(img.url));
    expect(parsed.x, equals(img.x));
    expect(parsed.y, equals(img.y));
    expect(parsed.width, equals(img.width));
    expect(parsed.height, equals(img.height));
    expect(parsed.naturalWidth, equals(img.naturalWidth));
    expect(parsed.naturalHeight, equals(img.naturalHeight));
    expect(parsed.aspectRatio, equals(img.aspectRatio));
  });

  test('CanvasImage strictly preserves aspect ratio when scaled', () {
    final narrowScreenshot = CanvasImage(
      id: 'img_narrow',
      url: 'https://example.com/narrow.png',
      x: 20.0,
      y: 30.0,
      width: 150.0,
      height: 450.0,
      naturalWidth: 150.0,
      naturalHeight: 450.0,
      aspectRatio: 150.0 / 450.0, // 1/3
    );

    final ar = narrowScreenshot.aspectRatio!;
    expect(ar, closeTo(0.3333, 0.001));

    // Scale up by factor 1.15 (+15%)
    final scaledWidth = narrowScreenshot.width * 1.15;
    final scaledHeight = scaledWidth / ar;
    narrowScreenshot.width = scaledWidth;
    narrowScreenshot.height = scaledHeight;

    expect(narrowScreenshot.width / narrowScreenshot.height!, closeTo(ar, 0.0001));

    // Scale down by factor 1 / 1.15 (-15%)
    final downWidth = narrowScreenshot.width / 1.15;
    final downHeight = downWidth / ar;
    narrowScreenshot.width = downWidth;
    narrowScreenshot.height = downHeight;

    expect(narrowScreenshot.width, closeTo(150.0, 0.001));
    expect(narrowScreenshot.height!, closeTo(450.0, 0.001));
    expect(narrowScreenshot.width / narrowScreenshot.height!, closeTo(ar, 0.0001));
  });

  test('Note content parsing supports both legacy delta and canvas images format', () {
    // 1. Canvas format with delta and images
    final canvasPayload = jsonEncode({
      'delta': [
        {'insert': 'Hello Canvas\n'}
      ],
      'images': [
        {
          'id': 'img_1',
          'url': 'https://example.com/pic.png',
          'x': 50.0,
          'y': 100.0,
          'width': 300.0
        }
      ]
    });

    final decodedMap = jsonDecode(canvasPayload);
    expect(decodedMap is Map, isTrue);
    expect(decodedMap['delta'] is List, isTrue);
    expect(decodedMap['images'] is List, isTrue);

    final images = (decodedMap['images'] as List)
        .map((e) => CanvasImage.fromJson(Map<String, dynamic>.from(e)))
        .toList();
    expect(images.length, equals(1));
    expect(images.first.x, equals(50.0));
    expect(images.first.y, equals(100.0));

    // 2. Legacy delta list format with embedded image
    final legacyPayload = jsonEncode([
      {'insert': 'Legacy Text\n'},
      {
        'insert': {'image': 'https://example.com/legacy.jpg'}
      },
      {'insert': '\nMore text\n'}
    ]);

    final decodedLegacy = jsonDecode(legacyPayload);
    expect(decodedLegacy is List, isTrue);

    final extractedImages = <CanvasImage>[];
    final textOps = <Map<String, dynamic>>[];
    double initialY = 20.0;
    for (final op in decodedLegacy) {
      if (op is Map && op['insert'] is Map && op['insert']['image'] != null) {
        extractedImages.add(CanvasImage(
          id: 'img_extracted_0',
          url: op['insert']['image'].toString(),
          x: 20.0,
          y: initialY,
          width: 320.0,
        ));
        initialY += 240.0;
      } else {
        textOps.add(Map<String, dynamic>.from(op));
      }
    }

    expect(extractedImages.length, equals(1));
    expect(extractedImages.first.url, equals('https://example.com/legacy.jpg'));
    expect(textOps.length, equals(2));
  });

  test('parseNoteContent extracts delta, images, and is_pinned uniformly', () {
    final mapPayload = jsonEncode({
      'delta': [
        {'insert': 'Pinned note\n'}
      ],
      'images': [
        {
          'id': 'img_a',
          'url': 'https://example.com/a.png',
          'x': 10.0,
          'y': 20.0,
          'width': 180.0,
          'height': 360.0,
          'aspectRatio': 0.5,
        }
      ],
      'is_pinned': true,
    });
    final parsedMap = parseNoteContent(mapPayload);
    expect(parsedMap.document.toPlainText().trim(), 'Pinned note');
    expect(parsedMap.images.length, 1);
    expect(parsedMap.images.first.width, 180.0);
    expect(parsedMap.isPinned, isTrue);

    final legacyPayload = jsonEncode([
      {'insert': 'Old note\n'},
      {
        'insert': {'image': 'https://example.com/old.png'}
      },
      {'insert': '\n'}
    ]);
    final parsedLegacy = parseNoteContent(legacyPayload);
    expect(parsedLegacy.document.toPlainText().trim(), 'Old note');
    expect(parsedLegacy.images.length, 1);
    expect(parsedLegacy.images.first.url, 'https://example.com/old.png');
    expect(parsedLegacy.isPinned, isNull);

    final parsedBad = parseNoteContent('{invalid json');
    expect(parsedBad.images, isEmpty);
  });

  test('computeEdgeResize locks aspect ratio and anchors opposite edge strictly', () {
    const ar = 0.5; // 200x400 narrow image

    // 1. Right edge resize at x=100, width=200, availableWidth=500 -> maxW must be 400 (not 500!)
    final rightRes = computeEdgeResize(
      currentX: 100.0,
      currentWidth: 200.0,
      currentHeight: 400.0,
      aspectRatio: ar,
      delta: const Offset(300.0, 0.0), // tries to overshoot past availableWidth
      edge: 'right',
      availableWidth: 500.0,
    );
    expect(rightRes.x, equals(100.0)); // left edge must NOT shift!
    expect(rightRes.width, equals(400.0));
    expect(rightRes.height, closeTo(800.0, 0.01));

    // 2. Left edge resize at x=50, width=200 (rightEdge=250), dragging far left (-100)
    // x clamps to 0, so width stops at 250 so rightEdge stays anchored at 250!
    final leftRes = computeEdgeResize(
      currentX: 50.0,
      currentWidth: 200.0,
      currentHeight: 400.0,
      aspectRatio: ar,
      delta: const Offset(-100.0, 0.0),
      edge: 'left',
      availableWidth: 500.0,
    );
    expect(leftRes.x, equals(0.0));
    expect(leftRes.width, equals(250.0));
    expect(leftRes.x + leftRes.width, equals(250.0)); // right edge stayed anchored!
    expect(leftRes.height, closeTo(500.0, 0.01));

    // 3. Bottom edge resize scales width proportionally (dy * ar)
    final bottomRes = computeEdgeResize(
      currentX: 20.0,
      currentWidth: 200.0,
      currentHeight: 400.0,
      aspectRatio: ar,
      delta: const Offset(0.0, 40.0),
      edge: 'bottom',
      availableWidth: 500.0,
    );
    expect(bottomRes.x, equals(20.0));
    expect(bottomRes.width, closeTo(220.0, 0.01));
    expect(bottomRes.height, closeTo(440.0, 0.01));

    // 4. Tiny viewport (<80px) never throws ArgumentError
    final tinyRes = computeEdgeResize(
      currentX: 0.0,
      currentWidth: 50.0,
      currentHeight: 50.0,
      aspectRatio: 1.0,
      delta: const Offset(10.0, 0.0),
      edge: 'right',
      availableWidth: 60.0,
    );
    expect(tinyRes.width, equals(60.0));
  });

  test('extractNoteImageStoragePath extracts relative path cleanly', () {
    const url =
        'https://fvkbsnzvluhnxsbzeivy.supabase.co/storage/v1/object/public/note-images/V3X-EGF/1795201737549.png';
    expect(extractNoteImageStoragePath(url), equals('V3X-EGF/1795201737549.png'));
    expect(extractNoteImageStoragePath('data:image/png;base64,AAA'), isNull);
    expect(extractNoteImageStoragePath('https://example.com/other.png'), isNull);
  });

  test('AppImageCache enforces byte cap and LRU order', () {
    AppImageCache.clear();
    final chunk = Uint8List(1024 * 1024); // 1 MB
    for (int i = 0; i < 45; i++) {
      AppImageCache.put('https://example.com/$i.png', chunk);
    }
    expect(AppImageCache.totalBytes, lessThanOrEqualTo(40 * 1024 * 1024));
    expect(AppImageCache.has('https://example.com/0.png'), isFalse);
    expect(AppImageCache.has('https://example.com/44.png'), isTrue);
    AppImageCache.clear();
  });

  test('Note.formattedDate and VaultService offline cache work across boundaries', () async {
    SharedPreferences.setMockInitialValues({});
    final now = DateTime.now();
    final yesterday = DateTime(now.year, now.month, now.day)
        .subtract(const Duration(hours: 2));
    final note = Note(
      id: 'n1',
      vaultId: 'V12-345',
      title: 'Cached',
      content: jsonEncode({'delta': [{'insert': 'Hi\n'}], 'images': [], 'is_pinned': true}),
      plainText: 'Hi',
      updatedAt: yesterday,
      isPinned: true,
    );

    expect(note.formattedDate, equals('Вчера'));

    await VaultService.saveCachedNotes('V12-345', [note]);
    final loaded = await VaultService.getCachedNotes('V12-345');
    expect(loaded.length, equals(1));
    expect(loaded.first.id, equals('n1'));
    expect(loaded.first.isPinned, isTrue);
  });
}

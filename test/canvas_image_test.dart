import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_notes/notes_screen.dart';

void main() {
  test('CanvasImage serialization and deserialization', () {
    final img = CanvasImage(
      id: 'img_123',
      url: 'https://example.com/test.jpg',
      x: 140.5,
      y: 280.0,
      width: 320.0,
      height: 240.0,
    );

    final json = img.toJson();
    expect(json['id'], equals('img_123'));
    expect(json['url'], equals('https://example.com/test.jpg'));
    expect(json['x'], equals(140.5));
    expect(json['y'], equals(280.0));
    expect(json['width'], equals(320.0));
    expect(json['height'], equals(240.0));

    final parsed = CanvasImage.fromJson(json);
    expect(parsed.id, equals(img.id));
    expect(parsed.url, equals(img.url));
    expect(parsed.x, equals(img.x));
    expect(parsed.y, equals(img.y));
    expect(parsed.width, equals(img.width));
    expect(parsed.height, equals(img.height));
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
}

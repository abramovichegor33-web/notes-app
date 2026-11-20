import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';
import 'package:web/web.dart' as web;

typedef ImagePasteCallback = void Function(Uint8List bytes);

class WebPasteListener {
  static void register(ImagePasteCallback onImage) {
    web.window.addEventListener(
      'flutter_image_paste',
      (web.Event e) {
        try {
          final customEvent = e as web.CustomEvent;
          final detail = customEvent.detail;
          if (detail != null) {
            final dataUrl = (detail as JSString).toDart;
            final commaIndex = dataUrl.indexOf(',');
            if (commaIndex != -1) {
              final base64Str = dataUrl.substring(commaIndex + 1);
              final bytes = base64Decode(base64Str);
              onImage(bytes);
            }
          }
        } catch (_) {}
      }.toJS,
    );
  }
}

import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';
import 'package:web/web.dart' as web;

typedef ImagePasteCallback = void Function(Uint8List bytes);

class WebPasteListener {
  static ImagePasteCallback? _currentHandler;
  static bool _initialized = false;

  static void setHandler(ImagePasteCallback? handler) {
    _currentHandler = handler;
    _initOnce();
  }

  static void _initOnce() {
    if (_initialized) return;
    _initialized = true;

    web.window.addEventListener(
      'flutter_image_paste',
      (web.Event e) {
        try {
          final customEvent = e as web.CustomEvent;
          final detail = customEvent.detail;
          if (detail != null) {
            final String dataUrl = detail.isA<JSString>()
                ? (detail as JSString).toDart
                : detail.toString();
            final commaIndex = dataUrl.indexOf(',');
            if (commaIndex != -1) {
              final base64Str = dataUrl.substring(commaIndex + 1);
              final bytes = base64Decode(base64Str);
              _currentHandler?.call(bytes);
            }
          }
        } catch (_) {}
      }.toJS,
    );
  }
}

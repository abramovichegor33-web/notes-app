import 'dart:convert';
import 'dart:js_interop';
import 'package:flutter/foundation.dart';
import 'package:web/web.dart' as web;

typedef ImagePasteCallback = void Function(Uint8List bytes);

@JS('copyImageToClipboard')
external JSBoolean? _copyImageToClipboardJS(JSString data);

bool copyImageViaNativeBridge(String base64Data) {
  try {
    return _copyImageToClipboardJS(base64Data.toJS)?.toDart ?? false;
  } catch (_) {
    return false;
  }
}

class WebPasteListener {
  static ImagePasteCallback? _currentImageHandler;
  static VoidCallback? _newNoteHandler;
  static bool _initialized = false;

  static void setHandler(ImagePasteCallback? handler) {
    _currentImageHandler = handler;
    _initOnce();
  }

  static void setNewNoteHandler(VoidCallback? handler) {
    _newNoteHandler = handler;
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
              _currentImageHandler?.call(bytes);
            }
          }
        } catch (_) {}
      }.toJS,
    );

    web.window.addEventListener(
      'flutter_new_note',
      (web.Event e) {
        _newNoteHandler?.call();
      }.toJS,
    );
  }
}

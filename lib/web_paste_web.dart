import 'dart:convert';
import 'dart:js_interop';
import 'package:flutter/foundation.dart';
import 'package:web/web.dart' as web;

typedef ImagePasteCallback = void Function(Uint8List bytes);
typedef FilePasteCallback = void Function(
  String fileName,
  Uint8List bytes, {
  bool tooLarge,
});

@JS('copyImageToClipboard')
external JSBoolean? _copyImageToClipboardJS(JSString data);

@JS('__NOTES_MACOS_TITLEBAR__')
external JSBoolean? get _notesMacOSTitlebarJS;

@JS('syncNotesNativeTheme')
external void _syncNotesNativeThemeJS(JSBoolean isDark);

@JS('pickNotesFile')
external JSBoolean? _pickNotesFileJS(JSBoolean imagesOnly);

@JS('saveNotesFile')
external JSBoolean? _saveNotesFileJS(
  JSString fileName,
  JSString url,
  JSString base64Data,
  JSString mimeType,
);

bool copyImageViaNativeBridge(String base64Data) {
  try {
    return _copyImageToClipboardJS(base64Data.toJS)?.toDart ?? false;
  } catch (_) {
    return false;
  }
}

bool pickFileViaMacOSBridge({bool imagesOnly = false}) {
  if (!isEmbeddedMacOSWindow()) return false;
  try {
    return _pickNotesFileJS(imagesOnly.toJS)?.toDart ?? false;
  } catch (_) {
    return false;
  }
}

bool saveFileViaMacOSBridge(String fileName, String url, String base64Data) {
  if (!isEmbeddedMacOSWindow()) return false;
  try {
    return _saveNotesFileJS(
          fileName.toJS,
          url.toJS,
          base64Data.toJS,
          'application/octet-stream'.toJS,
        )?.toDart ??
        false;
  } catch (_) {
    return false;
  }
}

bool downloadFileViaBrowserBridge(
  String fileName,
  String url,
  String base64Data,
  String mimeType,
) {
  try {
    return _saveNotesFileJS(
          fileName.toJS,
          url.toJS,
          base64Data.toJS,
          mimeType.toJS,
        )?.toDart ??
        false;
  } catch (_) {
    return false;
  }
}

bool isEmbeddedMacOSWindow() {
  try {
    return _notesMacOSTitlebarJS?.toDart ?? false;
  } catch (_) {
    return false;
  }
}

void syncNativeWindowTheme(bool isDark) {
  try {
    _syncNotesNativeThemeJS(isDark.toJS);
  } catch (_) {}
}

class WebPasteListener {
  static ImagePasteCallback? _currentImageHandler;
  static FilePasteCallback? _currentFileHandler;
  static VoidCallback? _newNoteHandler;
  static VoidCallback? _undoHandler;
  static VoidCallback? _redoHandler;
  static bool _initialized = false;
  static DateTime _lastPasteTime = DateTime.fromMillisecondsSinceEpoch(0);

  static void setHandler(ImagePasteCallback? handler) {
    _currentImageHandler = handler;
    _initOnce();
  }

  static void setFileHandler(FilePasteCallback? handler) {
    _currentFileHandler = handler;
    _initOnce();
  }

  static void setNewNoteHandler(VoidCallback? handler) {
    _newNoteHandler = handler;
    _initOnce();
  }

  static void setUndoHandler(VoidCallback? handler) {
    _undoHandler = handler;
    _initOnce();
  }

  static void setRedoHandler(VoidCallback? handler) {
    _redoHandler = handler;
    _initOnce();
  }

  static void _initOnce() {
    if (_initialized) return;
    _initialized = true;

    web.window.addEventListener(
      'flutter_image_paste',
      (web.Event e) {
        try {
          final now = DateTime.now();
          if (now.difference(_lastPasteTime).inMilliseconds < 600) {
            return;
          }
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
              _lastPasteTime = DateTime.now();
              _currentImageHandler?.call(bytes);
            }
          }
        } catch (_) {}
      }.toJS,
    );

    web.window.addEventListener(
      'flutter_file_paste',
      (web.Event e) {
        try {
          final customEvent = e as web.CustomEvent;
          final detail = customEvent.detail;
          if (detail != null) {
            final String raw = detail.isA<JSString>()
                ? (detail as JSString).toDart
                : detail.toString();
            final decoded = jsonDecode(raw);
            if (decoded is Map) {
              final name = (decoded['name'] ?? 'file').toString();
              if (decoded['error'] == 'too_large') {
                _currentFileHandler?.call(name, Uint8List(0), tooLarge: true);
                return;
              }
              final b64 = (decoded['base64'] ?? '').toString();
              if (b64.isNotEmpty) {
                final bytes = base64Decode(b64);
                _currentFileHandler?.call(name, bytes);
              }
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

    web.window.addEventListener(
      'flutter_undo',
      (web.Event e) {
        _undoHandler?.call();
      }.toJS,
    );

    web.window.addEventListener(
      'flutter_redo',
      (web.Event e) {
        _redoHandler?.call();
      }.toJS,
    );
  }
}

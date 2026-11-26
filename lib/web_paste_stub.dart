import 'package:flutter/foundation.dart';

typedef ImagePasteCallback = void Function(Uint8List bytes);
typedef FilePasteCallback = void Function(
  String fileName,
  Uint8List bytes, {
  bool tooLarge,
});

class WebPasteListener {
  static void setHandler(ImagePasteCallback? handler) {}
  static void setFileHandler(FilePasteCallback? handler) {}
  static void setNewNoteHandler(VoidCallback? handler) {}
  static void setUndoHandler(VoidCallback? handler) {}
  static void setRedoHandler(VoidCallback? handler) {}
}

bool copyImageViaNativeBridge(String base64Data) => false;

bool pickFileViaMacOSBridge({bool imagesOnly = false}) => false;

bool saveFileViaMacOSBridge(String fileName, String url, String base64Data) =>
    false;

bool downloadFileViaBrowserBridge(
  String fileName,
  String url,
  String base64Data,
  String mimeType,
) =>
    false;

bool isEmbeddedMacOSWindow() => false;

void syncNativeWindowTheme(bool isDark) {}

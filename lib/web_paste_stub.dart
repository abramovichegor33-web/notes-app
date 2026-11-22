import 'package:flutter/foundation.dart';

typedef ImagePasteCallback = void Function(Uint8List bytes);

class WebPasteListener {
  static void setHandler(ImagePasteCallback? handler) {}
  static void setNewNoteHandler(VoidCallback? handler) {}
}

bool copyImageViaNativeBridge(String base64Data) => false;

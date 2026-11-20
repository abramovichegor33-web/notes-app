import 'dart:typed_data';

typedef ImagePasteCallback = void Function(Uint8List bytes);

class WebPasteListener {
  static void setHandler(ImagePasteCallback? handler) {}
}

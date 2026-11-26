import 'dart:convert';

class Note {
  final String id;
  final String vaultId;
  final String title;
  final String content;
  final String plainText;
  final DateTime updatedAt;
  final bool isPinned;

  Note({
    required this.id,
    required this.vaultId,
    required this.title,
    required this.content,
    required this.plainText,
    required this.updatedAt,
    this.isPinned = false,
  });

  Note copyWith({
    String? id,
    String? vaultId,
    String? title,
    String? content,
    String? plainText,
    DateTime? updatedAt,
    bool? isPinned,
  }) {
    return Note(
      id: id ?? this.id,
      vaultId: vaultId ?? this.vaultId,
      title: title ?? this.title,
      content: content ?? this.content,
      plainText: plainText ?? this.plainText,
      updatedAt: updatedAt ?? this.updatedAt,
      isPinned: isPinned ?? this.isPinned,
    );
  }

  factory Note.fromMap(Map<dynamic, dynamic> map) {
    final rawContent = (map['content'] ?? '').toString();
    bool pinned = map['is_pinned'] == true || map['is_pinned'] == 1;

    if (!pinned && rawContent.isNotEmpty) {
      try {
        final decoded = jsonDecode(rawContent);
        if (decoded is Map && decoded['is_pinned'] == true) {
          pinned = true;
        }
      } catch (_) {}
    }

    return Note(
      id: (map['id'] ?? '').toString(),
      vaultId: (map['vault_id'] ?? '').toString(),
      title: (map['title'] ?? '').toString(),
      content: rawContent,
      plainText: (map['plain_text'] ?? '').toString(),
      updatedAt: DateTime.tryParse((map['updated_at'] ?? '').toString()) ??
          DateTime.now(),
      isPinned: pinned,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'vault_id': vaultId,
      'title': title,
      'content': content,
      'plain_text': plainText,
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  Map<String, dynamic> toCacheMap() {
    return {
      ...toMap(),
      'is_pinned': isPinned,
    };
  }

  late final ({int images, int files}) _attachmentCounts =
      _computeAttachmentCounts(content);

  int get imageCount => _attachmentCounts.images;
  int get fileCount => _attachmentCounts.files;

  static ({int images, int files}) _computeAttachmentCounts(String rawContent) {
    if (rawContent.isEmpty ||
        (!rawContent.contains('"images"') && !rawContent.contains('"files"'))) {
      return (images: 0, files: 0);
    }
    try {
      final decoded = jsonDecode(rawContent);
      if (decoded is Map) {
        final imgs = decoded['images'] is List
            ? (decoded['images'] as List).length
            : 0;
        final files =
            decoded['files'] is List ? (decoded['files'] as List).length : 0;
        return (images: imgs, files: files);
      }
    } catch (_) {}
    return (images: 0, files: 0);
  }

  String get formattedDate {
    final now = DateTime.now();
    final local = updatedAt.toLocal();
    final today = DateTime(now.year, now.month, now.day);
    final noteDay = DateTime(local.year, local.month, local.day);
    final dayDiff = today.difference(noteDay).inDays;

    if (dayDiff == 0) {
      final hour = local.hour.toString().padLeft(2, '0');
      final minute = local.minute.toString().padLeft(2, '0');
      return '$hour:$minute';
    } else if (dayDiff == 1) {
      return 'Вчера';
    } else if (now.year == local.year) {
      const months = [
        'янв.', 'февр.', 'марта', 'апр.', 'мая', 'июня',
        'июля', 'авг.', 'сент.', 'окт.', 'нояб.', 'дек.'
      ];
      return '${local.day} ${months[local.month - 1]}';
    } else {
      final day = local.day.toString().padLeft(2, '0');
      final month = local.month.toString().padLeft(2, '0');
      return '$day.$month.${local.year}';
    }
  }
}

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

  String get formattedDate {
    final now = DateTime.now();
    final difference = now.difference(updatedAt);
    if (difference.inDays == 0 && now.day == updatedAt.day) {
      final hour = updatedAt.hour.toString().padLeft(2, '0');
      final minute = updatedAt.minute.toString().padLeft(2, '0');
      return '$hour:$minute';
    } else if (difference.inDays <= 1 && now.day - updatedAt.day == 1) {
      return 'Вчера';
    } else if (now.year == updatedAt.year) {
      const months = [
        'янв.', 'февр.', 'марта', 'апр.', 'мая', 'июня',
        'июля', 'авг.', 'сент.', 'окт.', 'нояб.', 'дек.'
      ];
      return '${updatedAt.day} ${months[updatedAt.month - 1]}';
    } else {
      final day = updatedAt.day.toString().padLeft(2, '0');
      final month = updatedAt.month.toString().padLeft(2, '0');
      return '$day.$month.${updatedAt.year}';
    }
  }
}

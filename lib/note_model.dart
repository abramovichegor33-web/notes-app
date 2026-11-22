class Note {
  final String id;
  final String vaultId;
  final String title;
  final String content;
  final String plainText;
  final DateTime updatedAt;

  Note({
    required this.id,
    required this.vaultId,
    required this.title,
    required this.content,
    required this.plainText,
    required this.updatedAt,
  });

  Note copyWith({
    String? id,
    String? vaultId,
    String? title,
    String? content,
    String? plainText,
    DateTime? updatedAt,
  }) {
    return Note(
      id: id ?? this.id,
      vaultId: vaultId ?? this.vaultId,
      title: title ?? this.title,
      content: content ?? this.content,
      plainText: plainText ?? this.plainText,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  factory Note.fromMap(Map<dynamic, dynamic> map) {
    return Note(
      id: (map['id'] ?? '').toString(),
      vaultId: (map['vault_id'] ?? '').toString(),
      title: (map['title'] ?? '').toString(),
      content: (map['content'] ?? '').toString(),
      plainText: (map['plain_text'] ?? '').toString(),
      updatedAt: DateTime.tryParse((map['updated_at'] ?? '').toString()) ??
          DateTime.now(),
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

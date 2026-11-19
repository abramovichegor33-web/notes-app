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

  factory Note.fromMap(Map<String, dynamic> map) {
    return Note(
      id: map['id'] as String,
      vaultId: map['vault_id'] as String? ?? '',
      title: map['title'] as String? ?? '',
      content: map['content'] as String? ?? '',
      plainText: map['plain_text'] as String? ?? '',
      updatedAt: DateTime.tryParse(map['updated_at'] as String? ?? '') ??
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
      'updated_at': DateTime.now().toIso8601String(),
    };
  }
}

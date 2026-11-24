import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:my_notes/main.dart';
import 'package:my_notes/note_model.dart';

String _generateUuid() {
  final random = Random();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
  bytes[8] = (bytes[8] & 0x3f) | 0x80; // variant
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

void main() {
  test('E2E Phone to Mac Image and Text Sync Test', () async {
    final client = SupabaseClient(supabaseUrl, supabaseAnonKey);
    final vaultId = 'TEST-E2E-CI';
    final noteId = _generateUuid();

    // 1. Phone creates a new note
    final phoneNote = Note(
      id: noteId,
      vaultId: vaultId,
      title: 'E2E Тест синхронизации телефона и мака',
      content: jsonEncode([{'insert': '\n'}]),
      plainText: '',
      updatedAt: DateTime.now(),
    );
    await client.from('notes').insert(phoneNote.toMap());

    // 2. Phone uploads an image to storage
    final dummyImageBytes = Uint8List.fromList([
      0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01,
      0x01, 0x01, 0x00, 0x48, 0x00, 0x48, 0x00, 0x00, 0xFF, 0xDB, 0x00, 0x43,
      0x00, 0x08, 0x06, 0x06, 0x07, 0x06, 0x05, 0x08, 0x07, 0x07, 0x07, 0x09,
      0xFF, 0xD9
    ]);
    final fileName = 'test_e2e_${DateTime.now().millisecondsSinceEpoch}.jpg';
    final storagePath = '$vaultId/$fileName';

    await client.storage.from('note-images').uploadBinary(
      storagePath,
      dummyImageBytes,
      fileOptions: const FileOptions(contentType: 'image/jpeg'),
    );
    final cloudUrl = client.storage.from('note-images').getPublicUrl(storagePath);
    expect(cloudUrl.isNotEmpty, true);

    // 3. Phone replaces local data url with cloud url and saves note
    final noteContent = jsonEncode([
      {'insert': 'Текст заметки с телефона:\n'},
      {'insert': {'image': cloudUrl}},
      {'insert': '\nТекст под картинкой с телефона!'}
    ]);
    await client.from('notes').upsert({
      'id': noteId,
      'vault_id': vaultId,
      'title': 'E2E Тест синхронизации телефона и мака',
      'content': noteContent,
      'plain_text': 'Текст заметки с телефона: Текст под картинкой с телефона!',
      'updated_at': DateTime.now().toIso8601String(),
    });

    // 4. Simulate Mac reading notes from cloud
    final macFetchResponse = await client
        .from('notes')
        .select()
        .eq('vault_id', vaultId)
        .eq('id', noteId);

    expect(macFetchResponse.isNotEmpty, true);
    final macFetchedNote = Note.fromMap(macFetchResponse.first);
    expect(macFetchedNote.id, noteId);
    expect(macFetchedNote.content.contains(cloudUrl), true);
    expect(macFetchedNote.plainText.contains('Текст под картинкой'), true);

    // 5. Mac edits the note
    final macEditedContent = jsonEncode([
      {'insert': 'Текст заметки с телефона:\n'},
      {'insert': {'image': cloudUrl}},
      {'insert': '\nТекст под картинкой с телефона!\n[Добавлено с Mac: 100% подтверждено!]'}
    ]);
    await client.from('notes').upsert({
      'id': noteId,
      'vault_id': vaultId,
      'title': 'E2E Тест синхронизации телефона и мака (отредактировано на Mac)',
      'content': macEditedContent,
      'plain_text': 'Текст заметки с телефона: Текст под картинкой с телефона! [Добавлено с Mac: 100% подтверждено!]',
      'updated_at': DateTime.now().toIso8601String(),
    });

    // 6. Phone reads the updated note
    final phoneFetchResponse = await client
        .from('notes')
        .select()
        .eq('vault_id', vaultId)
        .eq('id', noteId);
    final phoneUpdatedNote = Note.fromMap(phoneFetchResponse.first);
    expect(phoneUpdatedNote.title, 'E2E Тест синхронизации телефона и мака (отредактировано на Mac)');
    expect(phoneUpdatedNote.content.contains('Добавлено с Mac'), true);

    // 7. Clean up
    await client.storage.from('note-images').remove([storagePath]);
    await client.from('notes').delete().eq('id', noteId);
  });
}

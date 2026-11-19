import 'dart:async';
import 'dart:convert';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'note_model.dart';
import 'sync_dialog.dart';

class NotesScreen extends StatefulWidget {
  final String vaultId;
  final ValueChanged<String> onVaultChanged;

  const NotesScreen({
    super.key,
    required this.vaultId,
    required this.onVaultChanged,
  });

  @override
  State<NotesScreen> createState() => _NotesScreenState();
}

class _NotesScreenState extends State<NotesScreen> {
  final _searchController = TextEditingController();
  String _searchQuery = '';
  Note? _selectedNote;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _createNewNote() async {
    final newNoteData = {
      'vault_id': widget.vaultId,
      'title': 'Новая заметка',
      'content': '',
      'plain_text': '',
    };

    final response = await Supabase.instance.client
        .from('notes')
        .insert(newNoteData)
        .select()
        .single();

    final createdNote = Note.fromMap(response);
    setState(() {
      _selectedNote = createdNote;
    });

    if (mounted && MediaQuery.of(context).size.width < 700) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => NoteEditorPage(
            note: createdNote,
            vaultId: widget.vaultId,
            onNoteUpdated: (updated) => setState(() => _selectedNote = updated),
          ),
        ),
      );
    }
  }

  Future<void> _deleteNote(String noteId) async {
    await Supabase.instance.client.from('notes').delete().eq('id', noteId);
    if (_selectedNote?.id == noteId) {
      setState(() {
        _selectedNote = null;
      });
    }
  }

  void _openSyncDialog() {
    showDialog(
      context: context,
      builder: (_) => SyncDialog(
        currentVaultId: widget.vaultId,
        onVaultChanged: (newVault) {
          setState(() {
            _selectedNote = null;
          });
          widget.onVaultChanged(newVault);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDesktop = MediaQuery.of(context).size.width >= 700;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Заметки'),
        actions: [
          IconButton(
            icon: const Icon(Icons.devices_outlined),
            tooltip: 'Связать устройства (QR / Код)',
            onPressed: _openSyncDialog,
          ),
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'Создать заметку',
            onPressed: _createNewNote,
          ),
        ],
      ),
      body: Row(
        children: [
          SizedBox(
            width: isDesktop ? 320 : MediaQuery.of(context).size.width,
            child: _buildNotesList(isDesktop),
          ),
          if (isDesktop) ...[
            const VerticalDivider(width: 1),
            Expanded(
              child: _selectedNote == null
                  ? const Center(
                      child: Text(
                        'Выберите заметку или создайте новую',
                        style: TextStyle(color: Colors.grey, fontSize: 16),
                      ),
                    )
                  : NoteEditorView(
                      key: ValueKey(_selectedNote!.id),
                      note: _selectedNote!,
                      vaultId: widget.vaultId,
                      onNoteUpdated: (updated) {
                        setState(() => _selectedNote = updated);
                      },
                    ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildNotesList(bool isDesktop) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: TextField(
            controller: _searchController,
            decoration: InputDecoration(
              hintText: 'Поиск заметок...',
              prefixIcon: const Icon(Icons.search, size: 20),
              suffixIcon: _searchQuery.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear, size: 18),
                      onPressed: () {
                        _searchController.clear();
                        setState(() => _searchQuery = '');
                      },
                    )
                  : null,
              filled: true,
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(vertical: 10),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide.none,
              ),
            ),
            onChanged: (val) =>
                setState(() => _searchQuery = val.trim().toLowerCase()),
          ),
        ),
        Expanded(
          child: StreamBuilder<List<Map<String, dynamic>>>(
            stream: Supabase.instance.client
                .from('notes')
                .stream(primaryKey: ['id'])
                .eq('vault_id', widget.vaultId)
                .order('updated_at', ascending: false),
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }

              final data = snapshot.data ?? [];
              final allNotes = data.map((e) => Note.fromMap(e)).toList();

              final filteredNotes = allNotes.where((n) {
                if (_searchQuery.isEmpty) return true;
                return n.title.toLowerCase().contains(_searchQuery) ||
                    n.plainText.toLowerCase().contains(_searchQuery);
              }).toList();

              if (filteredNotes.isEmpty) {
                return Center(
                  child: Text(
                    _searchQuery.isEmpty
                        ? 'Заметок пока нет'
                        : 'Ничего не найдено',
                    style: const TextStyle(color: Colors.grey),
                  ),
                );
              }

              return ListView.separated(
                itemCount: filteredNotes.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final note = filteredNotes[index];
                  final isSelected = isDesktop && _selectedNote?.id == note.id;

                  return ListTile(
                    selected: isSelected,
                    selectedTileColor: Theme.of(context)
                        .colorScheme
                        .primaryContainer
                        .withAlpha(80),
                    title: Text(
                      note.title.isEmpty ? 'Без названия' : note.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    subtitle: Text(
                      note.plainText.isEmpty ? 'Пустая заметка' : note.plainText,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12),
                    ),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline, size: 20),
                      onPressed: () => _deleteNote(note.id),
                    ),
                    onTap: () {
                      setState(() => _selectedNote = note);
                      if (!isDesktop) {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => NoteEditorPage(
                              note: note,
                              vaultId: widget.vaultId,
                              onNoteUpdated: (updated) {
                                setState(() => _selectedNote = updated);
                              },
                            ),
                          ),
                        );
                      }
                    },
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

class NoteEditorPage extends StatelessWidget {
  final Note note;
  final String vaultId;
  final ValueChanged<Note> onNoteUpdated;

  const NoteEditorPage({
    super.key,
    required this.note,
    required this.vaultId,
    required this.onNoteUpdated,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(note.title.isEmpty ? 'Заметка' : note.title),
      ),
      body: NoteEditorView(
        note: note,
        vaultId: vaultId,
        onNoteUpdated: onNoteUpdated,
      ),
    );
  }
}

class NoteEditorView extends StatefulWidget {
  final Note note;
  final String vaultId;
  final ValueChanged<Note> onNoteUpdated;

  const NoteEditorView({
    super.key,
    required this.note,
    required this.vaultId,
    required this.onNoteUpdated,
  });

  @override
  State<NoteEditorView> createState() => _NoteEditorViewState();
}

class _NoteEditorViewState extends State<NoteEditorView> {
  late TextEditingController _titleController;
  late QuillController _quillController;
  Timer? _debounceTimer;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.note.title);

    if (widget.note.content.isNotEmpty) {
      try {
        final decoded = jsonDecode(widget.note.content);
        _quillController = QuillController(
          document: Document.fromJson(decoded),
          selection: const TextSelection.collapsed(offset: 0),
        );
      } catch (_) {
        _quillController = QuillController.basic();
      }
    } else {
      _quillController = QuillController.basic();
    }

    _titleController.addListener(_scheduleSave);
    _quillController.addListener(_scheduleSave);
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _titleController.dispose();
    _quillController.dispose();
    super.dispose();
  }

  void _scheduleSave() {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 500), _saveNote);
  }

  Future<void> _saveNote() async {
    final title = _titleController.text.trim();
    final content = jsonEncode(_quillController.document.toDelta().toJson());
    final plainText = _quillController.document.toPlainText().trim();

    final updated = Note(
      id: widget.note.id,
      vaultId: widget.vaultId,
      title: title,
      content: content,
      plainText: plainText,
      updatedAt: DateTime.now(),
    );

    widget.onNoteUpdated(updated);

    await Supabase.instance.client.from('notes').upsert({
      'id': widget.note.id,
      'vault_id': widget.vaultId,
      'title': title,
      'content': content,
      'plain_text': plainText,
      'updated_at': DateTime.now().toIso8601String(),
    });
  }

  Future<void> _uploadAndInsertImage(Uint8List bytes) async {
    try {
      final fileName = '${DateTime.now().millisecondsSinceEpoch}.png';
      final storagePath = '${widget.vaultId}/$fileName';

      await Supabase.instance.client.storage.from('note-images').uploadBinary(
            storagePath,
            bytes,
            fileOptions: const FileOptions(contentType: 'image/png'),
          );

      final publicUrl = Supabase.instance.client.storage
          .from('note-images')
          .getPublicUrl(storagePath);

      final index = _quillController.selection.baseOffset;
      final length = _quillController.selection.extentOffset - index;
      _quillController.replaceText(
        index < 0 ? _quillController.document.length - 1 : index,
        length < 0 ? 0 : length,
        BlockEmbed.image(publicUrl),
        null,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Не удалось загрузить изображение')),
        );
      }
    }
  }

  Future<void> _pickImage() async {
    final file = await FilePicker.pickFile(type: FileType.image);
    if (file != null) {
      final bytes = await file.readAsBytes();
      if (bytes.isNotEmpty) {
        await _uploadAndInsertImage(bytes);
      }
    }
  }

  Future<void> _handlePasteImage() async {
    try {
      final imageBytes = await Pasteboard.image;
      if (imageBytes != null && imageBytes.isNotEmpty) {
        await _uploadAndInsertImage(imageBytes);
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyV, meta: true):
            _handlePasteImage,
        const SingleActivator(LogicalKeyboardKey.keyV, control: true):
            _handlePasteImage,
      },
      child: Focus(
        autofocus: true,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _titleController,
                      style: const TextStyle(
                          fontSize: 22, fontWeight: FontWeight.bold),
                      decoration: const InputDecoration(
                        hintText: 'Заголовок заметки',
                        border: InputBorder.none,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.image_outlined),
                    tooltip: 'Вставить изображение',
                    onPressed: _pickImage,
                  ),
                ],
              ),
            ),
            QuillSimpleToolbar(
              controller: _quillController,
              config: const QuillSimpleToolbarConfig(),
            ),
            const Divider(height: 1),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: QuillEditor.basic(
                  controller: _quillController,
                  config: const QuillEditorConfig(
                    placeholder:
                        'Начните писать или вставьте изображение (Cmd+V)...',
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

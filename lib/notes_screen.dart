import 'dart:async';
import 'dart:convert';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'note_model.dart';
import 'sync_dialog.dart';
import 'web_paste.dart';

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
  late Stream<List<Map<String, dynamic>>> _notesStream;

  @override
  void initState() {
    super.initState();
    _initStream();
  }

  void _initStream() {
    _notesStream = Supabase.instance.client
        .from('notes')
        .stream(primaryKey: ['id'])
        .eq('vault_id', widget.vaultId)
        .order('updated_at', ascending: false);
  }

  @override
  void didUpdateWidget(covariant NotesScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.vaultId != widget.vaultId) {
      _initStream();
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _createNewNote() async {
    try {
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
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Ошибка создания заметки: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _deleteNote(String noteId) async {
    try {
      await Supabase.instance.client.from('notes').delete().eq('id', noteId);
      if (_selectedNote?.id == noteId) {
        setState(() {
          _selectedNote = null;
        });
      }
    } catch (_) {}
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
            stream: _notesStream,
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

  const NoteEditorPage({
    super.key,
    required this.note,
    required this.vaultId,
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
      ),
    );
  }
}


class AppImageEmbedBuilder extends EmbedBuilder {
  const AppImageEmbedBuilder();

  @override
  String get key => BlockEmbed.imageType;

  @override
  bool get expanded => false;

  @override
  Widget build(BuildContext context, EmbedContext embedContext) {
    final imageSource = embedContext.node.value.data.toString();

    Widget imageWidget;
    if (imageSource.startsWith('data:image/') || imageSource.contains('base64')) {
      final base64String =
          imageSource.contains(',') ? imageSource.split(',')[1] : imageSource;
      imageWidget = Image.memory(
        base64Decode(base64String),
        fit: BoxFit.contain,
      );
    } else {
      imageWidget = Image.network(
        imageSource,
        fit: BoxFit.contain,
        loadingBuilder: (context, child, loadingProgress) {
          if (loadingProgress == null) return child;
          return Container(
            height: 150,
            width: 200,
            color: Colors.black12,
            child: const Center(
              child: SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        },
        errorBuilder: (context, error, stackTrace) => Container(
          height: 100,
          width: 250,
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Colors.red.withAlpha(20),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.red.withAlpha(60)),
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.broken_image, color: Colors.red),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Не удалось загрузить изображение',
                  style: TextStyle(fontSize: 12),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      );
    }

    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: GestureDetector(
        onTap: () {
          showDialog(
            context: context,
            builder: (_) => Dialog(
              backgroundColor: Colors.transparent,
              insetPadding: const EdgeInsets.all(24),
              child: Stack(
                alignment: Alignment.topRight,
                children: [
                  Center(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: InteractiveViewer(
                        child: imageWidget,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white, size: 28),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
          );
        },
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: 550,
              maxHeight: 450,
            ),
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: isDark ? Colors.white38 : Colors.black26,
                  width: 1.5,
                ),
                color: isDark
                    ? Colors.white.withAlpha(12)
                    : Colors.black.withAlpha(8),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6.5),
                child: imageWidget,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class NoteEditorView extends StatefulWidget {
  final Note note;
  final String vaultId;

  const NoteEditorView({
    super.key,
    required this.note,
    required this.vaultId,
  });

  @override
  State<NoteEditorView> createState() => _NoteEditorViewState();
}

class _NoteEditorViewState extends State<NoteEditorView> {
  late TextEditingController _titleController;
  late QuillController _quillController;
  StreamSubscription? _docChangeSub;
  Timer? _debounceTimer;
  String _lastSavedTitle = '';
  String _lastSavedContent = '';
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.note.title);
    _lastSavedTitle = widget.note.title;
    _lastSavedContent = widget.note.content;

    final controllerConfig = QuillControllerConfig(
      clipboardConfig: QuillClipboardConfig(
        onImagePaste: _uploadImageToStorage,
      ),
    );

    if (widget.note.content.isNotEmpty) {
      try {
        final decoded = jsonDecode(widget.note.content);
        _quillController = QuillController(
          document: Document.fromJson(decoded),
          selection: const TextSelection.collapsed(offset: 0),
          config: controllerConfig,
        );
      } catch (_) {
        _quillController = QuillController.basic(config: controllerConfig);
      }
    } else {
      _quillController = QuillController.basic(config: controllerConfig);
    }

    _titleController.addListener(_onTitleChanged);
    _docChangeSub = _quillController.changes.listen((_) => _scheduleSave());

    // Слушатель веб-события вставки изображения (Cmd+V в браузере/WebView)
    WebPasteListener.setHandler((bytes) {
      if (mounted) {
        _insertImageBytes(bytes);
      }
    });
  }

  void _onTitleChanged() {
    if (_titleController.text.trim() != _lastSavedTitle) {
      _scheduleSave();
    }
  }

  @override
  void dispose() {
    WebPasteListener.setHandler(null);
    _debounceTimer?.cancel();
    _docChangeSub?.cancel();
    _saveNote(updateUi: false);
    _titleController.dispose();
    _quillController.dispose();
    super.dispose();
  }

  void _scheduleSave() {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 1200), _saveNote);
  }

  Future<void> _saveNote({bool updateUi = true}) async {
    final title = _titleController.text.trim();
    final content = jsonEncode(_quillController.document.toDelta().toJson());

    if (title == _lastSavedTitle && content == _lastSavedContent) {
      return;
    }

    _lastSavedTitle = title;
    _lastSavedContent = content;

    if (updateUi && mounted) {
      setState(() => _isSaving = true);
    }

    try {
      final plainText = _quillController.document.toPlainText().trim();

      await Supabase.instance.client.from('notes').upsert({
        'id': widget.note.id,
        'vault_id': widget.vaultId,
        'title': title,
        'content': content,
        'plain_text': plainText,
        'updated_at': DateTime.now().toIso8601String(),
      });
    } catch (_) {
    } finally {
      if (updateUi && mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  Future<String?> _uploadImageToStorage(Uint8List bytes) async {
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

      return publicUrl;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Не удалось загрузить изображение')),
        );
      }
      return null;
    }
  }

  Future<void> _insertImageBytes(Uint8List bytes) async {
    if (mounted) {
      setState(() => _isSaving = true);
    }
    final url = await _uploadImageToStorage(bytes);
    if (mounted) {
      setState(() => _isSaving = false);
    }

    if (url != null) {
      final index = _quillController.selection.baseOffset;
      final length = _quillController.selection.extentOffset - index;
      final safeIndex =
          index < 0 ? _quillController.document.length - 1 : index;
      final safeLength = length < 0 ? 0 : length;

      _quillController.replaceText(
        safeIndex,
        safeLength,
        BlockEmbed.image(url),
        null,
      );
      _quillController.updateSelection(
        TextSelection.collapsed(offset: safeIndex + 1),
        ChangeSource.local,
      );
      _scheduleSave();
    }
  }

  Future<void> _pickImage() async {
    try {
      final files = await FilePicker.pickFiles(type: FileType.image);
      if (files.isNotEmpty) {
        final bytes = await files.first.readAsBytes();
        if (bytes.isNotEmpty) {
          await _insertImageBytes(bytes);
        }
      }
    } catch (e) {
      debugPrint('Error picking image: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
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
              if (_isSaving)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8.0),
                  child: SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              IconButton(
                icon: const Icon(Icons.image_outlined),
                tooltip: 'Вставить изображение из файла',
                onPressed: _pickImage,
              ),
            ],
          ),
        ),
        QuillSimpleToolbar(
          controller: _quillController,
          config: const QuillSimpleToolbarConfig(
            showFontFamily: false,
            showFontSize: false,
            showColorButton: false,
            showBackgroundColorButton: false,
            showSubscript: false,
            showSuperscript: false,
            showSearchButton: false,
            showInlineCode: false,
            showCodeBlock: false,
            showAlignmentButtons: false,
            showDirection: false,
            showLink: false,
            showListCheck: true,
            showListBullets: true,
            showListNumbers: true,
            showQuote: true,
            showIndent: false,
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: QuillEditor.basic(
              controller: _quillController,
              config: const QuillEditorConfig(
                placeholder:
                    'Начните писать или вставьте текст / скриншот (Cmd+V)...',
                embedBuilders: [
                  AppImageEmbedBuilder(),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

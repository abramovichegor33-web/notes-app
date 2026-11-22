import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:http/http.dart' as http;
import 'package:pasteboard/pasteboard.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'note_model.dart';
import 'sync_dialog.dart';
import 'web_paste.dart';

String _generateUuid() {
  final random = Random();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
  bytes[8] = (bytes[8] & 0x3f) | 0x80; // variant
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

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

class _NotesScreenState extends State<NotesScreen> with WidgetsBindingObserver {
  final _searchController = TextEditingController();
  final _searchFocusNode = FocusNode();

  final ValueNotifier<List<Note>> _notesNotifier =
      ValueNotifier<List<Note>>([]);
  List<Note> _notes = [];
  bool _isLoading = true;
  String _searchQuery = '';
  Note? _selectedNote;
  RealtimeChannel? _realtimeChannel;
  Timer? _periodicSyncTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WebPasteListener.setNewNoteHandler(_createNewNote);
    _fetchNotes();
    _setupRealtime();
    _startPeriodicSync();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _syncFromCloudSilently();
      _setupRealtime();
    }
  }

  void _startPeriodicSync() {
    _periodicSyncTimer?.cancel();
    _periodicSyncTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      _syncFromCloudSilently();
    });
  }

  void _broadcastSync() {
    try {
      _realtimeChannel?.sendBroadcastMessage(
        event: 'sync',
        payload: {
          'vault': widget.vaultId,
          'ts': DateTime.now().millisecondsSinceEpoch,
        },
      );
    } catch (_) {}
  }

  Future<void> _syncFromCloudSilently() async {
    try {
      final response = await Supabase.instance.client
          .from('notes')
          .select()
          .eq('vault_id', widget.vaultId)
          .order('updated_at', ascending: false);

      final cloudNotes =
          (response as List).map((e) => Note.fromMap(e as Map)).toList();

      if (!mounted) return;

      bool hasChanges = false;
      if (cloudNotes.length != _notes.length) {
        hasChanges = true;
      } else {
        for (int i = 0; i < cloudNotes.length; i++) {
          if (cloudNotes[i].id != _notes[i].id ||
              cloudNotes[i].title != _notes[i].title ||
              cloudNotes[i].content != _notes[i].content ||
              cloudNotes[i].updatedAt != _notes[i].updatedAt) {
            hasChanges = true;
            break;
          }
        }
      }

      if (hasChanges) {
        _notes = cloudNotes;
        _notesNotifier.value = List.of(_notes);

        if (_selectedNote != null) {
          final match = _notes.where((n) => n.id == _selectedNote!.id);
          if (match.isNotEmpty) {
            setState(() {
              _selectedNote = match.first;
            });
          } else {
            setState(() {
              _selectedNote = _notes.isNotEmpty ? _notes.first : null;
            });
          }
        } else if (_notes.isNotEmpty) {
          setState(() {
            _selectedNote = _notes.first;
          });
        }
      }
    } catch (e) {
      debugPrint('Sync silently error: $e');
    }
  }

  @override
  void didUpdateWidget(covariant NotesScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.vaultId != widget.vaultId) {
      _selectedNote = null;
      _notes = [];
      _notesNotifier.value = [];
      _fetchNotes();
      _setupRealtime();
      _startPeriodicSync();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _periodicSyncTimer?.cancel();
    WebPasteListener.setNewNoteHandler(null);
    _searchController.dispose();
    _searchFocusNode.dispose();
    _notesNotifier.dispose();
    _realtimeChannel?.unsubscribe();
    super.dispose();
  }

  Future<void> _fetchNotes() async {
    setState(() => _isLoading = true);
    try {
      final response = await Supabase.instance.client
          .from('notes')
          .select()
          .eq('vault_id', widget.vaultId)
          .order('updated_at', ascending: false);

      final fetched =
          (response as List).map((e) => Note.fromMap(e as Map)).toList();

      if (mounted) {
        _notes = fetched;
        _notesNotifier.value = List.of(_notes);
        setState(() {
          _isLoading = false;
          if (_selectedNote != null) {
            final match = _notes.where((n) => n.id == _selectedNote!.id);
            _selectedNote = match.isNotEmpty ? match.first : null;
          }
          if (_selectedNote == null && _notes.isNotEmpty) {
            _selectedNote = _notes.first;
          }
        });
      }
    } catch (e) {
      debugPrint('Fetch notes error: $e');
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _setupRealtime() {
    _realtimeChannel?.unsubscribe();
    _realtimeChannel = Supabase.instance.client
        .channel('notes_vault_${widget.vaultId}')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'notes',
          callback: (_) {
            _syncFromCloudSilently();
          },
        )
        .onBroadcast(
          event: 'sync',
          callback: (_) {
            _syncFromCloudSilently();
          },
        )
        .subscribe();
  }

  void _onNoteLocallyUpdated(
      String noteId, String newTitle, String newPlainText, String newContent) {
    final index = _notes.indexWhere((n) => n.id == noteId);
    if (index != -1) {
      final updated = _notes[index].copyWith(
        title: newTitle,
        plainText: newPlainText,
        content: newContent,
        updatedAt: DateTime.now(),
      );
      _notes[index] = updated;
      _notesNotifier.value = List.of(_notes);
      if (_selectedNote?.id == noteId) {
        _selectedNote = updated;
      }
    }
  }

  Future<void> _createNewNote() async {
    final newNote = Note(
      id: _generateUuid(),
      vaultId: widget.vaultId,
      title: 'Новая заметка',
      content: jsonEncode([
        {'insert': '\n'}
      ]),
      plainText: '',
      updatedAt: DateTime.now(),
    );

    _notes.insert(0, newNote);
    _notesNotifier.value = List.of(_notes);
    setState(() {
      _selectedNote = newNote;
    });

    try {
      await Supabase.instance.client.from('notes').insert(newNote.toMap());
      _broadcastSync();
    } catch (_) {}

    if (mounted && MediaQuery.of(context).size.width < 720) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => NoteEditorPage(
            initialNote: newNote,
            vaultId: widget.vaultId,
            notesNotifier: _notesNotifier,
            onNoteUpdated: _onNoteLocallyUpdated,
            onNoteDeleted: _deleteNote,
            onBroadcastSync: _broadcastSync,
          ),
        ),
      );
    }
  }

  Future<void> _confirmDeleteNote(Note note) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final isDark = Theme.of(ctx).brightness == Brightness.dark;
        return AlertDialog(
          backgroundColor: isDark ? const Color(0xFF1E1E24) : Colors.white,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          title: const Text('Удалить заметку?', style: TextStyle(fontSize: 18)),
          content: Text(
            'Заметка «${note.title.isEmpty ? "Без названия" : note.title}» будет удалена навсегда.',
            style: const TextStyle(fontSize: 14),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Отмена'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: Colors.red.shade600,
                foregroundColor: Colors.white,
              ),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Удалить'),
            ),
          ],
        );
      },
    );

    if (confirmed == true) {
      await _deleteNote(note.id);
    }
  }

  Future<void> _deleteNote(String noteId) async {
    _notes.removeWhere((n) => n.id == noteId);
    _notesNotifier.value = List.of(_notes);
    if (_selectedNote?.id == noteId) {
      setState(() {
        _selectedNote = _notes.isNotEmpty ? _notes.first : null;
      });
    }

    try {
      await Supabase.instance.client.from('notes').delete().eq('id', noteId);
      _broadcastSync();
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
    final isDesktop = MediaQuery.of(context).size.width >= 720;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyN, meta: true):
            _createNewNote,
        const SingleActivator(LogicalKeyboardKey.keyN, control: true):
            _createNewNote,
        const SingleActivator(LogicalKeyboardKey.keyF, meta: true): () {
          _searchFocusNode.requestFocus();
        },
        const SingleActivator(LogicalKeyboardKey.keyF, control: true): () {
          _searchFocusNode.requestFocus();
        },
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor:
              isDark ? const Color(0xFF141416) : const Color(0xFFFFFFFF),
          body: Row(
            children: [
              // Боковая панель заметок (Sidebar)
              Container(
                width: isDesktop ? 330 : MediaQuery.of(context).size.width,
                decoration: BoxDecoration(
                  color: isDark
                      ? const Color(0xFF1A1A1E)
                      : const Color(0xFFF8FAFC),
                  border: isDesktop
                      ? Border(
                          right: BorderSide(
                            color: isDark
                                ? const Color(0xFF27272E)
                                : const Color(0xFFE2E8F0),
                            width: 1,
                          ),
                        )
                      : null,
                ),
                child: Column(
                  children: [
                    _buildSidebarHeader(isDark),
                    _buildSearchBar(isDark),
                    Expanded(
                      child: ValueListenableBuilder<List<Note>>(
                        valueListenable: _notesNotifier,
                        builder: (context, notesList, _) {
                          final filteredNotes = notesList.where((n) {
                            if (_searchQuery.isEmpty) return true;
                            return n.title.toLowerCase().contains(_searchQuery) ||
                                n.plainText.toLowerCase().contains(_searchQuery);
                          }).toList();
                          return _buildNotesListView(
                              filteredNotes, isDark, isDesktop);
                        },
                      ),
                    ),
                  ],
                ),
              ),

              // Правая область редактора заметки (Desktop)
              if (isDesktop)
                Expanded(
                  child: _selectedNote == null
                      ? _buildEmptyState(isDark)
                      : NoteEditorView(
                          key: ValueKey(_selectedNote!.id),
                          note: _selectedNote!,
                          vaultId: widget.vaultId,
                          onNoteUpdated: _onNoteLocallyUpdated,
                          onDeleteRequested: () =>
                              _confirmDeleteNote(_selectedNote!),
                          onBroadcastSync: _broadcastSync,
                        ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSidebarHeader(bool isDark) {
    final accentColor = Theme.of(context).colorScheme.primary;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(7),
            decoration: BoxDecoration(
              color: accentColor.withAlpha(isDark ? 40 : 25),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(Icons.edit_note_rounded, color: accentColor, size: 22),
          ),
          const SizedBox(width: 10),
          const Text(
            'Заметки',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              letterSpacing: -0.3,
            ),
          ),
          const SizedBox(width: 8),
          ValueListenableBuilder<List<Note>>(
            valueListenable: _notesNotifier,
            builder: (context, notesList, _) {
              return Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: isDark
                      ? Colors.white.withAlpha(16)
                      : Colors.black.withAlpha(10),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '${notesList.length}',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: isDark ? Colors.white70 : Colors.black54,
                  ),
                ),
              );
            },
          ),
          const Spacer(),
          InkWell(
            onTap: _openSyncDialog,
            borderRadius: BorderRadius.circular(8),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
              decoration: BoxDecoration(
                color: accentColor.withAlpha(isDark ? 35 : 20),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: accentColor.withAlpha(isDark ? 90 : 60),
                  width: 1,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.cloud_done_rounded, size: 14, color: accentColor),
                  const SizedBox(width: 5),
                  Text(
                    widget.vaultId,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.8,
                      color: isDark ? Colors.white : accentColor,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 6),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              minimumSize: const Size(36, 36),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Новая',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            onPressed: _createNewNote,
          ),
        ],
      ),
    );
  }

  Widget _buildSearchBar(bool isDark) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: TextField(
        controller: _searchController,
        focusNode: _searchFocusNode,
        decoration: InputDecoration(
          hintText: 'Поиск заметок... (⌘F)',
          hintStyle: TextStyle(
            fontSize: 13,
            color: isDark ? Colors.white38 : Colors.black38,
          ),
          prefixIcon: Icon(
            Icons.search,
            size: 18,
            color: isDark ? Colors.white54 : Colors.black45,
          ),
          suffixIcon: _searchQuery.isNotEmpty
              ? IconButton(
                  icon: const Icon(Icons.clear, size: 16),
                  onPressed: () {
                    _searchController.clear();
                    setState(() => _searchQuery = '');
                  },
                )
              : null,
          filled: true,
          fillColor: isDark
              ? const Color(0xFF23232A)
              : const Color(0xFFEDF2F7),
          isDense: true,
          contentPadding:
              const EdgeInsets.symmetric(vertical: 9, horizontal: 10),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide.none,
          ),
        ),
        onChanged: (val) =>
            setState(() => _searchQuery = val.trim().toLowerCase()),
      ),
    );
  }

  Widget _buildNotesListView(
      List<Note> notes, bool isDark, bool isDesktop) {
    if (_isLoading && _notes.isEmpty) {
      return const Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }

    if (notes.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                _searchQuery.isEmpty
                    ? Icons.note_alt_outlined
                    : Icons.search_off_rounded,
                size: 38,
                color: isDark ? Colors.white24 : Colors.black26,
              ),
              const SizedBox(height: 12),
              Text(
                _searchQuery.isEmpty
                    ? 'Заметок пока нет\nНажмите «Новая», чтобы начать'
                    : 'Ничего не найдено',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  color: isDark ? Colors.white38 : Colors.black45,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      itemCount: notes.length,
      itemBuilder: (context, index) {
        final note = notes[index];
        final isSelected = isDesktop && _selectedNote?.id == note.id;

        return _NoteCardItem(
          note: note,
          isSelected: isSelected,
          isDark: isDark,
          onTap: () {
            setState(() => _selectedNote = note);
            if (!isDesktop) {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => NoteEditorPage(
                    initialNote: note,
                    vaultId: widget.vaultId,
                    notesNotifier: _notesNotifier,
                    onNoteUpdated: _onNoteLocallyUpdated,
                    onNoteDeleted: _deleteNote,
                    onBroadcastSync: _broadcastSync,
                  ),
                ),
              );
            }
          },
          onDelete: () => _confirmDeleteNote(note),
        );
      },
    );
  }

  Widget _buildEmptyState(bool isDark) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.article_outlined,
            size: 52,
            color: isDark ? Colors.white12 : Colors.black12,
          ),
          const SizedBox(height: 16),
          Text(
            'Выберите заметку из списка',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w500,
              color: isDark ? Colors.white54 : Colors.black54,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Или нажмите «Новая заметка» (⌘N)',
            style: TextStyle(
              fontSize: 13,
              color: isDark ? Colors.white24 : Colors.black26,
            ),
          ),
        ],
      ),
    );
  }
}

class _NoteCardItem extends StatefulWidget {
  final Note note;
  final bool isSelected;
  final bool isDark;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _NoteCardItem({
    required this.note,
    required this.isSelected,
    required this.isDark,
    required this.onTap,
    required this.onDelete,
  });

  @override
  State<_NoteCardItem> createState() => _NoteCardItemState();
}

class _NoteCardItemState extends State<_NoteCardItem> {
  bool _isHovered = false;

  void _copyNote() {
    final t = widget.note.title.trim();
    final p = widget.note.plainText.trim();
    final text = t.isEmpty ? p : '$t\n\n$p';
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Row(
          children: [
            Icon(Icons.check_circle, color: Colors.white, size: 18),
            SizedBox(width: 8),
            Text('Заметка скопирована в буфер обмена'),
          ],
        ),
        backgroundColor: Colors.green.shade700,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void _showCardContextMenu(TapDownDetails details) async {
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;

    final position = details.globalPosition;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        overlay.size.width - position.dx,
        overlay.size.height - position.dy,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      color: isDark ? const Color(0xFF222228) : Colors.white,
      items: [
        const PopupMenuItem<String>(
          value: 'copy',
          height: 38,
          child: Row(
            children: [
              Icon(Icons.copy_rounded, size: 18),
              SizedBox(width: 10),
              Text('Скопировать текст',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            ],
          ),
        ),
        const PopupMenuDivider(height: 1),
        PopupMenuItem<String>(
          value: 'delete',
          height: 38,
          child: Row(
            children: [
              Icon(Icons.delete_outline_rounded,
                  size: 18, color: Colors.red.shade400),
              const SizedBox(width: 10),
              Text(
                'Удалить заметку',
                style: TextStyle(
                  fontSize: 13,
                  color: Colors.red.shade400,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ],
    );

    if (!mounted) return;

    if (selected == 'copy') {
      _copyNote();
    } else if (selected == 'delete') {
      widget.onDelete();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;

    Color bgColor;
    if (widget.isSelected) {
      bgColor = widget.isDark
          ? const Color(0xFF282832)
          : const Color(0xFFEEF2FF);
    } else if (_isHovered) {
      bgColor = widget.isDark
          ? const Color(0xFF202028)
          : const Color(0xFFF1F5F9);
    } else {
      bgColor = Colors.transparent;
    }

    final title = widget.note.title.trim().isEmpty
        ? 'Без названия'
        : widget.note.title.trim();
    final preview = widget.note.plainText.trim().isEmpty
        ? 'Нет дополнительного текста'
        : widget.note.plainText.replaceAll('\n', ' ').trim();

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        onSecondaryTapDown: _showCardContextMenu,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          margin: const EdgeInsets.symmetric(vertical: 3),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(10),
            border: widget.isSelected
                ? Border.all(color: accent.withAlpha(120), width: 1.2)
                : Border.all(color: Colors.transparent, width: 1.2),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: widget.isSelected
                            ? FontWeight.bold
                            : FontWeight.w600,
                        color: widget.isDark
                            ? Colors.white
                            : const Color(0xFF0F172A),
                      ),
                    ),
                  ),
                  if (_isHovered || widget.isSelected) ...[
                    InkWell(
                      borderRadius: BorderRadius.circular(6),
                      onTap: _copyNote,
                      child: Padding(
                        padding: const EdgeInsets.all(2),
                        child: Icon(
                          Icons.copy_rounded,
                          size: 15,
                          color: widget.isDark
                              ? Colors.white60
                              : Colors.black45,
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    InkWell(
                      borderRadius: BorderRadius.circular(6),
                      onTap: widget.onDelete,
                      child: Padding(
                        padding: const EdgeInsets.all(2),
                        child: Icon(
                          Icons.delete_outline,
                          size: 16,
                          color: Colors.red.withAlpha(180),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  Text(
                    widget.note.formattedDate,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: widget.isSelected
                          ? accent
                          : (widget.isDark ? Colors.white54 : Colors.black45),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      preview,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: widget.isDark ? Colors.white38 : Colors.black45,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class NoteEditorPage extends StatelessWidget {
  final Note initialNote;
  final String vaultId;
  final ValueNotifier<List<Note>> notesNotifier;
  final Function(String, String, String, String) onNoteUpdated;
  final Function(String) onNoteDeleted;
  final VoidCallback onBroadcastSync;

  const NoteEditorPage({
    super.key,
    required this.initialNote,
    required this.vaultId,
    required this.notesNotifier,
    required this.onNoteUpdated,
    required this.onNoteDeleted,
    required this.onBroadcastSync,
  });

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<Note>>(
      valueListenable: notesNotifier,
      builder: (context, notes, _) {
        final currentNote = notes.firstWhere(
          (n) => n.id == initialNote.id,
          orElse: () => initialNote,
        );
        return Scaffold(
          appBar: AppBar(
            title:
                Text(currentNote.title.isEmpty ? 'Заметка' : currentNote.title),
            elevation: 0,
          ),
          body: NoteEditorView(
            key: ValueKey(currentNote.id),
            note: currentNote,
            vaultId: vaultId,
            onNoteUpdated: onNoteUpdated,
            onDeleteRequested: () {
              Navigator.of(context).pop();
              onNoteDeleted(currentNote.id);
            },
            onBroadcastSync: onBroadcastSync,
          ),
        );
      },
    );
  }
}

class AppImageCache {
  static final Map<String, Uint8List> _cache = {};

  static void put(String url, Uint8List bytes) {
    if (_cache.length > 80) {
      _cache.remove(_cache.keys.first);
    }
    _cache[url] = bytes;
  }

  static Uint8List? get(String url) => _cache[url];
  static bool has(String url) => _cache.containsKey(url);
}

class AppImageEmbedBuilder extends EmbedBuilder {
  const AppImageEmbedBuilder();

  @override
  String get key => BlockEmbed.imageType;

  @override
  bool get expanded => false;

  @override
  Widget build(BuildContext context, EmbedContext embedContext) {
    return _AppImageItemWidget(embedContext: embedContext);
  }
}

class _AppImageItemWidget extends StatefulWidget {
  final EmbedContext embedContext;

  const _AppImageItemWidget({required this.embedContext});

  @override
  State<_AppImageItemWidget> createState() => _AppImageItemWidgetState();
}

class _AppImageItemWidgetState extends State<_AppImageItemWidget> {
  bool _isHovered = false;

  void _deleteImage() {
    final offset = widget.embedContext.node.documentOffset;
    final length = widget.embedContext.node.length;
    widget.embedContext.controller.replaceText(
      offset,
      length,
      '',
      null,
    );
    widget.embedContext.controller.updateSelection(
      TextSelection.collapsed(offset: offset),
      ChangeSource.local,
    );
  }

  Future<void> _handleCopyImage(String imageSource) async {
    try {
      Uint8List? bytes;
      if (imageSource.startsWith('data:image/') ||
          imageSource.contains('base64')) {
        final base64String =
            imageSource.contains(',') ? imageSource.split(',')[1] : imageSource;
        bytes = base64Decode(base64String);
      } else if (imageSource.startsWith('http://') ||
          imageSource.startsWith('https://')) {
        final res = await http.get(Uri.parse(imageSource));
        if (res.statusCode == 200) {
          bytes = res.bodyBytes;
        }
      }

      if (bytes != null && bytes.isNotEmpty) {
        final base64Str = base64Encode(bytes);
        copyImageViaNativeBridge(base64Str);
        await Pasteboard.writeImage(bytes);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Row(
                children: [
                  Icon(Icons.check_circle, color: Colors.white, size: 18),
                  SizedBox(width: 8),
                  Text('Изображение скопировано в буфер обмена'),
                ],
              ),
              backgroundColor: Colors.green.shade700,
              behavior: SnackBarBehavior.floating,
              duration: const Duration(seconds: 2),
            ),
          );
        }
        return;
      }
    } catch (e) {
      debugPrint('Error copying image: $e');
    }

    Clipboard.setData(ClipboardData(text: imageSource));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Ссылка на изображение скопирована'),
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  void _showLightbox(Widget imageWidget, String imageSource) {
    showDialog(
      context: context,
      builder: (dialogCtx) => Dialog(
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
            Positioned(
              top: 12,
              right: 12,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.black.withAlpha(160),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: IconButton(
                      icon: const Icon(Icons.copy_rounded,
                          color: Colors.white, size: 20),
                      tooltip: 'Скопировать изображение',
                      onPressed: () => _handleCopyImage(imageSource),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.red.withAlpha(200),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: IconButton(
                      icon: const Icon(Icons.delete_outline,
                          color: Colors.white, size: 22),
                      tooltip: 'Удалить изображение',
                      onPressed: () {
                        Navigator.of(dialogCtx).pop();
                        _deleteImage();
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.black.withAlpha(160),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: IconButton(
                      icon: const Icon(Icons.close,
                          color: Colors.white, size: 24),
                      tooltip: 'Закрыть',
                      onPressed: () => Navigator.of(dialogCtx).pop(),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showContextMenu(
      TapDownDetails details, String imageSource, Widget imageWidget) async {
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;

    final position = details.globalPosition;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        overlay.size.width - position.dx,
        overlay.size.height - position.dy,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      color: isDark ? const Color(0xFF222228) : Colors.white,
      items: [
        const PopupMenuItem<String>(
          value: 'copy_image',
          height: 38,
          child: Row(
            children: [
              Icon(Icons.copy_rounded, size: 18),
              SizedBox(width: 10),
              Text(
                'Скопировать изображение',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
        const PopupMenuItem<String>(
          value: 'copy_link',
          height: 38,
          child: Row(
            children: [
              Icon(Icons.link_rounded, size: 18),
              SizedBox(width: 10),
              Text('Скопировать ссылку', style: TextStyle(fontSize: 13)),
            ],
          ),
        ),
        const PopupMenuItem<String>(
          value: 'view',
          height: 38,
          child: Row(
            children: [
              Icon(Icons.fullscreen_rounded, size: 18),
              SizedBox(width: 10),
              Text('Открыть на весь экран', style: TextStyle(fontSize: 13)),
            ],
          ),
        ),
        const PopupMenuDivider(height: 1),
        PopupMenuItem<String>(
          value: 'delete',
          height: 38,
          child: Row(
            children: [
              Icon(Icons.delete_outline_rounded,
                  size: 18, color: Colors.red.shade400),
              const SizedBox(width: 10),
              Text(
                'Удалить изображение',
                style: TextStyle(
                  fontSize: 13,
                  color: Colors.red.shade400,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ],
    );

    if (!mounted) return;

    if (selected == 'copy_image') {
      _handleCopyImage(imageSource);
    } else if (selected == 'copy_link') {
      Clipboard.setData(ClipboardData(text: imageSource));
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Ссылка скопирована в буфер обмена'),
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 2),
        ),
      );
    } else if (selected == 'delete') {
      _deleteImage();
    } else if (selected == 'view') {
      _showLightbox(imageWidget, imageSource);
    }
  }

  @override
  Widget build(BuildContext context) {
    final imageSource = widget.embedContext.node.value.data.toString();

    Widget imageWidget;
    final cachedBytes = AppImageCache.get(imageSource);
    if (cachedBytes != null) {
      imageWidget = Image.memory(
        cachedBytes,
        fit: BoxFit.contain,
      );
    } else if (imageSource.startsWith('data:image/') ||
        imageSource.contains('base64')) {
      final base64String =
          imageSource.contains(',') ? imageSource.split(',')[1] : imageSource;
      try {
        final decoded = base64Decode(base64String);
        AppImageCache.put(imageSource, decoded);
        imageWidget = Image.memory(
          decoded,
          fit: BoxFit.contain,
        );
      } catch (_) {
        imageWidget = const Icon(Icons.broken_image, size: 40);
      }
    } else {
      imageWidget = Image.network(
        imageSource,
        fit: BoxFit.contain,
        frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
          if (wasSynchronouslyLoaded || frame != null) {
            return child;
          }
          return Container(
            height: 160,
            width: 220,
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
        onTap: () => _showLightbox(imageWidget, imageSource),
        onSecondaryTapDown: (details) =>
            _showContextMenu(details, imageSource, imageWidget),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _isHovered = true),
          onExit: (_) => setState(() => _isHovered = false),
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: 550,
              maxHeight: 450,
            ),
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: isDark ? Colors.white30 : Colors.black26,
                  width: 1.5,
                ),
                color: isDark
                    ? Colors.white.withAlpha(12)
                    : Colors.black.withAlpha(8),
              ),
              child: Stack(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8.5),
                    child: imageWidget,
                  ),
                  if (_isHovered)
                    Positioned(
                      top: 8,
                      right: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 4, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.black.withAlpha(200),
                          borderRadius: BorderRadius.circular(8),
                          boxShadow: const [
                            BoxShadow(
                              color: Colors.black26,
                              blurRadius: 4,
                              offset: Offset(0, 2),
                            ),
                          ],
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(
                                Icons.copy_rounded,
                                size: 18,
                                color: Colors.white,
                              ),
                              tooltip: 'Скопировать изображение',
                              constraints: const BoxConstraints(
                                minWidth: 32,
                                minHeight: 32,
                              ),
                              padding: const EdgeInsets.all(6),
                              onPressed: () => _handleCopyImage(imageSource),
                            ),
                            IconButton(
                              icon: const Icon(
                                Icons.fullscreen_rounded,
                                size: 20,
                                color: Colors.white,
                              ),
                              tooltip: 'Открыть на весь экран',
                              constraints: const BoxConstraints(
                                minWidth: 32,
                                minHeight: 32,
                              ),
                              padding: const EdgeInsets.all(6),
                              onPressed: () =>
                                  _showLightbox(imageWidget, imageSource),
                            ),
                            IconButton(
                              icon: Icon(
                                Icons.delete_outline_rounded,
                                size: 19,
                                color: Colors.red.shade300,
                              ),
                              tooltip: 'Удалить изображение',
                              constraints: const BoxConstraints(
                                minWidth: 32,
                                minHeight: 32,
                              ),
                              padding: const EdgeInsets.all(6),
                              onPressed: _deleteImage,
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
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
  final Function(String, String, String, String)? onNoteUpdated;
  final VoidCallback? onDeleteRequested;
  final VoidCallback? onBroadcastSync;

  const NoteEditorView({
    super.key,
    required this.note,
    required this.vaultId,
    this.onNoteUpdated,
    this.onDeleteRequested,
    this.onBroadcastSync,
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
  DateTime _lastLocalEditTime = DateTime.fromMillisecondsSinceEpoch(0);

  final ValueNotifier<bool> _isSavingNotifier = ValueNotifier(false);
  final ValueNotifier<bool> _isSavedNotifier = ValueNotifier(true);

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.note.title);
    _lastSavedTitle = widget.note.title;
    _lastSavedContent = widget.note.content;

    final controllerConfig = QuillControllerConfig(
      clipboardConfig: QuillClipboardConfig(
        onImagePaste: (bytes) async {
          await _insertImageBytes(bytes);
          return null; // Предотвращаем дублирование вставки библиотекой
        },
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
    _docChangeSub = _quillController.changes.listen((_) => _onContentChanged());

    // Слушатель веб-события вставки изображения (Cmd+V в WKWebView)
    WebPasteListener.setHandler((bytes) {
      if (mounted) {
        _insertImageBytes(bytes);
      }
    });
  }

  @override
  void didUpdateWidget(covariant NoteEditorView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.note.id != widget.note.id) {
      _debounceTimer?.cancel();
      _saveNote();

      _titleController.text = widget.note.title;
      _lastSavedTitle = widget.note.title;
      _lastSavedContent = widget.note.content;

      _docChangeSub?.pause();
      if (widget.note.content.isNotEmpty) {
        try {
          final decoded = jsonDecode(widget.note.content);
          _quillController.document = Document.fromJson(decoded);
        } catch (_) {
          _quillController.document = Document();
        }
      } else {
        _quillController.document = Document();
      }
      _quillController.updateSelection(
        const TextSelection.collapsed(offset: 0),
        ChangeSource.local,
      );
      _docChangeSub?.resume();
      _isSavedNotifier.value = true;
    } else {
      final remoteTitle = widget.note.title;
      final remoteContent = widget.note.content;

      final bool titleChanged =
          remoteTitle != _lastSavedTitle && remoteTitle != _titleController.text;
      final bool contentChanged = remoteContent != _lastSavedContent;

      if (titleChanged || contentChanged) {
        final msSinceLocalEdit =
            DateTime.now().difference(_lastLocalEditTime).inMilliseconds;
        // Применяем изменения из облака, если пользователь не печатает прямо в эту секунду
        if (msSinceLocalEdit > 350) {
          _lastSavedTitle = remoteTitle;
          _lastSavedContent = remoteContent;
          _isSavedNotifier.value = true;

          if (titleChanged) {
            _titleController.text = remoteTitle;
          }
          if (contentChanged && remoteContent.isNotEmpty) {
            try {
              final decoded = jsonDecode(remoteContent);
              final newDoc = Document.fromJson(decoded);
              _docChangeSub?.pause();
              final oldSelection = _quillController.selection;
              _quillController.document = newDoc;
              final newLen = _quillController.document.length;
              final safeOffset = oldSelection.baseOffset.clamp(0, newLen - 1);
              _quillController.updateSelection(
                TextSelection.collapsed(offset: safeOffset),
                ChangeSource.local,
              );
              _docChangeSub?.resume();
            } catch (_) {}
          }
        }
      }
    }
  }

  void _onTitleChanged() {
    _scheduleSave();
  }

  void _onContentChanged() {
    _scheduleSave();
  }

  void _scheduleSave() {
    _lastLocalEditTime = DateTime.now();
    _isSavedNotifier.value = false;
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 350), _saveNote);
  }

  Future<void> _saveNote() async {
    final title = _titleController.text.trim();
    final content = jsonEncode(_quillController.document.toDelta().toJson());

    if (title == _lastSavedTitle && content == _lastSavedContent) {
      _isSavedNotifier.value = true;
      return;
    }

    _lastSavedTitle = title;
    _lastSavedContent = content;
    _isSavingNotifier.value = true;

    try {
      final plainText = _quillController.document.toPlainText().trim();

      // Уведомляем сайдбар о сохранении новых данных
      widget.onNoteUpdated?.call(widget.note.id, title, plainText, content);

      await Supabase.instance.client.from('notes').upsert({
        'id': widget.note.id,
        'vault_id': widget.vaultId,
        'title': title,
        'content': content,
        'plain_text': plainText,
        'updated_at': DateTime.now().toIso8601String(),
      });
      _isSavedNotifier.value = true;
      widget.onBroadcastSync?.call();
    } catch (_) {
    } finally {
      _isSavingNotifier.value = false;
    }
  }

  @override
  void dispose() {
    WebPasteListener.setHandler(null);
    _debounceTimer?.cancel();
    _docChangeSub?.cancel();
    _saveNote();
    _titleController.dispose();
    _quillController.dispose();
    _isSavingNotifier.dispose();
    _isSavedNotifier.dispose();
    super.dispose();
  }

  Future<Uint8List> _optimizeImageBytes(Uint8List bytes) async {
    try {
      if (bytes.length < 300 * 1024) {
        return bytes;
      }
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final image = frame.image;
      final width = image.width;
      final height = image.height;

      const maxDim = 1600;
      if (width <= maxDim && height <= maxDim) {
        return bytes;
      }

      int targetWidth = width;
      int targetHeight = height;
      if (width > height) {
        targetWidth = maxDim;
        targetHeight = (height * maxDim / width).round();
      } else {
        targetHeight = maxDim;
        targetWidth = (width * maxDim / height).round();
      }

      final targetCodec = await ui.instantiateImageCodec(
        bytes,
        targetWidth: targetWidth,
        targetHeight: targetHeight,
      );
      final targetFrame = await targetCodec.getNextFrame();
      final targetImg = targetFrame.image;
      final byteData =
          await targetImg.toByteData(format: ui.ImageByteFormat.png);
      if (byteData != null) {
        return byteData.buffer.asUint8List();
      }
    } catch (e) {
      debugPrint('Optimization error: $e');
    }
    return bytes;
  }

  Future<String?> _uploadImageToStorage(Uint8List bytes) async {
    try {
      final optimized = await _optimizeImageBytes(bytes);
      final isJpeg =
          optimized.length > 2 && optimized[0] == 0xFF && optimized[1] == 0xD8;
      final ext = isJpeg ? 'jpg' : 'png';
      final mime = isJpeg ? 'image/jpeg' : 'image/png';

      final fileName = '${DateTime.now().millisecondsSinceEpoch}.$ext';
      final storagePath = '${widget.vaultId}/$fileName';

      await Supabase.instance.client.storage.from('note-images').uploadBinary(
            storagePath,
            optimized,
            fileOptions: FileOptions(contentType: mime),
          );

      return Supabase.instance.client.storage
          .from('note-images')
          .getPublicUrl(storagePath);
    } catch (_) {
      return null;
    }
  }

  bool _isInsertingImage = false;

  void _replaceImageSourceInDocument(String oldSource, String newSource) {
    final jsonList = _quillController.document.toDelta().toJson();
    bool found = false;
    for (final item in jsonList) {
      if (item is Map) {
        final insert = item['insert'];
        if (insert is Map && insert['image'] == oldSource) {
          insert['image'] = newSource;
          found = true;
        }
      }
    }
    if (found) {
      final newContent = jsonEncode(jsonList);
      _lastSavedContent = newContent;
      _lastLocalEditTime = DateTime.now();

      final oldSelection = _quillController.selection;
      _docChangeSub?.pause();
      _quillController.document = Document.fromJson(jsonList);
      final maxOffset = _quillController.document.length - 1;
      final safeOffset =
          oldSelection.baseOffset.clamp(0, maxOffset < 0 ? 0 : maxOffset);
      _quillController.updateSelection(
        TextSelection.collapsed(offset: safeOffset),
        ChangeSource.local,
      );
      _docChangeSub?.resume();
    }
  }

  Future<void> _insertImageBytes(Uint8List bytes) async {
    if (_isInsertingImage) return;
    _isInsertingImage = true;

    try {
      final index = _quillController.selection.baseOffset;
      final length = _quillController.selection.extentOffset - index;
      final safeIndex =
          index < 0 ? _quillController.document.length - 1 : index;
      final safeLength = length < 0 ? 0 : length;

      // 1. МГНОВЕННОЕ локальное превью (0 мс задержки!)
      final isJpeg = bytes.length > 2 && bytes[0] == 0xFF && bytes[1] == 0xD8;
      final mime = isJpeg ? 'image/jpeg' : 'image/png';
      final tempBase64 = base64Encode(bytes);
      final localDataUrl = 'data:$mime;base64,$tempBase64';

      // Сохраняем байты в кэш для мгновенного плавного рендера
      AppImageCache.put(localDataUrl, bytes);

      _quillController.replaceText(
        safeIndex,
        safeLength,
        BlockEmbed.image(localDataUrl),
        null,
      );
      _quillController.updateSelection(
        TextSelection.collapsed(offset: safeIndex + 1),
        ChangeSource.local,
      );
      _onContentChanged();

      // 2. Фоновая оптимизированная загрузка в Supabase Storage
      _isSavingNotifier.value = true;
      try {
        final cloudUrl = await _uploadImageToStorage(bytes);
        if (cloudUrl != null && mounted) {
          // Кэшируем байты по cloudUrl ДО подмены в документе, чтобы не было мерцания
          AppImageCache.put(cloudUrl, bytes);
          // Подменяем локальный base64 постоянным облачным URL
          _replaceImageSourceInDocument(localDataUrl, cloudUrl);
          _saveNote();
        }
      } catch (_) {
      } finally {
        if (mounted) _isSavingNotifier.value = false;
      }
    } finally {
      _isInsertingImage = false;
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
    } catch (_) {}
  }

  void _copyNoteContent() {
    final title = _titleController.text.trim();
    final plainText = _quillController.document.toPlainText().trim();
    final fullText = title.isEmpty ? plainText : '$title\n\n$plainText';

    Clipboard.setData(ClipboardData(text: fullText));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Row(
          children: [
            Icon(Icons.check_circle, color: Colors.white, size: 18),
            SizedBox(width: 8),
            Text('Текст заметки скопирован в буфер обмена'),
          ],
        ),
        backgroundColor: Colors.green.shade700,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Column(
      children: [
        // Верхняя панель заметки (Заголовок, статус сохранения, действия)
        Padding(
          padding: const EdgeInsets.fromLTRB(28, 16, 24, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: TextField(
                  controller: _titleController,
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    letterSpacing: -0.4,
                    color: isDark ? Colors.white : const Color(0xFF0F172A),
                  ),
                  decoration: InputDecoration(
                    hintText: 'Заголовок заметки',
                    hintStyle: TextStyle(
                      color: isDark ? Colors.white24 : Colors.black26,
                      fontWeight: FontWeight.w600,
                    ),
                    border: InputBorder.none,
                    isDense: true,
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              ),

              // Индикатор статуса сохранения
              ValueListenableBuilder<bool>(
                valueListenable: _isSavingNotifier,
                builder: (context, isSaving, _) {
                  if (isSaving) {
                    return Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          'Сохранение...',
                          style: TextStyle(
                            fontSize: 12,
                            color: isDark ? Colors.white38 : Colors.black45,
                          ),
                        ),
                      ],
                    );
                  }

                  return ValueListenableBuilder<bool>(
                    valueListenable: _isSavedNotifier,
                    builder: (context, isSaved, _) {
                      return Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            isSaved ? Icons.check_circle_outline : Icons.edit,
                            size: 14,
                            color: isSaved
                                ? Colors.green.withAlpha(200)
                                : (isDark ? Colors.white38 : Colors.black45),
                          ),
                          const SizedBox(width: 4),
                          Text(
                            isSaved ? 'Сохранено' : 'Не сохранено',
                            style: TextStyle(
                              fontSize: 12,
                              color: isDark ? Colors.white38 : Colors.black45,
                            ),
                          ),
                        ],
                      );
                    },
                  );
                },
              ),
              const SizedBox(width: 12),

              // Кнопка копирования всей заметки
              IconButton(
                icon: const Icon(Icons.copy_rounded, size: 20),
                tooltip: 'Скопировать весь текст заметки',
                onPressed: _copyNoteContent,
              ),

              // Кнопка вставки картинки
              IconButton(
                icon: const Icon(Icons.add_photo_alternate_outlined, size: 21),
                tooltip: 'Вставить изображение',
                onPressed: _pickImage,
              ),

              // Кнопка удаления заметки
              if (widget.onDeleteRequested != null)
                IconButton(
                  icon: Icon(
                    Icons.delete_outline,
                    size: 21,
                    color: Colors.red.withAlpha(190),
                  ),
                  tooltip: 'Удалить заметку',
                  onPressed: widget.onDeleteRequested,
                ),
            ],
          ),
        ),

        // Панель форматирования текста (Toolbar)
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
          decoration: BoxDecoration(
            color: isDark
                ? const Color(0xFF1E1E24)
                : const Color(0xFFF1F5F9),
            borderRadius: BorderRadius.circular(10),
          ),
          child: QuillSimpleToolbar(
            controller: _quillController,
            config: const QuillSimpleToolbarConfig(
              showFontFamily: false,
              showFontSize: false,
              showColorButton: false,
              showBackgroundColorButton: false,
              showSubscript: false,
              showSuperscript: false,
              showSearchButton: false,
              showInlineCode: true,
              showCodeBlock: true,
              showAlignmentButtons: false,
              showDirection: false,
              showLink: false,
              showListCheck: true,
              showListBullets: true,
              showListNumbers: true,
              showQuote: true,
              showIndent: false,
              showClearFormat: true,
              buttonOptions: QuillSimpleToolbarButtonOptions(
                base: QuillToolbarBaseButtonOptions(
                  iconSize: 18,
                ),
              ),
            ),
          ),
        ),

        // Поле текстового редактора
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(28, 12, 28, 16),
            child: QuillEditor.basic(
              controller: _quillController,
              config: const QuillEditorConfig(
                placeholder:
                    'Начните писать или вставьте текст / скриншот (⌘V)...',
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

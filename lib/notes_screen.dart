import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:ui';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:image/image.dart' as img;
import 'package:pasteboard/pasteboard.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'main.dart';
import 'note_model.dart';
import 'vault_service.dart';
import 'web_paste.dart';

class NotesScreen extends StatefulWidget {
  final String vaultId;
  final ValueChanged<String>? onVaultChanged;

  const NotesScreen({
    super.key,
    required this.vaultId,
    this.onVaultChanged,
  });

  @override
  State<NotesScreen> createState() => _NotesScreenState();
}

class _NotesScreenState extends State<NotesScreen> with WidgetsBindingObserver {
  final _searchController = TextEditingController();
  final _searchFocusNode = FocusNode();
  bool _isSearchHovered = false;

  final ValueNotifier<List<Note>> _notesNotifier =
      ValueNotifier<List<Note>>([]);
  List<Note> _notes = [];
  Set<String> _pinnedNoteIds = {};
  bool _isLoading = true;
  String _searchQuery = '';
  Note? _selectedNote;
  RealtimeChannel? _realtimeChannel;
  Timer? _periodicSyncTimer;
  Timer? _incomingSyncDebounce;
  final Map<String, DateTime> _lastLocalEditAt = {};

  SupabaseClient? _supabaseOrNull() {
    try {
      return Supabase.instance.client;
    } catch (_) {
      return null;
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _searchFocusNode.addListener(_onSearchFocusChange);
    WebPasteListener.setNewNoteHandler(_createNewNote);
    _loadPinnedNotes();
    _fetchNotes();
    _setupRealtime();
    _startPeriodicSync();
  }

  void _onSearchFocusChange() {
    if (mounted) setState(() {});
  }

  Future<void> _loadPinnedNotes() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = prefs.getStringList('pinned_${widget.vaultId}') ?? [];
      if (mounted) {
        setState(() => _pinnedNoteIds = list.toSet());
      }
    } catch (_) {}
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
    _periodicSyncTimer = Timer.periodic(const Duration(seconds: 8), (_) {
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

  void _onRemoteSyncSignal() {
    _incomingSyncDebounce?.cancel();
    _incomingSyncDebounce = Timer(const Duration(milliseconds: 250), () {
      if (mounted) {
        _syncFromCloudSilently();
      }
    });
  }

  void _setupRealtime() {
    final client = _supabaseOrNull();
    if (client == null) return;
    _realtimeChannel?.unsubscribe();
    _realtimeChannel = client
        .channel('notes_vault_${widget.vaultId}')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'notes',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'vault_id',
            value: widget.vaultId,
          ),
          callback: (_) {
            _onRemoteSyncSignal();
          },
        )
        .onBroadcast(
          event: 'sync',
          callback: (_) {
            _onRemoteSyncSignal();
          },
        )
        .onBroadcast(
          event: 'pin_toggle',
          callback: (payload) {
            final vault = payload['vault'];
            if (vault == widget.vaultId && mounted) {
              final list = payload['pinned'];
              if (list is List) {
                setState(() {
                  _pinnedNoteIds = list.map((e) => e.toString()).toSet();
                });
              }
            }
          },
        )
        .subscribe();
  }

  Future<void> _syncFromCloudSilently() async {
    final client = _supabaseOrNull();
    if (client == null) return;
    final syncStartedAt = DateTime.now();
    try {
      final response = await client
          .from('notes')
          .select()
          .eq('vault_id', widget.vaultId)
          .order('updated_at', ascending: false);

      final cloudNotes =
          (response as List).map((e) => Note.fromMap(e as Map)).toList();

      if (!mounted) return;

      // Preserve any fresh local edits that happened after this sync started
      final mergedNotes = <Note>[];
      for (final remoteNote in cloudNotes) {
        final lastEdit = _lastLocalEditAt[remoteNote.id];
        final isFreshLocalEdit = lastEdit != null &&
            lastEdit.isAfter(syncStartedAt.subtract(const Duration(seconds: 2)));
        if (isFreshLocalEdit) {
          final existingIdx = _notes.indexWhere((n) => n.id == remoteNote.id);
          if (existingIdx != -1) {
            mergedNotes.add(_notes[existingIdx]);
            continue;
          }
        }
        mergedNotes.add(remoteNote);
      }

      // Reconcile cloud pin state if explicit 'is_pinned' exists in note content
      final nextPinnedIds = Set<String>.from(_pinnedNoteIds);
      bool pinnedChanged = false;
      for (final n in mergedNotes) {
        final parsed = parseNoteContent(n.content);
        if (parsed.isPinned != null) {
          if (parsed.isPinned! && !nextPinnedIds.contains(n.id)) {
            nextPinnedIds.add(n.id);
            pinnedChanged = true;
          } else if (!parsed.isPinned! && nextPinnedIds.contains(n.id)) {
            nextPinnedIds.remove(n.id);
            pinnedChanged = true;
          }
        }
      }

      final localById = {for (final n in _notes) n.id: n};
      bool hasChanges = pinnedChanged || mergedNotes.length != _notes.length;
      if (!hasChanges) {
        for (final remote in mergedNotes) {
          final local = localById[remote.id];
          if (local == null ||
              local.title != remote.title ||
              local.content != remote.content ||
              local.isPinned != remote.isPinned) {
            hasChanges = true;
            break;
          }
        }
      }

      if (hasChanges) {
        setState(() {
          if (pinnedChanged) {
            _pinnedNoteIds = nextPinnedIds;
          }
          _notes = mergedNotes;
          _notesNotifier.value = List.of(_notes);

          if (_selectedNote != null) {
            final match = _notes.where((n) => n.id == _selectedNote!.id);
            if (match.isNotEmpty) {
              final remoteNote = match.first;
              if (remoteNote.title != _selectedNote!.title ||
                  remoteNote.content != _selectedNote!.content ||
                  remoteNote.isPinned != _selectedNote!.isPinned) {
                _selectedNote = remoteNote;
              }
            } else {
              _selectedNote = _notes.isNotEmpty ? _notes.first : null;
            }
          } else if (_notes.isNotEmpty) {
            _selectedNote = _notes.first;
          }
        });
        VaultService.saveCachedNotes(widget.vaultId, _notes);
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
      _pinnedNoteIds.clear();
      _lastLocalEditAt.clear();
      _isLoading = true;
      _loadPinnedNotes();
      _fetchNotes();
      _setupRealtime();
      _startPeriodicSync();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _periodicSyncTimer?.cancel();
    _incomingSyncDebounce?.cancel();
    WebPasteListener.setNewNoteHandler(null);
    _searchFocusNode.removeListener(_onSearchFocusChange);
    _searchController.dispose();
    _searchFocusNode.dispose();
    _notesNotifier.dispose();
    _realtimeChannel?.unsubscribe();
    super.dispose();
  }

  Future<void> _fetchNotes() async {
    // Show offline-cached notes immediately while fetching from cloud
    final cached = await VaultService.getCachedNotes(widget.vaultId);
    if (cached.isNotEmpty && mounted && _notes.isEmpty) {
      setState(() {
        _notes = cached;
        _notesNotifier.value = List.of(_notes);
        _isLoading = false;
        _selectedNote ??= _notes.first;
        for (final n in cached) {
          if (n.isPinned) _pinnedNoteIds.add(n.id);
        }
      });
    }

    final client = _supabaseOrNull();
    if (client == null) {
      if (mounted) setState(() => _isLoading = false);
      return;
    }

    try {
      final response = await client
          .from('notes')
          .select()
          .eq('vault_id', widget.vaultId)
          .order('updated_at', ascending: false);

      final list =
          (response as List).map((e) => Note.fromMap(e as Map)).toList();

      if (mounted) {
        setState(() {
          _notes = list;
          for (final n in list) {
            final parsed = parseNoteContent(n.content);
            if (parsed.isPinned != null) {
              if (parsed.isPinned!) {
                _pinnedNoteIds.add(n.id);
              } else {
                _pinnedNoteIds.remove(n.id);
              }
            }
          }
          _notesNotifier.value = List.of(_notes);
          _isLoading = false;
          if (_selectedNote == null && _notes.isNotEmpty) {
            _selectedNote = _notes.first;
          }
        });
        VaultService.saveCachedNotes(widget.vaultId, _notes);
      }
    } catch (e) {
      debugPrint('Error fetching notes: $e');
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _createNewNote() async {
    final newId = _generateUuidV4();
    final newNote = Note(
      id: newId,
      vaultId: widget.vaultId,
      title: '',
      content: jsonEncode({
        'delta': [
          {'insert': '\n'}
        ],
        'images': <dynamic>[],
      }),
      plainText: '',
      updatedAt: DateTime.now(),
      isPinned: false,
    );

    _lastLocalEditAt[newId] = DateTime.now();
    setState(() {
      _notes.insert(0, newNote);
      _notesNotifier.value = List.of(_notes);
      _selectedNote = newNote;
    });
    VaultService.saveCachedNotes(widget.vaultId, _notes);

    final client = _supabaseOrNull();
    if (client == null) return;
    try {
      await client.from('notes').insert(newNote.toMap());
      _broadcastSync();
    } catch (e) {
      debugPrint('Error creating note: $e');
    }
  }

  Future<void> _deleteNote(String id) async {
    final noteIndex = _notes.indexWhere((n) => n.id == id);
    if (noteIndex == -1) return;

    final removedNote = _notes[noteIndex];
    setState(() {
      _notes.removeAt(noteIndex);
      _notesNotifier.value = List.of(_notes);
      _pinnedNoteIds.remove(id);
      if (_selectedNote?.id == id) {
        _selectedNote = _notes.isNotEmpty ? _notes.first : null;
      }
    });
    VaultService.saveCachedNotes(widget.vaultId, _notes);

    final client = _supabaseOrNull();
    if (client == null) return;
    try {
      await client.from('notes').delete().eq('id', id);
      _broadcastSync();
      // Best-effort cleanup of images belonging to the deleted note
      final parsed = parseNoteContent(removedNote.content);
      final paths = parsed.images
          .map((img) => extractNoteImageStoragePath(img.url))
          .whereType<String>()
          .toList();
      if (paths.isNotEmpty) {
        client.storage.from('note-images').remove(paths).catchError((_) => <FileObject>[]);
      }
    } catch (e) {
      debugPrint('Error deleting note: $e');
      if (mounted) {
        setState(() {
          _notes.insert(noteIndex, removedNote);
          _notesNotifier.value = List.of(_notes);
        });
        VaultService.saveCachedNotes(widget.vaultId, _notes);
      }
    }
  }

  Future<void> _togglePinNote(Note note) async {
    final newPinned = !_pinnedNoteIds.contains(note.id);
    _lastLocalEditAt[note.id] = DateTime.now();

    final parsed = parseNoteContent(note.content);
    final updatedContent = jsonEncode({
      'delta': parsed.document.toDelta().toJson(),
      'images': parsed.images
          .where((e) => !e.url.startsWith('data:image/'))
          .map((e) => e.toJson())
          .toList(),
      'is_pinned': newPinned,
    });

    final updatedNote = note.copyWith(
      isPinned: newPinned,
      content: updatedContent,
    );

    setState(() {
      if (newPinned) {
        _pinnedNoteIds.add(note.id);
      } else {
        _pinnedNoteIds.remove(note.id);
      }
      final idx = _notes.indexWhere((n) => n.id == note.id);
      if (idx != -1) {
        _notes[idx] = updatedNote;
        _notesNotifier.value = List.of(_notes);
      }
      if (_selectedNote?.id == note.id) {
        _selectedNote = updatedNote;
      }
    });
    VaultService.saveCachedNotes(widget.vaultId, _notes);

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
          'pinned_${widget.vaultId}', _pinnedNoteIds.toList());

      final client = _supabaseOrNull();
      if (client != null) {
        await client.from('notes').upsert(updatedNote.toMap());
        _realtimeChannel?.sendBroadcastMessage(
          event: 'pin_toggle',
          payload: {
            'vault': widget.vaultId,
            'pinned': _pinnedNoteIds.toList(),
          },
        );
        _broadcastSync();
      }
    } catch (_) {}
  }

  void _handleNoteUpdated(
      String id, String title, String plainText, String content) {
    _lastLocalEditAt[id] = DateTime.now();
    final index = _notes.indexWhere((n) => n.id == id);
    if (index != -1) {
      final current = _notes[index];
      final updated = current.copyWith(
        title: title,
        plainText: plainText,
        content: content,
        updatedAt: DateTime.now(),
      );

      _notes[index] = updated;
      _notesNotifier.value = List.of(_notes);

      if (_selectedNote?.id == id) {
        _selectedNote = updated;
      }
      VaultService.saveCachedNotes(widget.vaultId, _notes);
    }
  }

  List<Note> get _filteredNotes {
    var list = _notes.map((n) {
      final isPinned = _pinnedNoteIds.contains(n.id);
      return n.isPinned != isPinned ? n.copyWith(isPinned: isPinned) : n;
    }).toList();

    if (_searchQuery.isNotEmpty) {
      final q = _searchQuery.toLowerCase();
      list = list.where((n) {
        return n.title.toLowerCase().contains(q) ||
            n.plainText.toLowerCase().contains(q);
      }).toList();
    }

    list.sort((a, b) {
      if (a.isPinned && !b.isPinned) return -1;
      if (!a.isPinned && b.isPinned) return 1;
      return b.updatedAt.compareTo(a.updatedAt);
    });
    return list;
  }

  void _showVaultDialog() {
    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'VaultDialog',
      transitionDuration: const Duration(milliseconds: 220),
      transitionBuilder: (context, a1, a2, child) {
        final curve = CurvedAnimation(parent: a1, curve: Curves.easeOutCubic);
        return ScaleTransition(
          scale: Tween<double>(begin: 0.94, end: 1.0).animate(curve),
          child: FadeTransition(opacity: curve, child: child),
        );
      },
      pageBuilder: (context, anim1, anim2) {
        return _VaultSyncDialog(
          vaultId: widget.vaultId,
          onVaultChanged: (newCode) => widget.onVaultChanged?.call(newCode),
        );
      },
    );
  }

  void _focusSearch() {
    _searchFocusNode.requestFocus();
    _searchController.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _searchController.text.length,
    );
  }

  void _toggleTheme() {
    final current = appThemeModeNotifier.value;
    final isDarkNow = current == ThemeMode.dark ||
        (current == ThemeMode.system &&
            WidgetsBinding.instance.platformDispatcher.platformBrightness ==
                Brightness.dark);

    final nextMode = isDarkNow ? ThemeMode.light : ThemeMode.dark;
    appThemeModeNotifier.value = nextMode;
    VaultService.setThemeMode(nextMode);
  }

  static String _generateUuidV4() {
    final rand = Random.secure();
    final bytes = List<int>.generate(16, (_) => rand.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final isDesktop = MediaQuery.sizeOf(context).width >= 720;

    if (isDesktop) {
      return CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.keyF, meta: true):
              _focusSearch,
          const SingleActivator(LogicalKeyboardKey.keyF, control: true):
              _focusSearch,
          const SingleActivator(LogicalKeyboardKey.keyN, meta: true):
              _createNewNote,
          const SingleActivator(LogicalKeyboardKey.keyN, control: true):
              _createNewNote,
          const SingleActivator(LogicalKeyboardKey.escape): () {
            if (_searchFocusNode.hasFocus) {
              if (_searchQuery.isNotEmpty) {
                _searchController.clear();
                setState(() => _searchQuery = '');
              } else {
                _searchFocusNode.unfocus();
              }
            }
          },
        },
        child: Scaffold(
          backgroundColor:
              isDark ? const Color(0xFF0D0E10) : const Color(0xFFF0F1F4),
          body: Row(
          children: [
            SizedBox(
              width: 270,
              child: _buildSidebar(),
            ),
            Expanded(
              child: Container(
                color:
                    isDark ? const Color(0xFF0D0E10) : const Color(0xFFF0F1F4),
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 180),
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeInCubic,
                  transitionBuilder: (child, animation) {
                    return FadeTransition(
                      opacity: animation,
                      child: SlideTransition(
                        position: Tween<Offset>(
                          begin: const Offset(0, 0.015),
                          end: Offset.zero,
                        ).animate(CurvedAnimation(
                          parent: animation,
                          curve: Curves.easeOutCubic,
                        )),
                        child: child,
                      ),
                    );
                  },
                  child: _selectedNote == null
                      ? KeyedSubtree(
                          key: const ValueKey('empty_state'),
                          child: _buildEmptyState(),
                        )
                      : KeyedSubtree(
                          key: ValueKey(_selectedNote!.id),
                          child: NoteEditorView(
                            note: _selectedNote!,
                            vaultId: widget.vaultId,
                            onNoteUpdated: _handleNoteUpdated,
                            onDeleteRequested: () =>
                                _deleteNote(_selectedNote!.id),
                            onBroadcastSync: _broadcastSync,
                          ),
                        ),
                ),
              ),
            ),
          ],
        ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      appBar: AppBar(
        title: GestureDetector(
          onTap: _showVaultDialog,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Заметки',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: Theme.of(context).cardColor,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  widget.vaultId,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          IconButton(
            icon: Icon(
              Theme.of(context).brightness == Brightness.dark
                  ? Icons.light_mode_rounded
                  : Icons.dark_mode_rounded,
              size: 20,
            ),
            tooltip: 'Переключить тему',
            onPressed: _toggleTheme,
          ),
          IconButton(
            icon: const Icon(Icons.add_rounded, size: 24),
            tooltip: 'Новая заметка',
            onPressed: _createNewNote,
          ),
        ],
        elevation: 0,
        backgroundColor: Colors.transparent,
      ),
      body: _buildMobileList(),
    );
  }

  Widget _buildEmptyState() {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 36, vertical: 32),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF141518) : Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isDark
                ? Colors.white.withOpacity(0.08)
                : Colors.black.withOpacity(0.07),
            width: 1.0,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(isDark ? 0.35 : 0.05),
              blurRadius: 20,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.edit_note_rounded,
              size: 44,
              color: theme.colorScheme.onSurfaceVariant.withOpacity(0.6),
            ),
            const SizedBox(height: 12),
            Text(
              'Выберите заметку или создайте новую',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 18),
            BouncingPressable(
              onTap: _createNewNote,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
                decoration: BoxDecoration(
                  color: const Color(0xFF6366F1),
                  borderRadius: BorderRadius.circular(10),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF6366F1).withOpacity(0.3),
                      blurRadius: 10,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.add_rounded, size: 16, color: Colors.white),
                    SizedBox(width: 6),
                    Text(
                      'Новая заметка',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSidebar() {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Container(
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF121316) : const Color(0xFFF6F7F9),
        border: Border(
          right: BorderSide(
            color: isDark
                ? Colors.white.withOpacity(0.06)
                : Colors.black.withOpacity(0.06),
            width: 1.0,
          ),
        ),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 12, 12),
            child: Row(
              children: [
                GestureDetector(
                  onTap: _showVaultDialog,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: isDark
                          ? const Color(0xFF181A1F)
                          : const Color(0xFFE5E7EB),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: isDark
                            ? Colors.white.withOpacity(0.06)
                            : Colors.black.withOpacity(0.06),
                        width: 1.0,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.cloud_outlined,
                          size: 13,
                          color: theme.colorScheme.primary,
                        ),
                        const SizedBox(width: 5),
                        Text(
                          widget.vaultId,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.5,
                            color: theme.colorScheme.primary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const Spacer(),
                IconButton(
                  icon: Icon(
                    isDark ? Icons.light_mode_rounded : Icons.dark_mode_rounded,
                    size: 18,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  tooltip: 'Сменить тему',
                  onPressed: _toggleTheme,
                  splashRadius: 18,
                ),
                BouncingPressable(
                  onTap: _createNewNote,
                  child: Container(
                    padding: const EdgeInsets.all(7),
                    decoration: BoxDecoration(
                      color: const Color(0xFF6366F1),
                      borderRadius: BorderRadius.circular(8),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFF6366F1).withOpacity(0.3),
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: const Icon(
                      Icons.add_rounded,
                      size: 16,
                      color: Colors.white,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
            child: MouseRegion(
              onEnter: (_) => setState(() => _isSearchHovered = true),
              onExit: (_) => setState(() => _isSearchHovered = false),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOutCubic,
                height: 36,
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xFF16181D) : Colors.white,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: _searchFocusNode.hasFocus
                        ? (isDark
                            ? Colors.white.withOpacity(0.20)
                            : Colors.black.withOpacity(0.20))
                        : (_isSearchHovered
                            ? (isDark
                                ? Colors.white.withOpacity(0.12)
                                : Colors.black.withOpacity(0.11))
                            : (isDark
                                ? Colors.white.withOpacity(0.06)
                                : Colors.black.withOpacity(0.06))),
                    width: 1.0,
                  ),
                  boxShadow: _searchFocusNode.hasFocus
                      ? [
                          BoxShadow(
                            color: (isDark ? Colors.white : Colors.black)
                                .withOpacity(0.04),
                            blurRadius: 8,
                            offset: const Offset(0, 2),
                          )
                        ]
                      : null,
                ),
                child: TextField(
                  controller: _searchController,
                  focusNode: _searchFocusNode,
                  style: TextStyle(
                      fontSize: 13, color: theme.colorScheme.onSurface),
                  onChanged: (val) => setState(() => _searchQuery = val),
                  decoration: InputDecoration(
                    prefixIcon: Icon(
                      Icons.search_rounded,
                      size: 16,
                      color: _searchFocusNode.hasFocus
                          ? theme.colorScheme.primary
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                    prefixIconConstraints:
                        const BoxConstraints(minWidth: 32, minHeight: 32),
                    suffixIcon: _searchQuery.isNotEmpty
                        ? GestureDetector(
                            onTap: () {
                              _searchController.clear();
                              setState(() => _searchQuery = '');
                            },
                            child: Icon(
                              Icons.close_rounded,
                              size: 15,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          )
                        : null,
                    hintText: 'Поиск заметок... (⌘F)',
                    hintStyle: TextStyle(
                      fontSize: 12,
                      color:
                          theme.colorScheme.onSurfaceVariant.withOpacity(0.6),
                    ),
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(vertical: 9),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: _isLoading
                ? Center(
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  )
                : _filteredNotes.isEmpty
                    ? Center(
                        child: Text(
                          _searchQuery.isNotEmpty
                              ? 'Ничего не найдено'
                              : 'Нет заметок',
                          style: TextStyle(
                            fontSize: 12,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 4),
                        itemCount: _filteredNotes.length,
                        itemBuilder: (context, index) {
                          final note = _filteredNotes[index];
                          final isSelected = _selectedNote?.id == note.id;
                          return _SidebarNoteCard(
                            key: ValueKey(note.id),
                            note: note,
                            isSelected: isSelected,
                            onTap: () => setState(() => _selectedNote = note),
                            onPinToggle: () => _togglePinNote(note),
                            onDelete: () => _deleteNote(note.id),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }

  Widget _buildMobileList() {
    final theme = Theme.of(context);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Container(
            height: 38,
            decoration: BoxDecoration(
              color: Theme.of(context).brightness == Brightness.dark
                  ? const Color(0xFF1B1D22)
                  : const Color(0xFFE9EBEF),
              borderRadius: BorderRadius.circular(10),
            ),
            child: TextField(
              controller: _searchController,
              onChanged: (val) => setState(() => _searchQuery = val),
              style:
                  TextStyle(fontSize: 14, color: theme.colorScheme.onSurface),
              decoration: InputDecoration(
                prefixIcon: Icon(Icons.search_rounded,
                    size: 18, color: theme.colorScheme.onSurfaceVariant),
                prefixIconConstraints:
                    const BoxConstraints(minWidth: 36, minHeight: 36),
                hintText: 'Поиск заметок...',
                hintStyle: TextStyle(
                  fontSize: 13,
                  color: theme.colorScheme.onSurfaceVariant.withAlpha(160),
                ),
                border: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(vertical: 9),
              ),
            ),
          ),
        ),
        Expanded(
          child: _filteredNotes.isEmpty
              ? Center(
                  child: Text(
                    _searchQuery.isNotEmpty
                        ? 'Ничего не найдено'
                        : 'Нет заметок',
                    style: TextStyle(
                        fontSize: 13,
                        color: theme.colorScheme.onSurfaceVariant),
                  ),
                )
              : ListView.builder(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  itemCount: _filteredNotes.length,
                  itemBuilder: (context, index) {
                    final note = _filteredNotes[index];
                    return Dismissible(
                      key: ValueKey(note.id),
                      direction: DismissDirection.horizontal,
                      background: Container(
                        alignment: Alignment.centerLeft,
                        padding: const EdgeInsets.only(left: 20),
                        color: Colors.indigo.shade600,
                        child: Icon(
                          note.isPinned
                              ? Icons.push_pin_outlined
                              : Icons.push_pin_rounded,
                          color: Colors.white,
                        ),
                      ),
                      secondaryBackground: Container(
                        alignment: Alignment.centerRight,
                        padding: const EdgeInsets.only(right: 20),
                        color: Colors.red.shade600,
                        child: const Icon(Icons.delete_outline_rounded,
                            color: Colors.white),
                      ),
                      confirmDismiss: (dir) async {
                        if (dir == DismissDirection.startToEnd) {
                          _togglePinNote(note);
                          return false;
                        } else {
                          return true;
                        }
                      },
                      onDismissed: (_) => _deleteNote(note.id),
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _MobileNoteCard(
                          note: note,
                          onTap: () {
                            Navigator.of(context).push(
                              CupertinoPageRoute(
                                builder: (ctx) => NoteMobileEditorScreen(
                                  note: note,
                                  vaultId: widget.vaultId,
                                  notesNotifier: _notesNotifier,
                                  onNoteUpdated: _handleNoteUpdated,
                                  onNoteDeleted: _deleteNote,
                                  onBroadcastSync: _broadcastSync,
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class BouncingPressable extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  const BouncingPressable({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
  });

  @override
  State<BouncingPressable> createState() => _BouncingPressableState();
}

class _BouncingPressableState extends State<BouncingPressable> {
  bool _isPressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _isPressed = true),
      onTapUp: (_) {
        setState(() => _isPressed = false);
        widget.onTap?.call();
      },
      onTapCancel: () => setState(() => _isPressed = false),
      onLongPress: widget.onLongPress,
      behavior: HitTestBehavior.opaque,
      child: AnimatedScale(
        scale: _isPressed ? 0.97 : 1.0,
        duration: const Duration(milliseconds: 100),
        curve: Curves.easeOutCubic,
        child: widget.child,
      ),
    );
  }
}

class _SidebarNoteCard extends StatefulWidget {
  final Note note;
  final bool isSelected;
  final VoidCallback onTap;
  final VoidCallback onPinToggle;
  final VoidCallback onDelete;

  const _SidebarNoteCard({
    super.key,
    required this.note,
    required this.isSelected,
    required this.onTap,
    required this.onPinToggle,
    required this.onDelete,
  });

  @override
  State<_SidebarNoteCard> createState() => _SidebarNoteCardState();
}

class _SidebarNoteCardState extends State<_SidebarNoteCard> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final title = widget.note.title.trim().isNotEmpty
        ? widget.note.title.trim()
        : 'Без названия';
    final preview = widget.note.plainText.trim();

    final borderColor = widget.isSelected
        ? (isDark
            ? Colors.white.withOpacity(0.18)
            : Colors.black.withOpacity(0.16))
        : (_isHovered
            ? (isDark
                ? Colors.white.withOpacity(0.12)
                : Colors.black.withOpacity(0.10))
            : (isDark
                ? Colors.white.withOpacity(0.04)
                : Colors.black.withOpacity(0.04)));

    final bgColor = widget.isSelected
        ? (isDark ? const Color(0xFF1E2026) : Colors.white)
        : (_isHovered
            ? (isDark ? const Color(0xFF181A1F) : const Color(0xFFF3F4F6))
            : Colors.transparent);

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: BouncingPressable(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutCubic,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: borderColor, width: 1.0),
              boxShadow: widget.isSelected
                  ? [
                      BoxShadow(
                        color: Colors.black.withOpacity(isDark ? 0.35 : 0.05),
                        blurRadius: 10,
                        offset: const Offset(0, 2),
                      ),
                    ]
                  : null,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    if (widget.note.isPinned) ...[
                      Icon(
                        Icons.push_pin_rounded,
                        size: 12,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(width: 4),
                    ],
                    Expanded(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: widget.isSelected
                              ? FontWeight.w700
                              : FontWeight.w600,
                          color: theme.colorScheme.onSurface,
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    if (_isHovered) ...[
                      GestureDetector(
                        onTap: widget.onPinToggle,
                        child: Icon(
                          widget.note.isPinned
                              ? Icons.push_pin_rounded
                              : Icons.push_pin_outlined,
                          size: 14,
                          color: widget.note.isPinned
                              ? theme.colorScheme.primary
                              : theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(width: 6),
                      GestureDetector(
                        onTap: widget.onDelete,
                        child: Icon(
                          Icons.delete_outline_rounded,
                          size: 14,
                          color: Colors.red.shade400,
                        ),
                      ),
                    ] else
                      Text(
                        widget.note.formattedDate,
                        style: TextStyle(
                          fontSize: 10,
                          color:
                              theme.colorScheme.onSurfaceVariant.withAlpha(180),
                        ),
                      ),
                  ],
                ),
                if (preview.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(
                    preview,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      height: 1.3,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MobileNoteCard extends StatelessWidget {
  final Note note;
  final VoidCallback onTap;

  const _MobileNoteCard({
    required this.note,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final title =
        note.title.trim().isNotEmpty ? note.title.trim() : 'Без названия';
    final preview = note.plainText.trim();

    return BouncingPressable(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF141518) : Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isDark
                ? Colors.white.withOpacity(0.08)
                : Colors.black.withOpacity(0.07),
            width: 1.0,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(isDark ? 0.30 : 0.05),
              blurRadius: 10,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (note.isPinned) ...[
                  Icon(
                    Icons.push_pin_rounded,
                    size: 13,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 6),
                ],
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                ),
                Text(
                  note.formattedDate,
                  style: TextStyle(
                    fontSize: 11,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            if (preview.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                preview,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.4,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class NoteMobileEditorScreen extends StatefulWidget {
  final Note note;
  final String vaultId;
  final ValueNotifier<List<Note>> notesNotifier;
  final Function(String id, String title, String plainText, String content)?
      onNoteUpdated;
  final Function(String id) onNoteDeleted;
  final VoidCallback? onBroadcastSync;

  const NoteMobileEditorScreen({
    super.key,
    required this.note,
    required this.vaultId,
    required this.notesNotifier,
    required this.onNoteUpdated,
    required this.onNoteDeleted,
    required this.onBroadcastSync,
  });

  @override
  State<NoteMobileEditorScreen> createState() => _NoteMobileEditorScreenState();
}

class _NoteMobileEditorScreenState extends State<NoteMobileEditorScreen> {
  String _title = '';

  void _handleNoteUpdated(
      String id, String title, String plainText, String content) {
    widget.onNoteUpdated?.call(id, title, plainText, content);
    if (mounted && _title != title) {
      setState(() => _title = title);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<Note>>(
      valueListenable: widget.notesNotifier,
      builder: (context, notesList, _) {
        final currentNote = notesList.firstWhere(
          (n) => n.id == widget.note.id,
          orElse: () => widget.note,
        );
        return Scaffold(
          backgroundColor: Theme.of(context).scaffoldBackgroundColor,
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            elevation: 0,
            leading: IconButton(
              icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 18),
              onPressed: () => Navigator.of(context).pop(),
            ),
            title: Text(
              _title.isNotEmpty
                  ? _title
                  : (currentNote.title.isEmpty ? 'Заметка' : currentNote.title),
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
          ),
          body: NoteEditorView(
            key: ValueKey(widget.note.id),
            note: currentNote,
            vaultId: widget.vaultId,
            isMobile: true,
            onNoteUpdated: _handleNoteUpdated,
            onDeleteRequested: () {
              Navigator.of(context).pop();
              widget.onNoteDeleted(widget.note.id);
            },
            onBroadcastSync: widget.onBroadcastSync,
          ),
        );
      },
    );
  }
}

class _VaultSyncDialog extends StatefulWidget {
  final String vaultId;
  final ValueChanged<String> onVaultChanged;

  const _VaultSyncDialog({
    required this.vaultId,
    required this.onVaultChanged,
  });

  @override
  State<_VaultSyncDialog> createState() => _VaultSyncDialogState();
}

class _VaultSyncDialogState extends State<_VaultSyncDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.vaultId);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final newCode = _controller.text.trim().toUpperCase();
    if (newCode.isNotEmpty && newCode != widget.vaultId) {
      await VaultService.setVaultId(newCode);
      if (mounted) {
        Navigator.of(context).pop();
        widget.onVaultChanged(newCode);
      }
    } else if (mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Center(
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: 380,
          padding: const EdgeInsets.all(28),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF16181D) : Colors.white,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: isDark
                  ? Colors.white.withAlpha(20)
                  : Colors.black.withAlpha(15),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withAlpha(isDark ? 80 : 30),
                blurRadius: 36,
                offset: const Offset(0, 16),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Синхронизация',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                  IconButton(
                    icon: Icon(Icons.close_rounded,
                        size: 20, color: theme.colorScheme.onSurfaceVariant),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withAlpha(20),
                      blurRadius: 16,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: QrImageView(
                  data: widget.vaultId,
                  version: QrVersions.auto,
                  size: 170,
                  gapless: true,
                ),
              ),
              const SizedBox(height: 18),
              Text(
                'Отсканируйте камерой телефона или введите код на другом устройстве:',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.4,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 16),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                decoration: BoxDecoration(
                  color: isDark
                      ? const Color(0xFF1E2026)
                      : const Color(0xFFF1F3F5),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: TextField(
                  controller: _controller,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 2,
                  ),
                  textCapitalization: TextCapitalization.characters,
                  onSubmitted: (_) => _submit(),
                  decoration: const InputDecoration(
                    border: InputBorder.none,
                    hintText: 'XXX-XXX',
                  ),
                ),
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                height: 44,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF6366F1),
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onPressed: _submit,
                  child: const Text(
                    'Подключить хранилище',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Extracts the relative storage path inside the `note-images` bucket from a Supabase public URL.
String? extractNoteImageStoragePath(String imageSource) {
  final uri = Uri.tryParse(imageSource);
  if (uri == null || !uri.hasScheme) return null;
  final idx = uri.pathSegments.indexOf('note-images');
  if (idx != -1 && idx + 1 < uri.pathSegments.length) {
    return uri.pathSegments.sublist(idx + 1).join('/');
  }
  return null;
}

class ParsedNoteContent {
  final Document document;
  final List<CanvasImage> images;
  final bool? isPinned;

  ParsedNoteContent({
    required this.document,
    required this.images,
    this.isPinned,
  });
}

/// Parses either the structured `{delta, images, is_pinned}` format or legacy Delta list format.
ParsedNoteContent parseNoteContent(String rawContent) {
  if (rawContent.isEmpty) {
    return ParsedNoteContent(document: Document(), images: []);
  }
  try {
    final decoded = jsonDecode(rawContent);
    if (decoded is Map && decoded['delta'] is List) {
      final doc = Document.fromJson(decoded['delta']);
      final images = decoded['images'] is List
          ? (decoded['images'] as List)
              .map((e) => CanvasImage.fromJson(Map<String, dynamic>.from(e)))
              .toList()
          : <CanvasImage>[];
      final bool? pinned = decoded.containsKey('is_pinned')
          ? decoded['is_pinned'] == true
          : null;
      return ParsedNoteContent(
          document: doc, images: images, isPinned: pinned);
    } else if (decoded is List) {
      final textOps = <Map<String, dynamic>>[];
      final extracted = <CanvasImage>[];
      double initialY = 20.0;
      for (final op in decoded) {
        if (op is Map && op['insert'] is Map && op['insert']['image'] != null) {
          extracted.add(CanvasImage(
            id: 'img_legacy_${extracted.length}_${op['insert']['image'].toString().hashCode}',
            url: op['insert']['image'].toString(),
            x: 20.0,
            y: initialY,
            width: 320.0,
          ));
          initialY += 240.0;
        } else if (op is Map) {
          textOps.add(Map<String, dynamic>.from(op));
        }
      }
      final doc = Document.fromJson(
          textOps.isNotEmpty ? textOps : [{'insert': '\n'}]);
      return ParsedNoteContent(document: doc, images: extracted);
    }
  } catch (_) {}
  return ParsedNoteContent(document: Document(), images: []);
}

/// Computes new position and dimensions for a canvas image resized from an edge or corner,
/// strictly locking aspect ratio and anchoring the opposite edge within `availableWidth`.
({double x, double width, double height}) computeEdgeResize({
  required double currentX,
  required double currentWidth,
  required double? currentHeight,
  required double? aspectRatio,
  required Offset delta,
  required String edge,
  required double availableWidth,
}) {
  final ar = (aspectRatio != null && aspectRatio > 0)
      ? aspectRatio
      : ((currentHeight != null && currentHeight > 0)
          ? (currentWidth / currentHeight)
          : 1.0);
  final minW = min(80.0, max(1.0, availableWidth));

  if (edge == 'left' || edge == 'bottom_left') {
    final rightEdge = min(availableWidth, currentX + currentWidth);
    final maxW = max(minW, rightEdge);
    final deltaW = edge == 'left'
        ? -delta.dx
        : (((-delta.dx * ar + delta.dy) / (ar * ar + 1.0)) * ar);
    final double newWidth = (currentWidth + deltaW).clamp(minW, maxW).toDouble();
    final double newHeight = newWidth / ar;
    final double newX = (rightEdge - newWidth)
        .clamp(0.0, max(0.0, availableWidth - newWidth))
        .toDouble();
    return (x: newX, width: newWidth, height: newHeight);
  }

  final maxW = max(minW, availableWidth - currentX);
  double deltaW;
  if (edge == 'right') {
    deltaW = delta.dx;
  } else if (edge == 'bottom') {
    deltaW = delta.dy * ar;
  } else {
    // bottom_right diagonal projection
    deltaW = ((delta.dx * ar + delta.dy) / (ar * ar + 1.0)) * ar;
  }
  final double newWidth = (currentWidth + deltaW).clamp(minW, maxW).toDouble();
  final double newHeight = newWidth / ar;
  final double newX =
      currentX.clamp(0.0, max(0.0, availableWidth - newWidth)).toDouble();
  return (x: newX, width: newWidth, height: newHeight);
}

class AppImageCache {
  static final Map<String, Uint8List> _cache = {};
  static int _totalBytes = 0;
  static const int _maxEntries = 60;
  static const int _maxBytes = 40 * 1024 * 1024; // 40 MB cap

  static void put(String url, Uint8List bytes) {
    final existing = _cache.remove(url);
    if (existing != null) {
      _totalBytes -= existing.length;
    }
    _cache[url] = bytes;
    _totalBytes += bytes.length;

    while (_cache.length > _maxEntries ||
        (_totalBytes > _maxBytes && _cache.length > 1)) {
      final oldestKey = _cache.keys.first;
      final removed = _cache.remove(oldestKey);
      if (removed != null) {
        _totalBytes -= removed.length;
      }
    }
  }

  static Uint8List? get(String url) {
    final bytes = _cache.remove(url);
    if (bytes != null) {
      // Refresh LRU position
      _cache[url] = bytes;
    }
    return bytes;
  }

  static bool has(String url) => _cache.containsKey(url);

  static void remove(String url) {
    final removed = _cache.remove(url);
    if (removed != null) {
      _totalBytes -= removed.length;
    }
  }

  static void clear() {
    _cache.clear();
    _totalBytes = 0;
  }

  static int get totalBytes => _totalBytes;
}

class CanvasImage {
  final String id;
  String url;
  double x;
  double y;
  double width;
  double? height;
  double? naturalWidth;
  double? naturalHeight;
  double? aspectRatio;
  bool uploadFailed;
  Uint8List? pendingBytes;

  CanvasImage({
    required this.id,
    required this.url,
    required this.x,
    required this.y,
    this.width = 320.0,
    this.height,
    this.naturalWidth,
    this.naturalHeight,
    this.aspectRatio,
    this.uploadFailed = false,
    this.pendingBytes,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'url': url,
        'x': x,
        'y': y,
        'width': width,
        if (height != null) 'height': height,
        if (naturalWidth != null) 'naturalWidth': naturalWidth,
        if (naturalHeight != null) 'naturalHeight': naturalHeight,
        if (aspectRatio != null) 'aspectRatio': aspectRatio,
      };

  factory CanvasImage.fromJson(Map<String, dynamic> json) {
    return CanvasImage(
      id: (json['id'] ?? '').toString(),
      url: (json['url'] ?? '').toString(),
      x: (json['x'] as num?)?.toDouble() ?? 20.0,
      y: (json['y'] as num?)?.toDouble() ?? 20.0,
      width: (json['width'] as num?)?.toDouble() ?? 320.0,
      height: (json['height'] as num?)?.toDouble(),
      naturalWidth: (json['naturalWidth'] as num?)?.toDouble(),
      naturalHeight: (json['naturalHeight'] as num?)?.toDouble(),
      aspectRatio: (json['aspectRatio'] as num?)?.toDouble(),
    );
  }
}

class ImageActions {
  static Future<void> copyImage(
      BuildContext context, String imageSource) async {
    try {
      Uint8List? bytes = AppImageCache.get(imageSource);
      if (bytes == null) {
        if (imageSource.startsWith('data:image/') ||
            imageSource.contains('base64')) {
          final base64String = imageSource.contains(',')
              ? imageSource.split(',')[1]
              : imageSource;
          bytes = base64Decode(base64String);
        } else {
          final storagePath = extractNoteImageStoragePath(imageSource);
          if (storagePath != null) {
            final res = await Supabase.instance.client.storage
                .from('note-images')
                .download(storagePath);
            bytes = res;
          }
        }
      }

      if (bytes != null && bytes.isNotEmpty) {
        if (kIsWeb) {
          final base64Str = base64Encode(bytes);
          copyImageViaNativeBridge(base64Str);
        } else {
          await Pasteboard.writeImage(bytes);
        }

        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Row(
                children: [
                  Icon(Icons.check_circle_rounded,
                      color: Colors.white, size: 16),
                  SizedBox(width: 8),
                  Text('Изображение скопировано в буфер'),
                ],
              ),
              backgroundColor: const Color(0xFF10B981),
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
  }

  static void showLightbox(
      BuildContext context, Widget imageWidget, String imageSource) {
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
                borderRadius: BorderRadius.circular(16),
                child: InteractiveViewer(child: imageWidget),
              ),
            ),
            Positioned(
              top: 12,
              right: 12,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(Icons.copy_rounded, color: Colors.white),
                    tooltip: 'Скопировать',
                    onPressed: () => copyImage(context, imageSource),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded, color: Colors.white),
                    tooltip: 'Закрыть',
                    onPressed: () => Navigator.of(dialogCtx).pop(),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CanvasImageWidget extends StatefulWidget {
  final CanvasImage image;
  final double maxWidth;
  final bool isMobile;
  final bool isSelected;
  final VoidCallback onSelect;
  final Function(Offset delta) onDragUpdate;
  final VoidCallback onDragEnd;
  final Function(Offset delta, String edge) onResizeEdge;
  final Function(double factor) onScaleStep;
  final VoidCallback onResetScale;
  final VoidCallback onDelete;
  final Function(String source) onCopy;
  final Function(String source, Widget imageWidget) onShowLightbox;
  final VoidCallback? onDimensionsResolved;
  final VoidCallback? onRetryUpload;

  const _CanvasImageWidget({
    super.key,
    required this.image,
    required this.maxWidth,
    required this.isMobile,
    this.isSelected = false,
    required this.onSelect,
    required this.onDragUpdate,
    required this.onDragEnd,
    required this.onResizeEdge,
    required this.onScaleStep,
    required this.onResetScale,
    required this.onDelete,
    required this.onCopy,
    required this.onShowLightbox,
    this.onDimensionsResolved,
    this.onRetryUpload,
  });

  @override
  State<_CanvasImageWidget> createState() => _CanvasImageWidgetState();
}

class _CanvasImageWidgetState extends State<_CanvasImageWidget> {
  bool _isHovered = false;
  bool _isDragging = false;
  bool _isResizing = false;
  ImageStream? _imageStream;
  ImageStreamListener? _imageStreamListener;

  @override
  void initState() {
    super.initState();
    _resolveImageDimensions();
  }

  @override
  void didUpdateWidget(covariant _CanvasImageWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.image.url != widget.image.url ||
        oldWidget.image.aspectRatio != widget.image.aspectRatio) {
      _resolveImageDimensions();
    }
  }

  @override
  void dispose() {
    _detachImageListener();
    super.dispose();
  }

  void _detachImageListener() {
    if (_imageStream != null && _imageStreamListener != null) {
      _imageStream!.removeListener(_imageStreamListener!);
    }
    _imageStream = null;
    _imageStreamListener = null;
  }

  void _resolveImageDimensions() {
    _detachImageListener();
    final imageSource = widget.image.url;
    ImageProvider? provider;
    final cachedBytes = AppImageCache.get(imageSource);
    if (cachedBytes != null) {
      provider = MemoryImage(cachedBytes);
    } else if (imageSource.startsWith('data:image/') ||
        imageSource.contains('base64')) {
      final base64String =
          imageSource.contains(',') ? imageSource.split(',')[1] : imageSource;
      try {
        provider = MemoryImage(base64Decode(base64String));
      } catch (_) {}
    } else {
      final uri = Uri.tryParse(imageSource);
      if (uri != null && uri.hasScheme) {
        provider = NetworkImage(imageSource);
      }
    }

    if (provider == null) return;

    final stream = provider.resolve(ImageConfiguration.empty);
    late ImageStreamListener listener;
    void applyResolved(ImageInfo info) {
      final nw = info.image.width.toDouble();
      final nh = info.image.height.toDouble();
      if (nw > 0 && nh > 0 && mounted) {
        final ar = nw / nh;
        final hadNoSavedMetadata = widget.image.aspectRatio == null &&
            widget.image.naturalWidth == null;
        bool shouldUpdate = false;

        if (widget.image.aspectRatio == null ||
            widget.image.naturalWidth == null) {
          widget.image.naturalWidth = nw;
          widget.image.naturalHeight = nh;
          widget.image.aspectRatio = ar;
          shouldUpdate = true;
        }

        // Auto-fit narrow screenshots ONLY on first uninitialized resolution so manual resizes stay intact
        if (hadNoSavedMetadata &&
            (widget.image.width == 320.0 || widget.image.width == 340.0) &&
            nw < widget.image.width) {
          widget.image.width = max(80.0, nw);
          widget.image.height = widget.image.width / ar;
          shouldUpdate = true;
        } else if (widget.image.height == null) {
          widget.image.height = widget.image.width / ar;
          shouldUpdate = true;
        }

        if (shouldUpdate) {
          setState(() {});
          widget.onDimensionsResolved?.call();
        }
      }
    }

    listener = ImageStreamListener((ImageInfo info, bool synchronousCall) {
      if (synchronousCall) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) applyResolved(info);
        });
      } else {
        applyResolved(info);
      }
      _detachImageListener();
    }, onError: (_, _) {
      _detachImageListener();
    });
    _imageStream = stream;
    _imageStreamListener = listener;
    stream.addListener(listener);
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
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      color: isDark ? const Color(0xFF1E2026) : Colors.white,
      items: [
        const PopupMenuItem<String>(
          value: 'copy_image',
          height: 36,
          child: Row(
            children: [
              Icon(Icons.copy_rounded, size: 16),
              SizedBox(width: 8),
              Text('Скопировать картинку', style: TextStyle(fontSize: 13)),
            ],
          ),
        ),
        const PopupMenuItem<String>(
          value: 'copy_link',
          height: 36,
          child: Row(
            children: [
              Icon(Icons.link_rounded, size: 16),
              SizedBox(width: 8),
              Text('Скопировать ссылку', style: TextStyle(fontSize: 13)),
            ],
          ),
        ),
        const PopupMenuDivider(height: 1),
        const PopupMenuItem<String>(
          value: 'zoom_in',
          height: 36,
          child: Row(
            children: [
              Icon(Icons.zoom_in_rounded, size: 16),
              SizedBox(width: 8),
              Text('Увеличить (+15%)', style: TextStyle(fontSize: 13)),
            ],
          ),
        ),
        const PopupMenuItem<String>(
          value: 'zoom_out',
          height: 36,
          child: Row(
            children: [
              Icon(Icons.zoom_out_rounded, size: 16),
              SizedBox(width: 8),
              Text('Уменьшить (-15%)', style: TextStyle(fontSize: 13)),
            ],
          ),
        ),
        const PopupMenuItem<String>(
          value: 'zoom_reset',
          height: 36,
          child: Row(
            children: [
              Icon(Icons.aspect_ratio_rounded, size: 16),
              SizedBox(width: 8),
              Text('Оригинальный размер (100%)', style: TextStyle(fontSize: 13)),
            ],
          ),
        ),
        const PopupMenuDivider(height: 1),
        const PopupMenuItem<String>(
          value: 'view',
          height: 36,
          child: Row(
            children: [
              Icon(Icons.fullscreen_rounded, size: 16),
              SizedBox(width: 8),
              Text('На весь экран', style: TextStyle(fontSize: 13)),
            ],
          ),
        ),
        const PopupMenuDivider(height: 1),
        PopupMenuItem<String>(
          value: 'delete',
          height: 36,
          child: Row(
            children: [
              Icon(Icons.delete_outline_rounded,
                  size: 16, color: Colors.red.shade400),
              const SizedBox(width: 8),
              Text(
                'Удалить',
                style: TextStyle(fontSize: 13, color: Colors.red.shade400),
              ),
            ],
          ),
        ),
      ],
    );

    if (!mounted) return;
    if (selected == 'copy_image') {
      widget.onCopy(imageSource);
    } else if (selected == 'copy_link') {
      Clipboard.setData(ClipboardData(text: imageSource));
    } else if (selected == 'zoom_in') {
      widget.onScaleStep(1.15);
    } else if (selected == 'zoom_out') {
      widget.onScaleStep(1 / 1.15);
    } else if (selected == 'zoom_reset') {
      widget.onResetScale();
    } else if (selected == 'delete') {
      widget.onDelete();
    } else if (selected == 'view') {
      widget.onShowLightbox(imageSource, imageWidget);
    }
  }

  Widget _buildImageContent() {
    final imageSource = widget.image.url;
    final cachedBytes = AppImageCache.get(imageSource);
    if (cachedBytes != null) {
      return Image.memory(
        cachedBytes,
        fit: BoxFit.cover,
        filterQuality: FilterQuality.high,
      );
    } else if (imageSource.startsWith('data:image/') ||
        imageSource.contains('base64')) {
      final base64String =
          imageSource.contains(',') ? imageSource.split(',')[1] : imageSource;
      try {
        final decoded = base64Decode(base64String);
        AppImageCache.put(imageSource, decoded);
        return Image.memory(
          decoded,
          fit: BoxFit.cover,
          filterQuality: FilterQuality.high,
        );
      } catch (_) {
        return const Icon(Icons.broken_image_rounded, size: 40);
      }
    } else {
      return Image.network(
        imageSource,
        fit: BoxFit.cover,
        filterQuality: FilterQuality.high,
        loadingBuilder: (context, child, loadingProgress) {
          if (loadingProgress == null) return child;
          return Container(
            alignment: Alignment.center,
            child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
          );
        },
        errorBuilder: (ctx, err, stack) =>
            const Icon(Icons.broken_image_rounded, size: 40),
      );
    }
  }

  Widget _buildEdgeHandle({
    required String edge,
    required MouseCursor cursor,
    required bool isDark,
    required bool visible,
    double? top,
    double? bottom,
    double? left,
    double? right,
    double? width,
    double? height,
  }) {
    final isHorizontal = edge == 'bottom';
    return Positioned(
      top: top,
      bottom: bottom,
      left: left,
      right: right,
      width: width,
      height: height,
      child: MouseRegion(
        cursor: cursor,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (_) {
            widget.onSelect();
            setState(() => _isResizing = true);
          },
          onPanUpdate: (details) => widget.onResizeEdge(details.delta, edge),
          onPanEnd: (_) {
            setState(() => _isResizing = false);
            widget.onDragEnd();
          },
          onPanCancel: () {
            setState(() => _isResizing = false);
            widget.onDragEnd();
          },
          child: Center(
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 160),
              opacity: visible ? 0.90 : 0.0,
              child: Container(
                width: isHorizontal ? 32 : 4,
                height: isHorizontal ? 4 : 32,
                decoration: BoxDecoration(
                  color: isDark
                      ? Colors.white.withOpacity(0.55)
                      : Colors.black.withOpacity(0.45),
                  borderRadius: BorderRadius.circular(2),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.3),
                      blurRadius: 4,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCornerHandle({
    required String edge,
    required MouseCursor cursor,
    required IconData icon,
    required bool isDark,
    required bool showHandle,
    double idleOpacity = 0.0,
    double? left,
    double? right,
  }) {
    final isRight = right != null;
    return Positioned(
      bottom: 0,
      left: left,
      right: right,
      width: 28,
      height: 28,
      child: MouseRegion(
        cursor: cursor,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (_) {
            widget.onSelect();
            setState(() => _isResizing = true);
          },
          onPanUpdate: (details) => widget.onResizeEdge(details.delta, edge),
          onPanEnd: (_) {
            setState(() => _isResizing = false);
            widget.onDragEnd();
          },
          onPanCancel: () {
            setState(() => _isResizing = false);
            widget.onDragEnd();
          },
          child: Container(
            alignment: isRight ? Alignment.bottomRight : Alignment.bottomLeft,
            padding: EdgeInsets.only(
              left: isRight ? 0 : 3,
              right: isRight ? 3 : 0,
              bottom: 3,
            ),
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 160),
              opacity: showHandle ? 0.95 : idleOpacity,
              child: Container(
                decoration: BoxDecoration(
                  color: showHandle
                      ? Colors.black.withOpacity(0.65)
                      : Colors.transparent,
                  borderRadius: BorderRadius.only(
                    topLeft: Radius.circular(isRight ? 6 : 0),
                    topRight: Radius.circular(isRight ? 0 : 6),
                    bottomRight: Radius.circular(isRight ? 10 : 0),
                    bottomLeft: Radius.circular(isRight ? 0 : 10),
                  ),
                ),
                padding: const EdgeInsets.all(2),
                child: Icon(
                  icon,
                  size: 14,
                  color: isDark ? Colors.white70 : Colors.black54,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final imageWidget = _buildImageContent();
    final bool showControls =
        _isHovered || _isDragging || _isResizing || widget.isSelected;

    final borderColor = (_isDragging || _isResizing || widget.isSelected)
        ? const Color(0xFF6366F1).withOpacity(0.85)
        : (_isHovered
            ? (isDark
                ? Colors.white.withOpacity(0.24)
                : Colors.black.withOpacity(0.20))
            : (isDark
                ? Colors.white.withOpacity(0.08)
                : Colors.black.withOpacity(0.07)));

    final cardBg = isDark ? const Color(0xFF16181D) : Colors.white;

    final ar = widget.image.aspectRatio;
    final double displayHeight = (widget.image.height != null && widget.image.height! > 0)
        ? widget.image.height!
        : ((ar != null && ar > 0)
            ? (widget.image.width / ar)
            : (widget.image.width * 0.75));

    return MouseRegion(
      cursor:
          _isDragging ? SystemMouseCursors.grabbing : SystemMouseCursors.grab,
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => widget.onSelect(),
        onTap: () {
          if (widget.isMobile && !widget.isSelected) {
            widget.onSelect();
          } else {
            widget.onShowLightbox(widget.image.url, imageWidget);
          }
        },
        onSecondaryTapDown: (details) =>
            _showContextMenu(details, widget.image.url, imageWidget),
        onPanStart: (details) {
          widget.onSelect();
          setState(() => _isDragging = true);
        },
        onPanUpdate: (details) {
          widget.onDragUpdate(details.delta);
        },
        onPanEnd: (details) {
          setState(() => _isDragging = false);
          widget.onDragEnd();
        },
        onPanCancel: () {
          setState(() => _isDragging = false);
          widget.onDragEnd();
        },
        child: AnimatedContainer(
          duration: (_isDragging || _isResizing)
              ? Duration.zero
              : const Duration(milliseconds: 140),
          curve: Curves.easeOutCubic,
          width: widget.image.width,
          height: displayHeight,
          decoration: BoxDecoration(
            color: cardBg,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: borderColor, width: 1.0),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(_isDragging
                    ? 0.50
                    : (_isHovered || widget.isSelected
                        ? (isDark ? 0.35 : 0.10)
                        : (isDark ? 0.25 : 0.05))),
                blurRadius: _isDragging ? 24 : (_isHovered ? 16 : 8),
                offset: Offset(0, _isDragging ? 8 : 4),
              ),
            ],
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Image content edge-to-edge with no empty space
              ClipRRect(
                borderRadius: BorderRadius.circular(11),
                child: SizedBox(
                  width: widget.image.width,
                  height: displayHeight,
                  child: imageWidget,
                ),
              ),

              if (widget.image.uploadFailed)
                Positioned(
                  top: 6,
                  left: 6,
                  child: GestureDetector(
                    onTap: widget.onRetryUpload,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.red.shade700.withOpacity(0.92),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.refresh_rounded,
                              size: 13, color: Colors.white),
                          SizedBox(width: 4),
                          Text(
                            'Повторить загрузку',
                            style: TextStyle(
                                color: Colors.white,
                                fontSize: 11,
                                fontWeight: FontWeight.w600),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),

              // Floating Controls Bar on Hover / Drag / Select (never intercepts touches when hidden)
              Positioned(
                top: 6,
                right: 6,
                child: IgnorePointer(
                  ignoring: !showControls,
                  child: AnimatedOpacity(
                    duration: const Duration(milliseconds: 160),
                    opacity: showControls ? 1.0 : 0.0,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 3),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.80),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: Colors.white.withOpacity(0.18),
                          width: 1,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.drag_indicator_rounded,
                            size: 15,
                            color: Colors.white70,
                          ),
                          const SizedBox(width: 6),
                          Tooltip(
                            message: 'Уменьшить (-15%)',
                            child: InkWell(
                              onTap: () => widget.onScaleStep(1 / 1.15),
                              borderRadius: BorderRadius.circular(4),
                              child: const Padding(
                                padding: EdgeInsets.all(2),
                                child: Icon(
                                  Icons.remove_rounded,
                                  size: 14,
                                  color: Colors.white70,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 4),
                          Tooltip(
                            message: 'Увеличить (+15%)',
                            child: InkWell(
                              onTap: () => widget.onScaleStep(1.15),
                              borderRadius: BorderRadius.circular(4),
                              child: const Padding(
                                padding: EdgeInsets.all(2),
                                child: Icon(
                                  Icons.add_rounded,
                                  size: 14,
                                  color: Colors.white70,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 4),
                          Tooltip(
                            message: 'Оригинальный размер (100%)',
                            child: InkWell(
                              onTap: () => widget.onResetScale(),
                              borderRadius: BorderRadius.circular(4),
                              child: const Padding(
                                padding: EdgeInsets.all(2),
                                child: Icon(
                                  Icons.aspect_ratio_rounded,
                                  size: 13,
                                  color: Colors.white70,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 5),
                          Container(width: 1, height: 12, color: Colors.white24),
                          const SizedBox(width: 5),
                          Tooltip(
                            message: 'На весь экран',
                            child: InkWell(
                              onTap: () => widget.onShowLightbox(
                                  widget.image.url, imageWidget),
                              borderRadius: BorderRadius.circular(4),
                              child: const Padding(
                                padding: EdgeInsets.all(2),
                                child: Icon(
                                  Icons.fullscreen_rounded,
                                  size: 15,
                                  color: Colors.white70,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 4),
                          Tooltip(
                            message: 'Удалить',
                            child: InkWell(
                              onTap: () => widget.onDelete(),
                              borderRadius: BorderRadius.circular(4),
                              child: const Padding(
                                padding: EdgeInsets.all(2),
                                child: Icon(
                                  Icons.close_rounded,
                                  size: 15,
                                  color: Colors.white70,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),

              // Edge & Corner Resize Handles
              _buildEdgeHandle(
                edge: 'right',
                cursor: SystemMouseCursors.resizeLeftRight,
                isDark: isDark,
                visible: _isHovered || _isResizing || widget.isSelected,
                top: 20,
                bottom: 28,
                right: 0,
                width: 14,
              ),
              _buildEdgeHandle(
                edge: 'bottom',
                cursor: SystemMouseCursors.resizeUpDown,
                isDark: isDark,
                visible: _isHovered || _isResizing || widget.isSelected,
                left: 28,
                right: 28,
                bottom: 0,
                height: 14,
              ),
              _buildEdgeHandle(
                edge: 'left',
                cursor: SystemMouseCursors.resizeLeftRight,
                isDark: isDark,
                visible: _isHovered || _isResizing || widget.isSelected,
                top: 20,
                bottom: 28,
                left: 0,
                width: 14,
              ),
              _buildCornerHandle(
                edge: 'bottom_right',
                cursor: SystemMouseCursors.resizeDownRight,
                icon: Icons.south_east_rounded,
                isDark: isDark,
                showHandle: _isHovered || _isResizing || widget.isSelected,
                idleOpacity: 0.35,
                right: 0,
              ),
              _buildCornerHandle(
                edge: 'bottom_left',
                cursor: SystemMouseCursors.resizeDownLeft,
                icon: Icons.south_west_rounded,
                isDark: isDark,
                showHandle: _isHovered || _isResizing || widget.isSelected,
                left: 0,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class AppImageEmbedBuilder extends EmbedBuilder {
  final Function(String source)? onDeleteImage;
  final Function(String source)? onCopyImage;
  final bool isMobile;

  AppImageEmbedBuilder({
    this.onDeleteImage,
    this.onCopyImage,
    this.isMobile = false,
  });

  @override
  String get key => BlockEmbed.imageType;

  @override
  Widget build(
    BuildContext context,
    EmbedContext embedContext,
  ) {
    return _AppImageWidget(
      embedContext: embedContext,
      onDeleteImage: onDeleteImage,
      onCopyImage: onCopyImage,
      isMobile: isMobile,
    );
  }
}

class _AppImageWidget extends StatefulWidget {
  final EmbedContext embedContext;
  final Function(String source)? onDeleteImage;
  final Function(String source)? onCopyImage;
  final bool isMobile;

  const _AppImageWidget({
    required this.embedContext,
    this.onDeleteImage,
    this.onCopyImage,
    this.isMobile = false,
  });

  @override
  State<_AppImageWidget> createState() => _AppImageWidgetState();
}

class _AppImageWidgetState extends State<_AppImageWidget> {
  Widget _buildImageContent() {
    final imageSource = widget.embedContext.node.value.data.toString();
    final cachedBytes = AppImageCache.get(imageSource);
    if (cachedBytes != null) {
      return Image.memory(cachedBytes, fit: BoxFit.contain);
    } else if (imageSource.startsWith('data:image/') ||
        imageSource.contains('base64')) {
      final base64String =
          imageSource.contains(',') ? imageSource.split(',')[1] : imageSource;
      try {
        final decoded = base64Decode(base64String);
        AppImageCache.put(imageSource, decoded);
        return Image.memory(decoded, fit: BoxFit.contain);
      } catch (_) {
        return const Icon(Icons.broken_image_rounded, size: 40);
      }
    } else {
      return Image.network(
        imageSource,
        fit: BoxFit.contain,
        loadingBuilder: (context, child, loadingProgress) {
          if (loadingProgress == null) return child;
          return Container(
            height: 180,
            alignment: Alignment.center,
            child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
          );
        },
        errorBuilder: (ctx, err, stack) =>
            const Icon(Icons.broken_image_rounded, size: 40),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final imageSource = widget.embedContext.node.value.data.toString();
    final imageWidget = _buildImageContent();

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Center(
        child: GestureDetector(
          onTap: () => ImageActions.showLightbox(context, imageWidget, imageSource),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 520),
              child: imageWidget,
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
  final bool isMobile;
  final Function(String id, String title, String plainText, String content)?
      onNoteUpdated;
  final VoidCallback? onDeleteRequested;
  final VoidCallback? onBroadcastSync;

  const NoteEditorView({
    super.key,
    required this.note,
    required this.vaultId,
    this.isMobile = false,
    this.onNoteUpdated,
    this.onDeleteRequested,
    this.onBroadcastSync,
  });

  @override
  State<NoteEditorView> createState() => _NoteEditorViewState();
}

class _NoteEditorViewState extends State<NoteEditorView>
    with WidgetsBindingObserver {
  late TextEditingController _titleController;
  final FocusNode _titleFocusNode = FocusNode();
  late QuillController _quillController;
  final FocusNode _editorFocusNode = FocusNode();
  final ScrollController _editorScrollController = ScrollController();
  final GlobalKey<EditorState> _editorKey = GlobalKey<EditorState>();
  List<CanvasImage> _canvasImages = [];
  String? _selectedImageId;
  StreamSubscription? _docChangeSub;
  Timer? _debounceTimer;

  bool _isInternalDocUpdate = false;
  bool _isApplyingRemoteChange = false;
  bool _isCardHovered = false;

  String _lastSavedTitle = '';
  String _lastSavedContent = '';
  DateTime _lastLocalEditTime = DateTime.fromMillisecondsSinceEpoch(0);
  String? _pendingRemoteTitle;
  String? _pendingRemoteContent;

  final ValueNotifier<bool> _isSavingNotifier = ValueNotifier(false);
  final ValueNotifier<bool> _isSavedNotifier = ValueNotifier(true);

  // Floating selection toolbar state
  bool _showFloatingToolbar = false;
  // Slash menu notifier (prevents rebuilding the entire editor during typing)
  final ValueNotifier<bool> _showSlashMenuNotifier = ValueNotifier(false);

  SupabaseClient? _supabaseOrNull() {
    try {
      return Supabase.instance.client;
    } catch (_) {
      return null;
    }
  }

  void _subscribeToDocChanges() {
    _docChangeSub?.cancel();
    _docChangeSub = _quillController.document.changes.listen((change) {
      if (!_isInternalDocUpdate && !_isApplyingRemoteChange) {
        _onContentChanged();
      }
    });
  }

  void _setQuillDocument(Document doc) {
    _isInternalDocUpdate = true;
    try {
      _docChangeSub?.cancel();
      _quillController.document = doc;
      _subscribeToDocChanges();
    } finally {
      _isInternalDocUpdate = false;
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _titleFocusNode.addListener(_handleFocusChange);
    _editorFocusNode.addListener(_handleFocusChange);
    _titleController = TextEditingController(text: widget.note.title);
    _lastSavedTitle = widget.note.title;
    _lastSavedContent = widget.note.content;

    final controllerConfig = QuillControllerConfig(
      // ignore: experimental_member_use
      clipboardConfig: QuillClipboardConfig(
        onImagePaste: (bytes) async {
          await _insertImageBytes(bytes);
          return null;
        },
      ),
    );

    final parsed = parseNoteContent(widget.note.content);
    _canvasImages = parsed.images;

    _quillController = QuillController(
      document: parsed.document,
      selection: const TextSelection.collapsed(offset: 0),
      config: controllerConfig,
    );

    _titleController.addListener(_onTitleChanged);
    _subscribeToDocChanges();

    _quillController.addListener(_handleSelectionChange);

    WebPasteListener.setHandler((bytes) {
      if (mounted) {
        _insertImageBytes(bytes);
      }
    });
  }

  void _handleSelectionChange() {
    final selection = _quillController.selection;
    final hasSelection = !selection.isCollapsed &&
        selection.start >= 0 &&
        selection.end > selection.start;

    if (hasSelection != _showFloatingToolbar && mounted) {
      setState(() => _showFloatingToolbar = hasSelection);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      if (_debounceTimer?.isActive ?? false) {
        _debounceTimer?.cancel();
        _saveNote();
      }
    }
  }

  void _applyParsedRemoteContent(String remoteContent) {
    final parsed = parseNoteContent(remoteContent);
    _canvasImages = parsed.images;
    final oldSelection = _quillController.selection;
    _setQuillDocument(parsed.document);
    final newLen = _quillController.document.length;
    final safeOffset = oldSelection.baseOffset.clamp(0, max<int>(0, newLen - 1));
    _quillController.updateSelection(
      TextSelection.collapsed(offset: safeOffset),
      ChangeSource.local,
    );
  }

  @override
  void didUpdateWidget(covariant NoteEditorView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.note.id != widget.note.id) {
      if (_debounceTimer?.isActive ?? false) {
        _debounceTimer?.cancel();
        final prevNoteId = oldWidget.note.id;
        final prevPinned = oldWidget.note.isPinned;
        final prevTitle = _titleController.text.trim();
        final prevDelta = _quillController.document.toDelta().toJson();
        final prevPlain = _quillController.document.toPlainText().trim();
        final prevImages = _canvasImages
            .where((e) => !e.url.startsWith('data:image/'))
            .map((e) => e.toJson())
            .toList();
        final prevContent = jsonEncode({
          'delta': prevDelta,
          'images': prevImages,
          if (prevPinned) 'is_pinned': true,
        });
        Future.microtask(() async {
          widget.onNoteUpdated?.call(prevNoteId, prevTitle, prevPlain, prevContent);
          try {
            await _supabaseOrNull()?.from('notes').upsert({
              'id': prevNoteId,
              'vault_id': widget.vaultId,
              'title': prevTitle,
              'content': prevContent,
              'plain_text': prevPlain,
              'updated_at': DateTime.now().toIso8601String(),
            });
          } catch (_) {}
        });
      }

      _isApplyingRemoteChange = true;
      _selectedImageId = null;
      _pendingRemoteTitle = null;
      _pendingRemoteContent = null;
      _titleController.text = widget.note.title;
      _lastSavedTitle = widget.note.title;
      _lastSavedContent = widget.note.content;

      final parsed = parseNoteContent(widget.note.content);
      _canvasImages = parsed.images;
      _setQuillDocument(parsed.document);
      _quillController.updateSelection(
        const TextSelection.collapsed(offset: 0),
        ChangeSource.local,
      );
      _isApplyingRemoteChange = false;
      if (!_isSavedNotifier.value) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _isSavedNotifier.value = true;
        });
      }
    } else {
      final remoteTitle = widget.note.title;
      final remoteContent = widget.note.content;

      final bool titleChanged =
          remoteTitle != _lastSavedTitle && remoteTitle != _titleController.text;
      final bool contentChanged = remoteContent != _lastSavedContent;

      if (titleChanged || contentChanged) {
        final recentLocalEdit =
            DateTime.now().difference(_lastLocalEditTime).inMilliseconds < 1200;
        final hasPendingLocalChanges = recentLocalEdit ||
            _isSavingNotifier.value ||
            (_debounceTimer?.isActive ?? false);

        if (_isInsertingImage || hasPendingLocalChanges) {
          // Defer update until local saving completes
          _pendingRemoteTitle = remoteTitle;
          _pendingRemoteContent = remoteContent;
          return;
        }

        _pendingRemoteTitle = null;
        _pendingRemoteContent = null;
        _lastSavedTitle = remoteTitle;
        _lastSavedContent = remoteContent;
        _isSavedNotifier.value = true;

        _isApplyingRemoteChange = true;
        try {
          if (titleChanged) {
            _titleController.text = remoteTitle;
          }
          if (contentChanged && remoteContent.isNotEmpty) {
            _applyParsedRemoteContent(remoteContent);
          }
        } finally {
          _isApplyingRemoteChange = false;
        }
      }
    }
  }

  void _applyPendingRemoteChange() {
    if (!mounted) return;
    if (_pendingRemoteTitle == null && _pendingRemoteContent == null) return;
    if (_isSavingNotifier.value ||
        (_debounceTimer?.isActive ?? false) ||
        _isInsertingImage) {
      return;
    }

    final remoteTitle = _pendingRemoteTitle;
    final remoteContent = _pendingRemoteContent;
    _pendingRemoteTitle = null;
    _pendingRemoteContent = null;

    if (remoteTitle != null &&
        remoteTitle != _lastSavedTitle &&
        remoteTitle != _titleController.text) {
      _lastSavedTitle = remoteTitle;
      _isApplyingRemoteChange = true;
      try {
        _titleController.text = remoteTitle;
      } finally {
        _isApplyingRemoteChange = false;
      }
    }

    if (remoteContent != null &&
        remoteContent != _lastSavedContent &&
        remoteContent.isNotEmpty) {
      _lastSavedContent = remoteContent;
      _isApplyingRemoteChange = true;
      try {
        _applyParsedRemoteContent(remoteContent);
      } finally {
        _isApplyingRemoteChange = false;
      }
    }
    _isSavedNotifier.value = true;
  }

  void _onTitleChanged() {
    if (_isApplyingRemoteChange) return;
    _scheduleSave();
  }

  void _onContentChanged() {
    if (_isApplyingRemoteChange || _isInternalDocUpdate) return;

    // Trigger '/' slash menu only at the start of a line or after whitespace (never inside URLs)
    final text = _quillController.document.toPlainText();
    final sel = _quillController.selection.baseOffset;
    final isSlashTrigger = sel > 0 &&
        sel <= text.length &&
        text[sel - 1] == '/' &&
        (sel == 1 || text[sel - 2] == '\n' || text[sel - 2] == ' ');

    if (isSlashTrigger) {
      if (!_showSlashMenuNotifier.value) {
        _showSlashMenuNotifier.value = true;
      }
    } else if (_showSlashMenuNotifier.value) {
      _showSlashMenuNotifier.value = false;
    }
    _scheduleSave();
  }

  void _scheduleSave() {
    _lastLocalEditTime = DateTime.now();
    _isSavedNotifier.value = false;
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 500), _saveNote);
  }

  Future<void> _saveNote({bool force = false}) async {
    final title = _titleController.text.trim();
    // Filter out temporary data:image/ entries so text/title always save reliably
    final syncedImages = _canvasImages
        .where((e) => !e.url.startsWith('data:image/'))
        .map((e) => e.toJson())
        .toList();

    final content = jsonEncode({
      'delta': _quillController.document.toDelta().toJson(),
      'images': syncedImages,
      if (widget.note.isPinned) 'is_pinned': true,
    });

    if (!force && title == _lastSavedTitle && content == _lastSavedContent) {
      _isSavedNotifier.value = true;
      return;
    }

    _isSavingNotifier.value = true;

    try {
      final plainText = _quillController.document.toPlainText().trim();
      widget.onNoteUpdated
          ?.call(widget.note.id, title, plainText, content);

      final client = _supabaseOrNull();
      if (client != null) {
        await client.from('notes').upsert({
          'id': widget.note.id,
          'vault_id': widget.vaultId,
          'title': title,
          'content': content,
          'plain_text': plainText,
          'updated_at': DateTime.now().toIso8601String(),
        });
      }
      _lastSavedTitle = title;
      _lastSavedContent = content;
      _isSavedNotifier.value = true;
      widget.onBroadcastSync?.call();
    } catch (e) {
      debugPrint('Save note error: $e');
    } finally {
      if (mounted) _isSavingNotifier.value = false;
      if (_pendingRemoteContent != null || _pendingRemoteTitle != null) {
        _applyPendingRemoteChange();
      }
    }
  }

  void _handleFocusChange() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    WebPasteListener.setHandler(null);
    _debounceTimer?.cancel();
    _docChangeSub?.cancel();
    _saveNote();
    _titleFocusNode.removeListener(_handleFocusChange);
    _editorFocusNode.removeListener(_handleFocusChange);
    _titleFocusNode.dispose();
    _titleController.dispose();
    _editorFocusNode.dispose();
    _editorScrollController.dispose();
    _quillController.dispose();
    _isSavingNotifier.dispose();
    _isSavedNotifier.dispose();
    _showSlashMenuNotifier.dispose();
    super.dispose();
  }

  Future<Uint8List> _optimizeImageBytes(Uint8List bytes) async {
    try {
      // Retain 100% original lossless quality for screenshots and images under 3MB
      if (bytes.length < 3 * 1024 * 1024) {
        return bytes;
      }
      final decoded = img.decodeImage(bytes);
      if (decoded == null) return bytes;

      const maxDim = 2560; // Crisp 2K/Retina sharpness
      img.Image resized = decoded;
      if (decoded.width > maxDim || decoded.height > maxDim) {
        if (decoded.width > decoded.height) {
          resized = img.copyResize(decoded,
              width: maxDim, interpolation: img.Interpolation.linear);
        } else {
          resized = img.copyResize(decoded,
              height: maxDim, interpolation: img.Interpolation.linear);
        }
      }

      final compressed = img.encodeJpg(resized, quality: 92);
      if (compressed.isNotEmpty && compressed.length < bytes.length) {
        return Uint8List.fromList(compressed);
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
  DateTime _lastImageInsertTime = DateTime.fromMillisecondsSinceEpoch(0);

  void _replaceImageSourceInDocument(String oldSource, String newSource) {
    final jsonList = _quillController.document.toDelta().toJson();
    bool found = false;
    for (int i = 0; i < jsonList.length; i++) {
      final insert = jsonList[i]['insert'];
      if (insert is Map && insert['image'] == oldSource) {
        if (newSource.isEmpty) {
          jsonList.removeAt(i);
        } else {
          insert['image'] = newSource;
        }
        found = true;
        break;
      }
    }
    if (found) {
      _lastLocalEditTime = DateTime.now();
      final oldSelection = _quillController.selection;
      _setQuillDocument(Document.fromJson(jsonList));
      final maxOffset = _quillController.document.length - 1;
      final safeOffset =
          oldSelection.baseOffset.clamp(0, maxOffset < 0 ? 0 : maxOffset);
      _quillController.updateSelection(
        TextSelection.collapsed(offset: safeOffset),
        ChangeSource.local,
      );
    }
  }

  Future<void> _uploadAndAttachImage(
      CanvasImage targetImg, Uint8List optimizedBytes) async {
    if (!mounted) return;
    setState(() {
      targetImg.uploadFailed = false;
      targetImg.pendingBytes = optimizedBytes;
    });
    _isSavingNotifier.value = true;

    try {
      final cloudUrl = await _uploadImageToStorage(optimizedBytes);
      if (cloudUrl != null && mounted) {
        AppImageCache.put(cloudUrl, optimizedBytes);
        final idx = _canvasImages.indexWhere((img) => img.id == targetImg.id);
        if (idx != -1) {
          setState(() {
            _canvasImages[idx].url = cloudUrl;
            _canvasImages[idx].uploadFailed = false;
            _canvasImages[idx].pendingBytes = null;
          });
          await _saveNote(force: true);
        }
      } else if (mounted) {
        setState(() {
          targetImg.uploadFailed = true;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text(
                'Не удалось загрузить фото в облако. Нажмите «Повторить» на картинке.'),
            backgroundColor: Colors.red.shade700,
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } catch (e) {
      debugPrint('Image upload error: $e');
      if (mounted) {
        setState(() => targetImg.uploadFailed = true);
      }
    } finally {
      if (mounted) _isSavingNotifier.value = false;
    }
  }

  Future<void> _insertImageBytes(Uint8List bytes) async {
    final now = DateTime.now();
    if (_isInsertingImage ||
        now.difference(_lastImageInsertTime).inMilliseconds < 600) {
      return;
    }
    _isInsertingImage = true;
    _lastImageInsertTime = now;

    try {
      final optimized = await _optimizeImageBytes(bytes);
      final tempBase64 = base64Encode(optimized);
      final isPng = optimized.length > 8 &&
          optimized[0] == 0x89 &&
          optimized[1] == 0x50 &&
          optimized[2] == 0x4E &&
          optimized[3] == 0x47;
      final mime = isPng ? 'image/png' : 'image/jpeg';
      final localDataUrl = 'data:$mime;base64,$tempBase64';

      AppImageCache.put(localDataUrl, optimized);

      // Extract natural dimensions and aspect ratio
      double? naturalWidth;
      double? naturalHeight;
      double? ar;

      try {
        final codec = await instantiateImageCodec(optimized);
        final frame = await codec.getNextFrame();
        final nw = frame.image.width.toDouble();
        final nh = frame.image.height.toDouble();
        if (nw > 0 && nh > 0) {
          naturalWidth = nw;
          naturalHeight = nh;
          ar = nw / nh;
        }
      } catch (_) {
        try {
          final decoded = img.decodeImage(optimized);
          if (decoded != null && decoded.width > 0 && decoded.height > 0) {
            final nw = decoded.width.toDouble();
            final nh = decoded.height.toDouble();
            naturalWidth = nw;
            naturalHeight = nh;
            ar = nw / nh;
          }
        } catch (_) {}
      }

      double initWidth;
      if (naturalWidth != null && naturalWidth > 0) {
        if (naturalWidth < 340.0) {
          // Narrow screenshot (e.g. 150px wide) - fit exact natural width with zero extra space
          initWidth = max(80.0, naturalWidth);
        } else {
          initWidth = 360.0;
        }
      } else {
        initWidth = 320.0;
      }

      final initHeight = (ar != null && ar > 0) ? (initWidth / ar) : null;

      final imgId = 'img_${DateTime.now().millisecondsSinceEpoch}';
      final currentScroll = _editorScrollController.hasClients
          ? _editorScrollController.offset
          : 0.0;

      final newImage = CanvasImage(
        id: imgId,
        url: localDataUrl,
        x: 20.0,
        y: currentScroll + 20.0,
        width: initWidth,
        height: initHeight,
        naturalWidth: naturalWidth,
        naturalHeight: naturalHeight,
        aspectRatio: ar,
        pendingBytes: optimized,
      );

      setState(() {
        _canvasImages.add(newImage);
        _selectedImageId = imgId;
      });

      _debounceTimer?.cancel();
      _lastLocalEditTime = DateTime.now();
      _isSavedNotifier.value = false;

      await _uploadAndAttachImage(newImage, optimized);
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

  void _applyFormat(Attribute attribute) {
    _quillController.formatSelection(attribute);
  }

  void _applySlashCommand(Attribute? attr, {bool isImage = false}) {
    final sel = _quillController.selection.baseOffset;
    if (sel > 0) {
      _quillController.replaceText(sel - 1, 1, '', null);
      _quillController.updateSelection(
        TextSelection.collapsed(offset: sel - 1),
        ChangeSource.local,
      );
    }
    _showSlashMenuNotifier.value = false;

    if (isImage) {
      _pickImage();
    } else if (attr != null) {
      _quillController.formatSelection(attr);
    }
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
            Icon(Icons.check_circle_rounded, color: Colors.white, size: 16),
            SizedBox(width: 8),
            Text('Текст заметки скопирован'),
          ],
        ),
        backgroundColor: const Color(0xFF10B981),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final bool isEditorActive =
        _titleFocusNode.hasFocus || _editorFocusNode.hasFocus;

    final sheetBorderColor = isEditorActive
        ? (isDark
            ? Colors.white.withOpacity(0.18)
            : Colors.black.withOpacity(0.18))
        : (_isCardHovered
            ? (isDark
                ? Colors.white.withOpacity(0.12)
                : Colors.black.withOpacity(0.11))
            : (isDark
                ? Colors.white.withOpacity(0.08)
                : Colors.black.withOpacity(0.07)));

    final Widget editorBody = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: TextField(
                controller: _titleController,
                focusNode: _titleFocusNode,
                style: TextStyle(
                  fontSize: widget.isMobile ? 24 : 26,
                  fontWeight: FontWeight.w700,
                  height: 1.25,
                  color: theme.colorScheme.onSurface,
                ),
                maxLines: null,
                decoration: InputDecoration(
                  hintText: 'Заголовок заметки',
                  hintStyle: TextStyle(
                    fontSize: widget.isMobile ? 24 : 26,
                    fontWeight: FontWeight.w700,
                    height: 1.25,
                    color: theme.colorScheme.onSurfaceVariant
                        .withOpacity(0.4),
                  ),
                  border: InputBorder.none,
                  isDense: true,
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ),
            const SizedBox(width: 12),
            _buildStatusDot(),
          ],
        ),

        // Тонкий деликатный разделитель под заголовком
        Container(
          height: 1,
          margin: EdgeInsets.only(
            top: widget.isMobile ? 14 : 18,
            bottom: widget.isMobile ? 18 : 22,
          ),
          color: isDark
              ? Colors.white.withOpacity(0.07)
              : Colors.black.withOpacity(0.06),
        ),
        LayoutBuilder(
          builder: (context, constraints) {
            final availableWidth = constraints.maxWidth;
            double maxImageBottom = 300.0;
            for (final img in _canvasImages) {
              final b = img.y + (img.height ?? (img.width * 0.75));
              if (b > maxImageBottom) maxImageBottom = b;
            }

            return Stack(
              clipBehavior: Clip.none,
              children: [
                Container(
                  constraints: BoxConstraints(
                    minHeight: max(400.0, maxImageBottom + 120.0),
                  ),
                  child: QuillEditor(
                    controller: _quillController,
                    focusNode: _editorFocusNode,
                    scrollController: _editorScrollController,
                    config: QuillEditorConfig(
                      editorKey: _editorKey,
                      scrollable: false,
                      autoFocus: false,
                      expands: false,
                      padding: EdgeInsets.zero,
                      showCursor: true,
                      detectWordBoundary: false,
                      embedBuilders: [
                        AppImageEmbedBuilder(
                          isMobile: widget.isMobile,
                          onDeleteImage: (src) {
                            _replaceImageSourceInDocument(src, '');
                            _saveNote(force: true);
                          },
                        ),
                      ],
                      customStyles: DefaultStyles(
                        paragraph: DefaultTextBlockStyle(
                          TextStyle(
                            fontSize: 16,
                            height: 1.7,
                            color: theme.colorScheme.onSurface,
                          ),
                          const HorizontalSpacing(0, 0),
                          const VerticalSpacing(0, 4),
                          const VerticalSpacing(0, 0),
                          null,
                        ),
                        h1: DefaultTextBlockStyle(
                          TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.w700,
                            height: 1.4,
                            color: theme.colorScheme.onSurface,
                          ),
                          const HorizontalSpacing(0, 0),
                          const VerticalSpacing(16, 6),
                          const VerticalSpacing(0, 0),
                          null,
                        ),
                        h2: DefaultTextBlockStyle(
                          TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                            height: 1.4,
                            color: theme.colorScheme.onSurface,
                          ),
                          const HorizontalSpacing(0, 0),
                          const VerticalSpacing(14, 4),
                          const VerticalSpacing(0, 0),
                          null,
                        ),
                        code: DefaultTextBlockStyle(
                          TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 13,
                            color: isDark
                                ? const Color(0xFFE2E8F0)
                                : const Color(0xFF1E293B),
                          ),
                          const HorizontalSpacing(0, 0),
                          const VerticalSpacing(8, 8),
                          const VerticalSpacing(0, 0),
                          BoxDecoration(
                            color: isDark
                                ? const Color(0xFF16181D)
                                : const Color(0xFFF1F3F5),
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                        quote: DefaultTextBlockStyle(
                          TextStyle(
                            fontSize: 15,
                            fontStyle: FontStyle.italic,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                          const HorizontalSpacing(0, 0),
                          const VerticalSpacing(6, 6),
                          const VerticalSpacing(0, 0),
                          BoxDecoration(
                            border: Border(
                              left: BorderSide(
                                color: theme.colorScheme.primary,
                                width: 3,
                              ),
                            ),
                          ),
                        ),
                        placeHolder: DefaultTextBlockStyle(
                          TextStyle(
                            fontSize: 16,
                            height: 1.7,
                            color: theme.colorScheme.onSurfaceVariant
                                .withAlpha(120),
                          ),
                          const HorizontalSpacing(0, 0),
                          const VerticalSpacing(0, 0),
                          const VerticalSpacing(0, 0),
                          null,
                        ),
                      ),
                      placeholder:
                          'Начните писать или нажмите / для выбора команд...',
                    ),
                  ),
                ),
                for (int i = 0; i < _canvasImages.length; i++)
                  _buildPositionedCanvasImage(_canvasImages[i], availableWidth),
              ],
            );
          },
        ),
        const SizedBox(height: 120),
                  ],
                );

    final Widget editorLayout = widget.isMobile
        ? Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            child: editorBody,
          )
        : Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 780),
              child: MouseRegion(
                onEnter: (_) => setState(() => _isCardHovered = true),
                onExit: (_) => setState(() => _isCardHovered = false),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOutCubic,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 40, vertical: 32),
                  decoration: BoxDecoration(
                    color: isDark ? const Color(0xFF141518) : Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: sheetBorderColor, width: 1.0),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(isDark ? 0.40 : 0.05),
                        blurRadius: isEditorActive ? 28 : 16,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: editorBody,
                ),
              ),
            ),
          );

    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (_showSlashMenuNotifier.value) {
            _showSlashMenuNotifier.value = false;
          } else if (_selectedImageId != null) {
            setState(() => _selectedImageId = null);
          }
        },
      },
      child: Stack(
        children: [
          GestureDetector(
            onTap: () {
              if (_selectedImageId != null) {
                setState(() => _selectedImageId = null);
              }
              if (_showSlashMenuNotifier.value) {
                _showSlashMenuNotifier.value = false;
              }
              if (!_editorFocusNode.hasFocus) {
                _editorFocusNode.requestFocus();
              }
            },
            behavior: HitTestBehavior.translucent,
            child: SingleChildScrollView(
              controller: _editorScrollController,
              physics: const AlwaysScrollableScrollPhysics(
                  parent: BouncingScrollPhysics()),
              padding: EdgeInsets.symmetric(
                horizontal: widget.isMobile ? 0 : 28,
                vertical: widget.isMobile ? 8 : 24,
              ),
              child: editorLayout,
            ),
          ),
          if (_showFloatingToolbar && !widget.isMobile)
            Positioned(
              top: 24,
              left: 0,
              right: 0,
              child: Center(
                child: _buildFloatingSelectionCapsule(),
              ),
            ),
          ValueListenableBuilder<bool>(
            valueListenable: _showSlashMenuNotifier,
            builder: (context, showSlash, _) {
              if (!showSlash) return const SizedBox.shrink();
              return Positioned(
                top: 80,
                left: MediaQuery.sizeOf(context).width > 720
                    ? (MediaQuery.sizeOf(context).width - 270) / 2 - 130
                    : 30,
                child: _buildSlashCommandMenu(),
              );
            },
          ),
          if (widget.isMobile)
            Positioned(
              bottom: MediaQuery.viewInsetsOf(context).bottom + 8,
              left: 16,
              right: 16,
              child: _buildMobileToolbarStrip(),
            ),
        ],
      ),
    );
  }

  Widget _buildPositionedCanvasImage(CanvasImage img, double availableWidth) {
    final maxX = max(0.0, availableWidth - img.width);
    final clampedX = img.x.clamp(0.0, maxX);
    final clampedY = max(0.0, img.y);

    return Positioned(
      left: clampedX,
      top: clampedY,
      child: _CanvasImageWidget(
        key: ValueKey(img.id),
        image: img,
        maxWidth: availableWidth,
        isMobile: widget.isMobile,
        isSelected: _selectedImageId == img.id,
        onSelect: () {
          setState(() {
            _selectedImageId = img.id;
            _canvasImages.remove(img);
            _canvasImages.add(img);
          });
        },
        onDragUpdate: (delta) {
          setState(() {
            final currentMaxX = max(0.0, availableWidth - img.width);
            img.x = (img.x + delta.dx).clamp(0.0, currentMaxX);
            img.y = max(0.0, img.y + delta.dy);
          });
          _handleAutoScrollOnCanvasDrag(img.y);
        },
        onDragEnd: () {
          _lastLocalEditTime = DateTime.now();
          _isSavedNotifier.value = false;
          _isSavingNotifier.value = true;
          _saveNote(force: true);
          widget.onBroadcastSync?.call();
        },
        onResizeEdge: (delta, edge) {
          setState(() {
            final res = computeEdgeResize(
              currentX: img.x,
              currentWidth: img.width,
              currentHeight: img.height,
              aspectRatio: img.aspectRatio,
              delta: delta,
              edge: edge,
              availableWidth: availableWidth,
            );
            img.x = res.x;
            img.width = res.width;
            img.height = res.height;
          });
        },
        onScaleStep: (factor) {
          setState(() {
            final ar = img.aspectRatio ??
                ((img.height != null && img.height! > 0)
                    ? (img.width / img.height!)
                    : 1.0);
            final minW = min(80.0, max(1.0, availableWidth));
            final maxW = max(minW, availableWidth);

            final newWidth = (img.width * factor).clamp(minW, maxW);
            img.width = newWidth;
            img.height = newWidth / ar;
            img.x = img.x.clamp(0.0, max(0.0, availableWidth - img.width));
          });
          _lastLocalEditTime = DateTime.now();
          _saveNote(force: true);
          widget.onBroadcastSync?.call();
        },
        onResetScale: () {
          setState(() {
            final ar = img.aspectRatio ??
                ((img.height != null && img.height! > 0)
                    ? (img.width / img.height!)
                    : 1.0);
            final minW = min(80.0, max(1.0, availableWidth));
            final maxW = max(minW, availableWidth);
            final targetW = (img.naturalWidth != null && img.naturalWidth! > 0)
                ? img.naturalWidth!.clamp(minW, maxW)
                : min(320.0, maxW);
            img.width = targetW;
            img.height = targetW / ar;
            img.x = img.x.clamp(0.0, max(0.0, availableWidth - img.width));
          });
          _lastLocalEditTime = DateTime.now();
          _saveNote(force: true);
          widget.onBroadcastSync?.call();
        },
        onDelete: () {
          final removedUrl = img.url;
          setState(() {
            if (_selectedImageId == img.id) _selectedImageId = null;
            _canvasImages.remove(img);
          });
          AppImageCache.remove(removedUrl);
          final storagePath = extractNoteImageStoragePath(removedUrl);
          if (storagePath != null) {
            _supabaseOrNull()
                ?.storage
                .from('note-images')
                .remove([storagePath])
                .catchError((_) => <FileObject>[]);
          }
          _lastLocalEditTime = DateTime.now();
          _saveNote(force: true);
          widget.onBroadcastSync?.call();
        },
        onCopy: (src) {
          ImageActions.copyImage(context, src);
        },
        onShowLightbox: (src, imageWidget) {
          ImageActions.showLightbox(context, imageWidget, src);
        },
        onDimensionsResolved: () {
          _saveNote(force: true);
          widget.onBroadcastSync?.call();
        },
        onRetryUpload: () {
          final bytes = img.pendingBytes ?? AppImageCache.get(img.url);
          if (bytes != null) {
            _uploadAndAttachImage(img, bytes);
          }
        },
      ),
    );
  }

  void _handleAutoScrollOnCanvasDrag(double imageY) {
    if (!_editorScrollController.hasClients) return;
    final currentScroll = _editorScrollController.offset;
    final viewportHeight = _editorScrollController.position.viewportDimension;
    const threshold = 80.0;
    const step = 16.0;

    final screenY = imageY - currentScroll;
    if (screenY < threshold && currentScroll > 0) {
      final target = (currentScroll - step)
          .clamp(0.0, _editorScrollController.position.maxScrollExtent);
      _editorScrollController.jumpTo(target);
    } else if (screenY > viewportHeight - threshold) {
      final target = (currentScroll + step)
          .clamp(0.0, _editorScrollController.position.maxScrollExtent);
      _editorScrollController.jumpTo(target);
    }
  }

  Widget _buildStatusDot() {
    return ValueListenableBuilder<bool>(
      valueListenable: _isSavedNotifier,
      builder: (context, isSaved, _) {
        return ValueListenableBuilder<bool>(
          valueListenable: _isSavingNotifier,
          builder: (context, isSaving, _) {
            final isSynced = isSaved && !isSaving;
            final dotColor =
                isSynced ? const Color(0xFF10B981) : const Color(0xFFF59E0B);

            return Tooltip(
              message: isSynced ? 'Сохранено' : 'Синхронизация...',
              waitDuration: const Duration(milliseconds: 200),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 250),
                    curve: Curves.easeOutCubic,
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: dotColor,
                      boxShadow: [
                        BoxShadow(
                          color: dotColor.withAlpha(isSynced ? 80 : 160),
                          blurRadius: 6,
                          spreadRadius: 1,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  PopupMenuButton<String>(
                    icon: Icon(
                      Icons.more_horiz_rounded,
                      size: 18,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                    color: Theme.of(context).brightness == Brightness.dark
                        ? const Color(0xFF1E2026)
                        : Colors.white,
                    itemBuilder: (ctx) => [
                      const PopupMenuItem(
                        value: 'copy',
                        height: 36,
                        child: Row(
                          children: [
                            Icon(Icons.copy_rounded, size: 16),
                            SizedBox(width: 8),
                            Text('Скопировать весь текст',
                                style: TextStyle(fontSize: 13)),
                          ],
                        ),
                      ),
                      const PopupMenuItem(
                        value: 'image',
                        height: 36,
                        child: Row(
                          children: [
                            Icon(Icons.image_outlined, size: 16),
                            SizedBox(width: 8),
                            Text('Вставить фото',
                                style: TextStyle(fontSize: 13)),
                          ],
                        ),
                      ),
                      const PopupMenuDivider(height: 1),
                      PopupMenuItem(
                        value: 'delete',
                        height: 36,
                        child: Row(
                          children: [
                            Icon(Icons.delete_outline_rounded,
                                size: 16, color: Colors.red.shade400),
                            const SizedBox(width: 8),
                            Text(
                              'Удалить заметку',
                              style: TextStyle(
                                  fontSize: 13, color: Colors.red.shade400),
                            ),
                          ],
                        ),
                      ),
                    ],
                    onSelected: (val) {
                      if (val == 'copy') _copyNoteContent();
                      if (val == 'image') _pickImage();
                      if (val == 'delete') widget.onDeleteRequested?.call();
                    },
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildFloatingSelectionCapsule() {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          decoration: BoxDecoration(
            color: isDark
                ? Colors.black.withAlpha(200)
                : Colors.white.withAlpha(220),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: isDark
                  ? Colors.white.withAlpha(30)
                  : Colors.black.withAlpha(20),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withAlpha(isDark ? 80 : 25),
                blurRadius: 20,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _toolbarBtn(
                label: 'B',
                style: const TextStyle(fontWeight: FontWeight.w800),
                onTap: () => _applyFormat(Attribute.bold),
              ),
              _toolbarBtn(
                label: 'I',
                style: const TextStyle(fontStyle: FontStyle.italic),
                onTap: () => _applyFormat(Attribute.italic),
              ),
              _toolbarBtn(
                label: 'S',
                style: const TextStyle(decoration: TextDecoration.lineThrough),
                onTap: () => _applyFormat(Attribute.strikeThrough),
              ),
              _divider(),
              _toolbarBtn(
                label: 'H1',
                style: const TextStyle(fontWeight: FontWeight.w700),
                onTap: () => _applyFormat(Attribute.h1),
              ),
              _toolbarBtn(
                label: 'H2',
                style: const TextStyle(fontWeight: FontWeight.w700),
                onTap: () => _applyFormat(Attribute.h2),
              ),
              _divider(),
              _toolbarBtn(
                icon: Icons.format_list_bulleted_rounded,
                onTap: () => _applyFormat(Attribute.ul),
              ),
              _toolbarBtn(
                icon: Icons.check_box_outlined,
                onTap: () => _applyFormat(Attribute.unchecked),
              ),
              _toolbarBtn(
                icon: Icons.code_rounded,
                onTap: () => _applyFormat(Attribute.codeBlock),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSlashCommandMenu() {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Material(
      color: Colors.transparent,
      child: Container(
        width: 260,
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF1A1C22) : Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isDark
                ? Colors.white.withAlpha(25)
                : Colors.black.withAlpha(15),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withAlpha(isDark ? 90 : 25),
              blurRadius: 24,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _slashItem(
                  icon: Icons.title_rounded,
                  title: 'Заголовок H1',
                  onTap: () => _applySlashCommand(Attribute.h1)),
              _slashItem(
                  icon: Icons.format_size_rounded,
                  title: 'Подзаголовок H2',
                  onTap: () => _applySlashCommand(Attribute.h2)),
              _slashItem(
                  icon: Icons.check_box_outlined,
                  title: 'Список задач',
                  onTap: () => _applySlashCommand(Attribute.unchecked)),
              _slashItem(
                  icon: Icons.format_list_bulleted_rounded,
                  title: 'Маркированный список',
                  onTap: () => _applySlashCommand(Attribute.ul)),
              _slashItem(
                  icon: Icons.code_rounded,
                  title: 'Блок кода',
                  onTap: () => _applySlashCommand(Attribute.codeBlock)),
              _slashItem(
                  icon: Icons.format_quote_rounded,
                  title: 'Цитата',
                  onTap: () => _applySlashCommand(Attribute.blockQuote)),
              _slashItem(
                  icon: Icons.image_outlined,
                  title: 'Вставить изображение',
                  onTap: () => _applySlashCommand(null, isImage: true)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _slashItem({
    required IconData icon,
    required String title,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            Icon(icon, size: 16, color: const Color(0xFF6366F1)),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMobileToolbarStrip() {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Center(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: isDark
                  ? Colors.black.withAlpha(190)
                  : Colors.white.withAlpha(220),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: isDark
                    ? Colors.white.withAlpha(25)
                    : Colors.black.withAlpha(15),
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withAlpha(isDark ? 80 : 25),
                  blurRadius: 16,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.image_outlined, size: 20),
                  onPressed: _pickImage,
                  splashRadius: 18,
                ),
                IconButton(
                  icon: const Icon(Icons.check_box_outlined, size: 20),
                  onPressed: () => _applyFormat(Attribute.unchecked),
                  splashRadius: 18,
                ),
                IconButton(
                  icon: const Icon(Icons.title_rounded, size: 20),
                  onPressed: () => _applyFormat(Attribute.h1),
                  splashRadius: 18,
                ),
                IconButton(
                  icon: const Icon(Icons.format_bold_rounded, size: 20),
                  onPressed: () => _applyFormat(Attribute.bold),
                  splashRadius: 18,
                ),
                IconButton(
                  icon: const Icon(Icons.keyboard_hide_rounded, size: 20),
                  onPressed: () => FocusScope.of(context).unfocus(),
                  splashRadius: 18,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _toolbarBtn({
    String? label,
    IconData? icon,
    TextStyle? style,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(context);
    return BouncingPressable(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: icon != null
            ? Icon(icon, size: 16, color: theme.colorScheme.onSurface)
            : Text(
                label ?? '',
                style: (style ?? const TextStyle()).copyWith(
                  fontSize: 13,
                  color: theme.colorScheme.onSurface,
                ),
              ),
      ),
    );
  }

  Widget _divider() {
    return Container(
      width: 1,
      height: 16,
      margin: const EdgeInsets.symmetric(horizontal: 4),
      color: Theme.of(context).dividerColor.withAlpha(60),
    );
  }
}

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:ui';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:image/image.dart' as img;
import 'package:pasteboard/pasteboard.dart';
import 'package:qr_flutter/qr_flutter.dart';
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

  final ValueNotifier<List<Note>> _notesNotifier =
      ValueNotifier<List<Note>>([]);
  List<Note> _notes = [];
  bool _isLoading = true;
  String _searchQuery = '';
  Note? _selectedNote;
  RealtimeChannel? _realtimeChannel;
  Timer? _periodicSyncTimer;
  Timer? _incomingSyncDebounce;

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
    _periodicSyncTimer = Timer.periodic(const Duration(seconds: 4), (_) {
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
              cloudNotes[i].isPinned != _notes[i].isPinned) {
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
            final remoteNote = match.first;
            if (remoteNote.title != _selectedNote!.title ||
                remoteNote.content != _selectedNote!.content ||
                remoteNote.isPinned != _selectedNote!.isPinned) {
              setState(() {
                _selectedNote = remoteNote;
              });
            }
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
    _incomingSyncDebounce?.cancel();
    WebPasteListener.setNewNoteHandler(null);
    _searchController.dispose();
    _searchFocusNode.dispose();
    _notesNotifier.dispose();
    _realtimeChannel?.unsubscribe();
    super.dispose();
  }

  Future<void> _fetchNotes() async {
    try {
      final response = await Supabase.instance.client
          .from('notes')
          .select()
          .eq('vault_id', widget.vaultId)
          .order('updated_at', ascending: false);

      final list =
          (response as List).map((e) => Note.fromMap(e as Map)).toList();

      if (mounted) {
        setState(() {
          _notes = list;
          _notesNotifier.value = List.of(_notes);
          _isLoading = false;
          if (_selectedNote == null && _notes.isNotEmpty) {
            _selectedNote = _notes.first;
          }
        });
      }
    } catch (e) {
      debugPrint('Error fetching notes: $e');
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  void _setupRealtime() {
    _realtimeChannel?.unsubscribe();
    _realtimeChannel = Supabase.instance.client.channel('public:notes');

    _realtimeChannel!
        .onBroadcast(
          event: 'sync',
          callback: (payload) {
            final vault = payload['vault'];
            if (vault == widget.vaultId && mounted) {
              _incomingSyncDebounce?.cancel();
              _incomingSyncDebounce =
                  Timer(const Duration(milliseconds: 300), () {
                _syncFromCloudSilently();
              });
            }
          },
        )
        .subscribe();
  }

  Future<void> _createNewNote() async {
    final newId = _generateUuidV4();
    final newNote = Note(
      id: newId,
      vaultId: widget.vaultId,
      title: '',
      content: jsonEncode([
        {'insert': '\n'}
      ]),
      plainText: '',
      updatedAt: DateTime.now(),
      isPinned: false,
    );

    setState(() {
      _notes.insert(0, newNote);
      _notesNotifier.value = List.of(_notes);
      _selectedNote = newNote;
    });

    try {
      await Supabase.instance.client.from('notes').insert(newNote.toMap());
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
      if (_selectedNote?.id == id) {
        _selectedNote = _notes.isNotEmpty ? _notes.first : null;
      }
    });

    try {
      await Supabase.instance.client.from('notes').delete().eq('id', id);
      _broadcastSync();
    } catch (e) {
      debugPrint('Error deleting note: $e');
      if (mounted) {
        setState(() {
          _notes.insert(noteIndex, removedNote);
          _notesNotifier.value = List.of(_notes);
        });
      }
    }
  }

  Future<void> _togglePinNote(Note note) async {
    final newPinned = !note.isPinned;
    final index = _notes.indexWhere((n) => n.id == note.id);
    if (index == -1) return;

    final updated = note.copyWith(isPinned: newPinned);

    // Упаковываем статус is_pinned в JSON контента
    String packagedContent = updated.content;
    try {
      final decoded = jsonDecode(updated.content);
      if (decoded is List) {
        packagedContent = jsonEncode({
          'delta': decoded,
          'is_pinned': newPinned,
        });
      } else if (decoded is Map) {
        final map = Map<String, dynamic>.from(decoded);
        map['is_pinned'] = newPinned;
        packagedContent = jsonEncode(map);
      }
    } catch (_) {}

    final noteToSave = updated.copyWith(content: packagedContent);

    setState(() {
      _notes[index] = noteToSave;
      _notesNotifier.value = List.of(_notes);
      if (_selectedNote?.id == note.id) {
        _selectedNote = noteToSave;
      }
    });

    try {
      await Supabase.instance.client.from('notes').upsert({
        'id': noteToSave.id,
        'vault_id': noteToSave.vaultId,
        'title': noteToSave.title,
        'content': noteToSave.content,
        'plain_text': noteToSave.plainText,
        'updated_at': DateTime.now().toIso8601String(),
      });
      _broadcastSync();
    } catch (e) {
      debugPrint('Error toggling pin: $e');
    }
  }

  void _handleNoteUpdated(
      String id, String title, String plainText, String content) {
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
    }
  }

  List<Note> get _filteredNotes {
    var list = _notes;
    if (_searchQuery.isNotEmpty) {
      final q = _searchQuery.toLowerCase();
      list = list.where((n) {
        return n.title.toLowerCase().contains(q) ||
            n.plainText.toLowerCase().contains(q);
      }).toList();
    }
    // Сортировка: закрепленные всегда сверху, далее по дате
    list.sort((a, b) {
      if (a.isPinned && !b.isPinned) return -1;
      if (!a.isPinned && b.isPinned) return 1;
      return b.updatedAt.compareTo(a.updatedAt);
    });
    return list;
  }

  void _showVaultDialog() {
    final controller = TextEditingController(text: widget.vaultId);
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
                      controller: controller,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 2,
                      ),
                      textCapitalization: TextCapitalization.characters,
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
                      onPressed: () async {
                        final newCode = controller.text.trim().toUpperCase();
                        if (newCode.isNotEmpty && newCode != widget.vaultId) {
                          await VaultService.setVaultId(newCode);
                          if (context.mounted) {
                            Navigator.of(context).pop();
                            widget.onVaultChanged?.call(newCode);
                          }
                        } else {
                          Navigator.of(context).pop();
                        }
                      },
                      child: const Text(
                        'Подключить хранилище',
                        style: TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
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
    final isDesktop = MediaQuery.sizeOf(context).width >= 720;

    if (isDesktop) {
      return Scaffold(
        body: Row(
          children: [
            SizedBox(
              width: 270,
              child: _buildSidebar(),
            ),
            VerticalDivider(
              width: 1,
              thickness: 1,
              color: Theme.of(context).dividerColor.withAlpha(60),
            ),
            Expanded(
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
          ],
        ),
      );
    }

    // Mobile layout
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
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.edit_note_rounded,
            size: 48,
            color: theme.colorScheme.onSurfaceVariant.withAlpha(80),
          ),
          const SizedBox(height: 12),
          Text(
            'Выберите заметку или создайте новую',
            style: TextStyle(
              fontSize: 14,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
          BouncingPressable(
            onTap: _createNewNote,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFF6366F1),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.add_rounded, size: 18, color: Colors.white),
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
    );
  }

  Widget _buildSidebar() {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Container(
      color: theme.colorScheme.surface,
      child: Column(
        children: [
          // Header: Vault badge, theme switcher, new note button
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
                          ? const Color(0xFF1F2228)
                          : const Color(0xFFE5E7EB),
                      borderRadius: BorderRadius.circular(8),
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

          // Borderless search field
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
            child: Container(
              height: 36,
              decoration: BoxDecoration(
                color: isDark
                    ? const Color(0xFF1B1D22)
                    : const Color(0xFFE9EBEF),
                borderRadius: BorderRadius.circular(8),
              ),
              child: TextField(
                controller: _searchController,
                focusNode: _searchFocusNode,
                style: TextStyle(fontSize: 13, color: theme.colorScheme.onSurface),
                onChanged: (val) => setState(() => _searchQuery = val),
                decoration: InputDecoration(
                  prefixIcon: Icon(
                    Icons.search_rounded,
                    size: 16,
                    color: theme.colorScheme.onSurfaceVariant,
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
                    color: theme.colorScheme.onSurfaceVariant.withAlpha(160),
                  ),
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(vertical: 9),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),

          // Notes list
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
              style: TextStyle(fontSize: 14, color: theme.colorScheme.onSurface),
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
                              PageRouteBuilder(
                                transitionDuration:
                                    const Duration(milliseconds: 220),
                                pageBuilder: (ctx, anim, _) =>
                                    NoteMobileEditorScreen(
                                  note: note,
                                  vaultId: widget.vaultId,
                                  notesNotifier: _notesNotifier,
                                  onNoteUpdated: _handleNoteUpdated,
                                  onNoteDeleted: _deleteNote,
                                  onBroadcastSync: _broadcastSync,
                                ),
                                transitionsBuilder:
                                    (ctx, anim, secondaryAnim, child) {
                                  return SlideTransition(
                                    position: Tween<Offset>(
                                      begin: const Offset(1, 0),
                                      end: Offset.zero,
                                    ).animate(CurvedAnimation(
                                      parent: anim,
                                      curve: Curves.easeOutCubic,
                                    )),
                                    child: child,
                                  );
                                },
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

// Bouncing Pressable widget with spring scale 0.97
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

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 3),
        child: BouncingPressable(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            curve: Curves.easeOutCubic,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              color: widget.isSelected
                  ? theme.colorScheme.surfaceContainerHighest
                  : (_isHovered
                      ? (isDark
                          ? const Color(0xFF1B1D22)
                          : const Color(0xFFE9EBEF))
                      : Colors.transparent),
              borderRadius: BorderRadius.circular(10),
              boxShadow: widget.isSelected && !isDark
                  ? [
                      BoxShadow(
                        color: Colors.black.withAlpha(8),
                        blurRadius: 10,
                        offset: const Offset(0, 2),
                      )
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
                          color: theme.colorScheme.onSurfaceVariant.withAlpha(180),
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
          color: theme.cardColor,
          borderRadius: BorderRadius.circular(14),
          boxShadow: !isDark
              ? [
                  BoxShadow(
                    color: Colors.black.withAlpha(6),
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
  final Function(String source)? onDeleteImage;
  final Function(String source)? onCopyImage;

  AppImageEmbedBuilder({this.onDeleteImage, this.onCopyImage});

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
    );
  }
}

class _AppImageWidget extends StatefulWidget {
  final EmbedContext embedContext;
  final Function(String source)? onDeleteImage;
  final Function(String source)? onCopyImage;

  const _AppImageWidget({
    required this.embedContext,
    this.onDeleteImage,
    this.onCopyImage,
  });

  @override
  State<_AppImageWidget> createState() => _AppImageWidgetState();
}

class _AppImageWidgetState extends State<_AppImageWidget> {
  void _deleteImage() {
    final imageSource = widget.embedContext.node.value.data.toString();
    widget.onDeleteImage?.call(imageSource);
  }

  Future<void> _handleCopyImage(String imageSource) async {
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
          final uri = Uri.tryParse(imageSource);
          if (uri != null) {
            final res = await Supabase.instance.client.storage
                .from('note-images')
                .download(uri.pathSegments.sublist(1).join('/'));
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

        if (mounted) {
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
                    onPressed: () => _handleCopyImage(imageSource),
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
      _handleCopyImage(imageSource);
    } else if (selected == 'copy_link') {
      Clipboard.setData(ClipboardData(text: imageSource));
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
      imageWidget = Image.memory(cachedBytes, fit: BoxFit.contain);
    } else if (imageSource.startsWith('data:image/') ||
        imageSource.contains('base64')) {
      final base64String =
          imageSource.contains(',') ? imageSource.split(',')[1] : imageSource;
      try {
        final decoded = base64Decode(base64String);
        AppImageCache.put(imageSource, decoded);
        imageWidget = Image.memory(decoded, fit: BoxFit.contain);
      } catch (_) {
        imageWidget = const Icon(Icons.broken_image_rounded, size: 40);
      }
    } else {
      imageWidget = Image.network(
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

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Center(
        child: GestureDetector(
          onSecondaryTapDown: (details) =>
              _showContextMenu(details, imageSource, imageWidget),
          onLongPressStart: (details) => _showContextMenu(
            TapDownDetails(globalPosition: details.globalPosition),
            imageSource,
            imageWidget,
          ),
          onTap: () => _showLightbox(imageWidget, imageSource),
          child: TweenAnimationBuilder<double>(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            tween: Tween(begin: 0.98, end: 1.0),
            builder: (context, scale, child) {
              return Transform.scale(
                scale: scale,
                child: child,
              );
            },
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 520),
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
  late QuillController _quillController;
  final FocusNode _editorFocusNode = FocusNode();
  StreamSubscription? _docChangeSub;
  Timer? _debounceTimer;
  bool _isInternalDocUpdate = false;

  String _lastSavedTitle = '';
  String _lastSavedContent = '';
  DateTime _lastLocalEditTime = DateTime.fromMillisecondsSinceEpoch(0);

  final ValueNotifier<bool> _isSavingNotifier = ValueNotifier(false);
  final ValueNotifier<bool> _isSavedNotifier = ValueNotifier(true);

  // Floating selection toolbar state
  bool _showFloatingToolbar = false;
  // Slash menu state
  bool _showSlashMenu = false;

  void _subscribeToDocChanges() {
    _docChangeSub?.cancel();
    _docChangeSub = _quillController.document.changes.listen((change) {
      if (!_isInternalDocUpdate) {
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
    _titleController = TextEditingController(text: widget.note.title);
    _lastSavedTitle = widget.note.title;
    _lastSavedContent = widget.note.content;

    final controllerConfig = QuillControllerConfig(
      clipboardConfig: QuillClipboardConfig(
        onImagePaste: (bytes) async {
          await _insertImageBytes(bytes);
          return null;
        },
      ),
    );

    Document doc;
    if (widget.note.content.isNotEmpty) {
      try {
        final decoded = jsonDecode(widget.note.content);
        if (decoded is List) {
          doc = Document.fromJson(decoded);
        } else if (decoded is Map && decoded['delta'] is List) {
          doc = Document.fromJson(decoded['delta']);
        } else {
          doc = Document();
        }
      } catch (_) {
        doc = Document();
      }
    } else {
      doc = Document();
    }

    _quillController = QuillController(
      document: doc,
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

  @override
  void didUpdateWidget(covariant NoteEditorView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.note.id != widget.note.id) {
      _debounceTimer?.cancel();
      _saveNote();

      _titleController.text = widget.note.title;
      _lastSavedTitle = widget.note.title;
      _lastSavedContent = widget.note.content;

      Document newDoc;
      if (widget.note.content.isNotEmpty) {
        try {
          final decoded = jsonDecode(widget.note.content);
          if (decoded is List) {
            newDoc = Document.fromJson(decoded);
          } else if (decoded is Map && decoded['delta'] is List) {
            newDoc = Document.fromJson(decoded['delta']);
          } else {
            newDoc = Document();
          }
        } catch (_) {
          newDoc = Document();
        }
      } else {
        newDoc = Document();
      }
      _setQuillDocument(newDoc);
      _quillController.updateSelection(
        const TextSelection.collapsed(offset: 0),
        ChangeSource.local,
      );
      _isSavedNotifier.value = true;
    } else {
      final remoteTitle = widget.note.title;
      final remoteContent = widget.note.content;

      final bool titleChanged =
          remoteTitle != _lastSavedTitle && remoteTitle != _titleController.text;
      final bool contentChanged = remoteContent != _lastSavedContent;

      if (titleChanged || contentChanged) {
        final hasPendingLocalChanges =
            _isSavingNotifier.value || (_debounceTimer?.isActive ?? false);
        final msSinceLocalEdit =
            DateTime.now().difference(_lastLocalEditTime).inMilliseconds;

        if (_isInsertingImage ||
            hasPendingLocalChanges ||
            msSinceLocalEdit < 2000) {
          return;
        }

        _lastSavedTitle = remoteTitle;
        _lastSavedContent = remoteContent;
        _isSavedNotifier.value = true;

        if (titleChanged) {
          _titleController.text = remoteTitle;
        }
        if (contentChanged && remoteContent.isNotEmpty) {
          try {
            final decoded = jsonDecode(remoteContent);
            Document newDoc;
            if (decoded is List) {
              newDoc = Document.fromJson(decoded);
            } else if (decoded is Map && decoded['delta'] is List) {
              newDoc = Document.fromJson(decoded['delta']);
            } else {
              newDoc = Document();
            }
            final oldSelection = _quillController.selection;
            _setQuillDocument(newDoc);
            final newLen = _quillController.document.length;
            final safeOffset = oldSelection.baseOffset.clamp(0, newLen - 1);
            _quillController.updateSelection(
              TextSelection.collapsed(offset: safeOffset),
              ChangeSource.local,
            );
          } catch (_) {}
        }
      }
    }
  }

  void _onTitleChanged() {
    _scheduleSave();
  }

  void _onContentChanged() {
    // Check if user typed '/' to show slash commands
    final text = _quillController.document.toPlainText();
    final sel = _quillController.selection.baseOffset;
    if (sel > 0 && sel <= text.length && text[sel - 1] == '/') {
      if (!_showSlashMenu) {
        setState(() => _showSlashMenu = true);
      }
    } else if (_showSlashMenu) {
      setState(() => _showSlashMenu = false);
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
    final rawDelta = _quillController.document.toDelta().toJson();

    // Защита от сохранения data:image base64
    final jsonString = jsonEncode(rawDelta);
    if (jsonString.contains('data:image/')) {
      return;
    }

    String contentToSave;
    if (widget.note.isPinned) {
      contentToSave = jsonEncode({
        'delta': rawDelta,
        'is_pinned': true,
      });
    } else {
      contentToSave = jsonString;
    }

    if (!force &&
        title == _lastSavedTitle &&
        contentToSave == _lastSavedContent) {
      _isSavedNotifier.value = true;
      return;
    }

    _isSavingNotifier.value = true;

    try {
      final plainText = _quillController.document.toPlainText().trim();
      widget.onNoteUpdated
          ?.call(widget.note.id, title, plainText, contentToSave);

      await Supabase.instance.client.from('notes').upsert({
        'id': widget.note.id,
        'vault_id': widget.vaultId,
        'title': title,
        'content': contentToSave,
        'plain_text': plainText,
        'updated_at': DateTime.now().toIso8601String(),
      });
      _lastSavedTitle = title;
      _lastSavedContent = contentToSave;
      _isSavedNotifier.value = true;
      widget.onBroadcastSync?.call();
    } catch (e) {
      debugPrint('Save note error: $e');
    } finally {
      if (mounted) _isSavingNotifier.value = false;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    WebPasteListener.setHandler(null);
    _debounceTimer?.cancel();
    _docChangeSub?.cancel();
    _saveNote();
    _titleController.dispose();
    _editorFocusNode.dispose();
    _quillController.dispose();
    _isSavingNotifier.dispose();
    _isSavedNotifier.dispose();
    super.dispose();
  }

  Future<Uint8List> _optimizeImageBytes(Uint8List bytes) async {
    try {
      final decoded = img.decodeImage(bytes);
      if (decoded == null) return bytes;

      const maxDim = 1400;
      img.Image resized = decoded;
      if (decoded.width > maxDim || decoded.height > maxDim) {
        if (decoded.width > decoded.height) {
          resized = img.copyResize(decoded, width: maxDim);
        } else {
          resized = img.copyResize(decoded, height: maxDim);
        }
      }

      final compressed = img.encodeJpg(resized, quality: 82);
      if (compressed.isNotEmpty) {
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
    for (final item in jsonList) {
      final insert = item['insert'];
      if (insert is Map && insert['image'] == oldSource) {
        insert['image'] = newSource;
        found = true;
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

  Future<void> _insertImageBytes(Uint8List bytes) async {
    final now = DateTime.now();
    if (_isInsertingImage ||
        now.difference(_lastImageInsertTime).inMilliseconds < 600) {
      return;
    }
    _isInsertingImage = true;
    _lastImageInsertTime = now;

    try {
      final index = _quillController.selection.baseOffset;
      final length = _quillController.selection.extentOffset - index;
      final safeIndex =
          index < 0 ? _quillController.document.length - 1 : index;
      final safeLength = length < 0 ? 0 : length;

      final optimized = await _optimizeImageBytes(bytes);
      final tempBase64 = base64Encode(optimized);
      final localDataUrl = 'data:image/jpeg;base64,$tempBase64';

      AppImageCache.put(localDataUrl, optimized);

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

      _debounceTimer?.cancel();
      _lastLocalEditTime = DateTime.now();
      _isSavedNotifier.value = false;
      _isSavingNotifier.value = true;

      try {
        final cloudUrl = await _uploadImageToStorage(optimized);
        if (cloudUrl != null && mounted) {
          AppImageCache.put(cloudUrl, optimized);
          _replaceImageSourceInDocument(localDataUrl, cloudUrl);
          await _saveNote(force: true);
        }
      } catch (e) {
        debugPrint('Image upload error: $e');
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

  void _applyFormat(Attribute attribute) {
    _quillController.formatSelection(attribute);
  }

  void _applySlashCommand(Attribute? attr, {bool isImage = false}) {
    // Remove the '/' character
    final sel = _quillController.selection.baseOffset;
    if (sel > 0) {
      _quillController.replaceText(sel - 1, 1, '', null);
      _quillController.updateSelection(
        TextSelection.collapsed(offset: sel - 1),
        ChangeSource.local,
      );
    }
    setState(() => _showSlashMenu = false);

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

    return Stack(
      children: [
        // Main Editor Canvas
        GestureDetector(
          onTap: () {
            if (!_editorFocusNode.hasFocus) {
              _editorFocusNode.requestFocus();
            }
          },
          behavior: HitTestBehavior.translucent,
          child: SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(
                parent: BouncingScrollPhysics()),
            padding: EdgeInsets.symmetric(
              horizontal: widget.isMobile ? 20 : 36,
              vertical: widget.isMobile ? 16 : 28,
            ),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 680),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Top header: Minimal title and status dot
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _titleController,
                            style: TextStyle(
                              fontSize: 28,
                              fontWeight: FontWeight.w700,
                              height: 1.25,
                              color: theme.colorScheme.onSurface,
                            ),
                            maxLines: null,
                            decoration: InputDecoration(
                              hintText: 'Заголовок заметки',
                              hintStyle: TextStyle(
                                fontSize: 28,
                                fontWeight: FontWeight.w700,
                                height: 1.25,
                                color: theme.colorScheme.onSurfaceVariant
                                    .withAlpha(120),
                              ),
                              border: InputBorder.none,
                              isDense: true,
                              contentPadding: EdgeInsets.zero,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        // Micro status indicator dot
                        _buildStatusDot(),
                      ],
                    ),
                    const SizedBox(height: 24),

                    // Quill Editor Canvas
                    QuillEditor(
                      controller: _quillController,
                      focusNode: _editorFocusNode,
                      scrollController: ScrollController(),
                      config: QuillEditorConfig(
                        autoFocus: false,
                        expands: false,
                        padding: EdgeInsets.zero,
                        showCursor: true,
                        detectWordBoundary: false,
                        embedBuilders: [
                          AppImageEmbedBuilder(
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
                    const SizedBox(height: 120),
                  ],
                ),
              ),
            ),
          ),
        ),

        // Floating Selection Toolbar Capsule (Desktop)
        if (_showFloatingToolbar && !widget.isMobile)
          Positioned(
            top: 24,
            left: 0,
            right: 0,
            child: Center(
              child: _buildFloatingSelectionCapsule(),
            ),
          ),

        // Slash command menu
        if (_showSlashMenu)
          Positioned(
            top: 80,
            left: MediaQuery.sizeOf(context).width > 720
                ? (MediaQuery.sizeOf(context).width - 270) / 2 - 130
                : 30,
            child: _buildSlashCommandMenu(),
          ),

        // Mobile Bottom Keyboard Strip
        if (widget.isMobile)
          Positioned(
            bottom: MediaQuery.viewInsetsOf(context).bottom + 8,
            left: 16,
            right: 16,
            child: _buildMobileToolbarStrip(),
          ),
      ],
    );
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
        width: 240,
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
            Text(
              title,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: Theme.of(context).colorScheme.onSurface,
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

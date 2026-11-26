import 'dart:convert';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_notes/note_model.dart';
import 'package:my_notes/notes_screen.dart';

void main() {
  testWidgets('NoteEditorView renders text note cleanly',
      (WidgetTester tester) async {
    final note = Note(
      id: '82878f91-884f-421a-a026-c3af0c6542ef',
      vaultId: 'TEST-123',
      title: 'фывфвф',
      plainText: 'фывфвф',
      content: jsonEncode([
        {'insert': 'фывфвффывфвффывфвффывфвффывфвффывфвф\n'}
      ]),
      updatedAt: DateTime.now(),
    );

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
          FlutterQuillLocalizations.delegate,
        ],
        supportedLocales: const [
          Locale('en', 'US'),
          Locale('ru', 'RU'),
        ],
        home: Scaffold(
          body: NoteEditorView(
            note: note,
            vaultId: 'TEST-123',
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();
    expect(find.text('фывфвф'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('NoteEditorView renders image embed cleanly',
      (WidgetTester tester) async {
    final note = Note(
      id: 'test-img-note',
      vaultId: 'TEST-123',
      title: 'Image Note',
      plainText: 'Hello',
      content: jsonEncode([
        {'insert': 'Hello\n'},
        {
          'insert': {
            'image':
                'https://fvkbsnzvluhnxsbzeivy.supabase.co/storage/v1/object/public/note-images/V3X-EGF/1795201737549.png'
          }
        },
        {'insert': '\n'}
      ]),
      updatedAt: DateTime.now(),
    );

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
          FlutterQuillLocalizations.delegate,
        ],
        supportedLocales: const [
          Locale('en', 'US'),
          Locale('ru', 'RU'),
        ],
        home: Scaffold(
          body: NoteEditorView(
            note: note,
            vaultId: 'TEST-123',
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();
    expect(find.text('Image Note'), findsOneWidget);
    final canvasImageFinder = find.byWidgetPredicate(
        (w) => w.runtimeType.toString() == '_CanvasImageWidget');
    expect(canvasImageFinder, findsOneWidget);

    // Freeform drag test: drag image by (60, 40)
    await tester.drag(canvasImageFinder, const Offset(60, 40));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('NoteEditorView updates text and title when remote changes arrive',
      (WidgetTester tester) async {
    final noteInitial = Note(
      id: 'sync-test-note',
      vaultId: 'TEST-123',
      title: 'Initial Title',
      plainText: 'Initial text',
      content: jsonEncode([
        {'insert': 'Initial text\n'}
      ]),
      updatedAt: DateTime.now(),
    );

    final noteUpdated = Note(
      id: 'sync-test-note',
      vaultId: 'TEST-123',
      title: 'Synced from Phone',
      plainText: 'Hello from Android!',
      content: jsonEncode([
        {'insert': 'Hello from Android!\n'}
      ]),
      updatedAt: DateTime.now().add(const Duration(seconds: 1)),
    );

    final currentNote = ValueNotifier<Note>(noteInitial);

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
          FlutterQuillLocalizations.delegate,
        ],
        supportedLocales: const [
          Locale('en', 'US'),
          Locale('ru', 'RU'),
        ],
        home: Scaffold(
          body: ValueListenableBuilder<Note>(
            valueListenable: currentNote,
            builder: (context, note, _) => NoteEditorView(
              key: ValueKey(note.id),
              note: note,
              vaultId: 'TEST-123',
            ),
          ),
        ),
      ),
    );

    await tester.pump();
    expect(find.text('Initial Title'), findsOneWidget);

    // Simulate remote update arriving from phone
    currentNote.value = noteUpdated;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('Synced from Phone'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'NoteEditorView triggers onNoteUpdated when edited after remote doc sync',
      (WidgetTester tester) async {
    final noteInitial = Note(
      id: 'doc-sync-edit-note',
      vaultId: 'TEST-123',
      title: 'Initial Title',
      plainText: 'Initial text',
      content: jsonEncode([
        {'insert': 'Initial text\n'}
      ]),
      updatedAt: DateTime.now(),
    );

    final noteUpdated = Note(
      id: 'doc-sync-edit-note',
      vaultId: 'TEST-123',
      title: 'Synced Title',
      plainText: 'Synced text',
      content: jsonEncode([
        {'insert': 'Synced text\n'}
      ]),
      updatedAt: DateTime.now().add(const Duration(seconds: 1)),
    );

    final currentNote = ValueNotifier<Note>(noteInitial);
    String? updatedContent;

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
          FlutterQuillLocalizations.delegate,
        ],
        supportedLocales: const [
          Locale('en', 'US'),
          Locale('ru', 'RU'),
        ],
        home: Scaffold(
          body: ValueListenableBuilder<Note>(
            valueListenable: currentNote,
            builder: (context, note, _) => NoteEditorView(
              key: ValueKey(note.id),
              note: note,
              vaultId: 'TEST-123',
              onNoteUpdated: (id, title, plain, content) {
                updatedContent = content;
              },
            ),
          ),
        ),
      ),
    );

    await tester.pump();
    expect(find.text('Initial Title'), findsOneWidget);

    // 1. Simulate remote sync replacing the document
    currentNote.value = noteUpdated;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('Synced Title'), findsOneWidget);

    // 2. Now user types text into the editor after document was replaced
    final quillEditorFinder = find.byType(QuillEditor);
    expect(quillEditorFinder, findsOneWidget);

    final quillEditor = tester.widget<QuillEditor>(quillEditorFinder);
    quillEditor.controller.document.insert(0, '123egor ');
    await tester.pump();
    // Wait for the 500ms debounce save timer to fire
    await tester.pump(const Duration(milliseconds: 600));

    expect(updatedContent, isNotNull);
    expect(updatedContent!.contains('123egor'), isTrue);
  });

  testWidgets(
      'NoteEditorView saves text even with pending data:image and triggers slash menu only at boundaries',
      (WidgetTester tester) async {
    final note = Note(
      id: 'pending-img-note',
      vaultId: 'TEST-123',
      title: 'Pending Image',
      plainText: '',
      content: jsonEncode({
        'delta': [
          {'insert': '\n'}
        ],
        'images': [
          {
            'id': 'img_pending',
            'url': 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
            'x': 20.0,
            'y': 20.0,
            'width': 120.0,
            'height': 120.0,
            'aspectRatio': 1.0,
          }
        ]
      }),
      updatedAt: DateTime.now(),
    );

    String? savedContent;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
          FlutterQuillLocalizations.delegate,
        ],
        supportedLocales: const [
          Locale('en', 'US'),
          Locale('ru', 'RU'),
        ],
        home: Scaffold(
          body: NoteEditorView(
            note: note,
            vaultId: 'TEST-123',
            onNoteUpdated: (id, title, plain, content) {
              savedContent = content;
            },
          ),
        ),
      ),
    );

    await tester.pump();
    final quillEditor = tester.widget<QuillEditor>(find.byType(QuillEditor));

    // Typing 'https:/' should NOT open slash menu
    quillEditor.controller.replaceText(
      0,
      0,
      'https:/',
      const TextSelection.collapsed(offset: 7),
    );
    await tester.pump();
    expect(find.text('Заголовок H1'), findsNothing);

    // Typing '/' after a space SHOULD open slash menu
    quillEditor.controller.replaceText(
      7,
      0,
      ' /',
      const TextSelection.collapsed(offset: 9),
    );
    await tester.pump();
    expect(find.text('Заголовок H1'), findsOneWidget);

    // Wait for debounce save -> text MUST be saved even though data:image/ is pending
    await tester.pump(const Duration(milliseconds: 600));
    expect(savedContent, isNotNull);
    expect(savedContent!.contains('https:/'), isTrue);
    expect(savedContent!.contains('data:image/'), isFalse);
  });

  testWidgets('NoteEditorView extracts legacy delta images when switching notes',
      (WidgetTester tester) async {
    final note1 = Note(
      id: 'note-1',
      vaultId: 'TEST-123',
      title: 'Note One',
      plainText: 'One',
      content: jsonEncode({
        'delta': [
          {'insert': 'One\n'}
        ],
        'images': [],
      }),
      updatedAt: DateTime.now(),
    );

    final note2Legacy = Note(
      id: 'note-2',
      vaultId: 'TEST-123',
      title: 'Note Two Legacy',
      plainText: 'Two',
      content: jsonEncode([
        {'insert': 'Two\n'},
        {
          'insert': {
            'image':
                'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII='
          }
        },
        {'insert': '\n'}
      ]),
      updatedAt: DateTime.now(),
    );

    final currentNote = ValueNotifier<Note>(note1);

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
          FlutterQuillLocalizations.delegate,
        ],
        supportedLocales: const [
          Locale('en', 'US'),
          Locale('ru', 'RU'),
        ],
        home: Scaffold(
          body: ValueListenableBuilder<Note>(
            valueListenable: currentNote,
            builder: (context, note, _) => NoteEditorView(
              note: note,
              vaultId: 'TEST-123',
            ),
          ),
        ),
      ),
    );

    await tester.pump();
    expect(
        find.byWidgetPredicate(
            (w) => w.runtimeType.toString() == '_CanvasImageWidget'),
        findsNothing);

    currentNote.value = note2Legacy;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('Note Two Legacy'), findsOneWidget);
    expect(
        find.byWidgetPredicate(
            (w) => w.runtimeType.toString() == '_CanvasImageWidget'),
        findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('NoteMobileEditorScreen avoids duplicate visible hero title at top',
      (WidgetTester tester) async {
    final note = Note(
      id: 'mobile-note-1',
      vaultId: 'TEST-123',
      title: 'Mobile Unique Title',
      plainText: 'Body text',
      content: jsonEncode({
        'delta': [
          {'insert': 'Body text\n'}
        ],
        'images': [],
      }),
      updatedAt: DateTime.now(),
    );
    final notifier = ValueNotifier<List<Note>>([note]);

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
          FlutterQuillLocalizations.delegate,
        ],
        supportedLocales: const [
          Locale('en', 'US'),
          Locale('ru', 'RU'),
        ],
        home: NoteMobileEditorScreen(
          note: note,
          vaultId: 'TEST-123',
          notesNotifier: notifier,
          onNoteUpdated: null,
          onNoteDeleted: (_) {},
          onBroadcastSync: null,
        ),
      ),
    );

    await tester.pumpAndSettle();
    // Editable title is visible (opacity 1), compact AppBar title is hidden (opacity 0)
    final appBarAnimatedOpacity = tester.widget<AnimatedOpacity>(
      find.byType(AnimatedOpacity).first,
    );
    expect(appBarAnimatedOpacity.opacity, equals(0.0));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Continuous back-and-forth canvas image drag preserves 1:1 position without drift',
      (WidgetTester tester) async {
    final note = Note(
      id: 'drag-smooth-note',
      vaultId: 'TEST-123',
      title: 'Drag Test',
      plainText: 'Text',
      content: jsonEncode({
        'delta': [
          {'insert': 'Text\n'}
        ],
        'images': [
          {
            'id': 'img_drag_1',
            'url':
                'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
            'x': 50.0,
            'y': 40.0,
            'width': 160.0,
            'height': 120.0,
            'aspectRatio': 160.0 / 120.0,
          }
        ],
      }),
      updatedAt: DateTime.now(),
    );

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
          FlutterQuillLocalizations.delegate,
        ],
        supportedLocales: const [
          Locale('en', 'US'),
          Locale('ru', 'RU'),
        ],
        home: Scaffold(
          body: NoteEditorView(
            note: note,
            vaultId: 'TEST-123',
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();
    final imageFinder = find.byWidgetPredicate(
        (w) => w.runtimeType.toString() == '_CanvasImageWidget');
    expect(imageFinder, findsOneWidget);

    final startCenter = tester.getCenter(imageFinder);
    final gesture = await tester.startGesture(
      startCenter,
      kind: PointerDeviceKind.mouse,
    );
    // Simulate prolonged back-and-forth dragging across canvas center & margins
    for (int i = 0; i < 20; i++) {
      await gesture.moveBy(const Offset(10, 4));
      await tester.pump(const Duration(milliseconds: 16));
    }
    for (int i = 0; i < 20; i++) {
      await gesture.moveBy(const Offset(-10, -4));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pumpAndSettle();

    final endCenter = tester.getCenter(imageFinder);
    expect(endCenter.dx, closeTo(startCenter.dx, 0.5));
    expect(endCenter.dy, closeTo(startCenter.dy, 0.5));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Ctrl+Z, Cmd+Z and Redo work for text edits and canvas images',
      (WidgetTester tester) async {
    final note = Note(
      id: 'undo-redo-note',
      vaultId: 'TEST-123',
      title: 'Undo Note',
      plainText: 'Start',
      content: jsonEncode({
        'delta': [
          {'insert': 'Start\n'}
        ],
        'images': [
          {
            'id': 'img_undo_1',
            'url':
                'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
            'x': 20.0,
            'y': 30.0,
            'width': 140.0,
            'height': 100.0,
            'aspectRatio': 1.4,
          }
        ],
      }),
      updatedAt: DateTime.now(),
    );

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
          FlutterQuillLocalizations.delegate,
        ],
        supportedLocales: const [
          Locale('en', 'US'),
          Locale('ru', 'RU'),
        ],
        home: Scaffold(
          body: NoteEditorView(
            note: note,
            vaultId: 'TEST-123',
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    // Focus Quill editor and insert text cleanly
    final quillEditor = tester.widget<QuillEditor>(find.byType(QuillEditor));
    quillEditor.focusNode.requestFocus();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    quillEditor.controller.replaceText(
      5,
      0,
      ' Edited',
      const TextSelection.collapsed(offset: 12),
    );
    await tester.pump(const Duration(milliseconds: 500));
    expect(quillEditor.controller.document.toPlainText().trim(), equals('Start Edited'));

    // Also drag the canvas image from its initial position
    final imageFinder = find.byWidgetPredicate(
        (w) => w.runtimeType.toString() == '_CanvasImageWidget');
    final initialCenter = tester.getCenter(imageFinder);
    final dragGesture = await tester.startGesture(
      initialCenter,
      kind: PointerDeviceKind.mouse,
    );
    await dragGesture.moveBy(const Offset(80, 40));
    await tester.pump(const Duration(milliseconds: 16));
    await dragGesture.up();
    await tester.pumpAndSettle();
    final movedCenter = tester.getCenter(imageFinder);
    expect(movedCenter.dx, closeTo(initialCenter.dx + 80, 1.0));

    // 1. Ctrl+Z should undo the image move first
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(tester.getCenter(imageFinder).dx, closeTo(initialCenter.dx, 1.0));

    // 2. Cmd+Z (Meta+Z) should undo the text edit next
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();
    expect(quillEditor.controller.document.toPlainText().trim(), equals('Start'));

    // 3. Cmd+Shift+Z should redo the text edit back
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();
    expect(quillEditor.controller.document.toPlainText().trim(), equals('Start Edited'));

    // 4. Ctrl+Y should redo the image move back
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyY);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyY);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(tester.getCenter(imageFinder).dx, closeTo(movedCenter.dx, 1.0));

    expect(tester.takeException(), isNull);
  });

  testWidgets('NoteEditorView renders attached files on desktop & mobile and supports Undo delete',
      (WidgetTester tester) async {
    final note = Note(
      id: 'file-attach-note',
      vaultId: 'TEST-123',
      title: 'Files Note',
      plainText: 'Body',
      content: jsonEncode({
        'delta': [
          {'insert': 'Body\n'}
        ],
        'images': [],
        'files': [
          {
            'id': 'file_1',
            'name': 'Спецификация.pdf',
            'url': 'https://example.com/spec.pdf',
            'size': 1572864,
            'ext': 'pdf',
          }
        ],
      }),
      updatedAt: DateTime.now(),
    );

    // 1. Mobile layout renders file card without infinite width errors
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
          FlutterQuillLocalizations.delegate,
        ],
        supportedLocales: const [
          Locale('en', 'US'),
          Locale('ru', 'RU'),
        ],
        home: Scaffold(
          body: NoteEditorView(
            note: note,
            vaultId: 'TEST-123',
            isMobile: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Спецификация.pdf'), findsOneWidget);
    expect(find.text('1.5 МБ · PDF'), findsOneWidget);

    // Delete file on mobile (delete icon is always visible on mobile)
    await tester.tap(find.byIcon(Icons.close_rounded).first);
    await tester.pumpAndSettle();
    expect(find.text('Спецификация.pdf'), findsNothing);

    // Ctrl+Z restores the deleted file attachment cleanly
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(find.text('Спецификация.pdf'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Remote sync updates both canvas images and attached files visually',
      (WidgetTester tester) async {
    final initial = Note(
      id: 'sync-files-note',
      vaultId: 'TEST-123',
      title: 'Sync Title',
      plainText: 'Initial',
      content: jsonEncode({
        'delta': [
          {'insert': 'Initial\n'}
        ],
        'images': [],
        'files': [],
      }),
      updatedAt: DateTime.now(),
    );

    final updated = Note(
      id: 'sync-files-note',
      vaultId: 'TEST-123',
      title: 'Sync Title',
      plainText: 'Initial',
      content: jsonEncode({
        'delta': [
          {'insert': 'Initial\n'}
        ],
        'images': [
          {
            'id': 'img_remote_1',
            'url':
                'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
            'x': 20.0,
            'y': 20.0,
            'width': 160.0,
            'height': 120.0,
          }
        ],
        'files': [
          {
            'id': 'file_remote_1',
            'name': 'Синхронизированный_документ.docx',
            'url': 'https://example.com/doc.docx',
            'size': 524288,
            'ext': 'docx',
          }
        ],
      }),
      updatedAt: DateTime.now().add(const Duration(seconds: 2)),
    );

    final notifier = ValueNotifier<Note>(initial);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
          FlutterQuillLocalizations.delegate,
        ],
        supportedLocales: const [
          Locale('en', 'US'),
          Locale('ru', 'RU'),
        ],
        home: Scaffold(
          body: ValueListenableBuilder<Note>(
            valueListenable: notifier,
            builder: (context, note, _) => NoteEditorView(
              key: ValueKey(note.id),
              note: note,
              vaultId: 'TEST-123',
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Синхронизированный_документ.docx'), findsNothing);
    expect(
        find.byWidgetPredicate(
            (w) => w.runtimeType.toString() == '_CanvasImageWidget'),
        findsNothing);

    // Remote sync arrives
    notifier.value = updated;
    await tester.pumpAndSettle();

    expect(find.text('Синхронизированный_документ.docx'), findsOneWidget);
    expect(
        find.byWidgetPredicate(
            (w) => w.runtimeType.toString() == '_CanvasImageWidget'),
        findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'Mobile clamps oversized images, scrolls over unselected image, and drags selected image',
      (WidgetTester tester) async {
    const String imgUrl = 'https://example.com/wide_test.png';
    AppImageCache.put(
      imgUrl,
      base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=='),
    );
    final content = jsonEncode({
      'delta': [
        {'insert': 'Строка 1\nСтрока 2\nСтрока 3\n'},
      ],
      'images': [
        {
          'id': 'img_wide',
          'url': imgUrl,
          'x': 320.0,
          'y': 40.0,
          'width': 520.0,
          'height': 260.0,
          'aspectRatio': 2.0,
        },
      ],
      'files': [],
    });

    final note = Note(
      id: 'mobile-ux-1',
      vaultId: 'TEST-123',
      title: 'Mobile UX',
      content: content,
      plainText: 'Строка 1',
      updatedAt: DateTime.now(),
    );

    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    String? latestContent;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: const [
          FlutterQuillLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: const [
          Locale('en', 'US'),
          Locale('ru', 'RU'),
        ],
        home: Scaffold(
          body: NoteEditorView(
            key: ValueKey(note.id),
            note: note,
            vaultId: 'TEST-123',
            isMobile: true,
            onNoteUpdated: (_, _, _, c) => latestContent = c,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final imageFinder = find.byWidgetPredicate(
        (w) => w.runtimeType.toString() == '_CanvasImageWidget');
    expect(imageFinder, findsOneWidget);

    // Oversized image (520px) must fit inside 390px phone viewport
    final rectBefore = tester.getRect(imageFinder);
    expect(rectBefore.right, lessThanOrEqualTo(390.0));
    expect(rectBefore.width, lessThanOrEqualTo(350.0));

    // Dragging over an unselected image should scroll the page, NOT move the image
    await tester.drag(imageFinder, const Offset(0, -80));
    await tester.pumpAndSettle();
    expect(latestContent, isNull);

    // Tap to select the image, then drag it right/down — now it moves!
    await tester.tap(imageFinder);
    await tester.pumpAndSettle();
    await tester.drag(imageFinder, const Offset(-40, 50));
    await tester.pumpAndSettle();

    expect(latestContent, isNotNull);
    final savedImages = parseNoteContent(latestContent!).images;
    expect(savedImages.first.y, greaterThan(40.0));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Deferred remote sync reconciles after recent local edit settles',
      (WidgetTester tester) async {
    const String imgUrl = 'https://example.com/deferred_test.png';
    AppImageCache.put(
      imgUrl,
      base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=='),
    );

    final initialNote = Note(
      id: 'deferred-sync-1',
      vaultId: 'TEST-123',
      title: 'Note',
      content: jsonEncode({
        'delta': [
          {'insert': 'Hello\n'},
        ],
        'images': [],
        'files': [],
      }),
      plainText: 'Hello',
      updatedAt: DateTime.now(),
    );

    final notifier = ValueNotifier<Note>(initialNote);

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: const [
          FlutterQuillLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: const [
          Locale('en', 'US'),
          Locale('ru', 'RU'),
        ],
        home: Scaffold(
          body: ValueListenableBuilder<Note>(
            valueListenable: notifier,
            builder: (context, note, _) => NoteEditorView(
              key: ValueKey(note.id),
              note: note,
              vaultId: 'TEST-123',
              isMobile: true,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Trigger a recent local edit on the title
    await tester.enterText(find.byType(TextField).first, 'Note local');
    await tester.pump();

    // While local edit is fresh (< 1200ms), remote update arrives with a file + image
    notifier.value = initialNote.copyWith(
      content: jsonEncode({
        'delta': [
          {'insert': 'Hello\n'},
        ],
        'images': [
          {
            'id': 'img_deferred',
            'url': imgUrl,
            'x': 10.0,
            'y': 10.0,
            'width': 120.0,
            'height': 120.0,
          },
        ],
        'files': [
          {
            'id': 'file_deferred',
            'name': 'Отчет_телефон.pdf',
            'url': 'https://example.com/report.pdf',
            'size': 2048,
            'ext': 'pdf',
          },
        ],
      }),
    );
    await tester.pump();

    // Wait real wall-clock 1.3s so DateTime.now() settles past 1200ms, then pump fake timers
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 1300)));
    await tester.pump(const Duration(milliseconds: 1200));
    await tester.pumpAndSettle();

    expect(find.text('Отчет_телефон.pdf'), findsOneWidget);
    expect(
        find.byWidgetPredicate(
            (w) => w.runtimeType.toString() == '_CanvasImageWidget'),
        findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

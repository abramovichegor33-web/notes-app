import 'dart:convert';
import 'package:flutter/material.dart';
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
}

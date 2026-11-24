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
    expect(find.byType(Draggable<ImageDragPayload>), findsOneWidget);
    expect(find.byType(DragTarget<ImageDragPayload>), findsOneWidget);
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
}

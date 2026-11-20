import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_notes/note_model.dart';
import 'package:my_notes/notes_screen.dart';

void main() {
  testWidgets('NoteEditorView renders text note cleanly', (WidgetTester tester) async {
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

    await tester.pump();
    expect(find.text('фывфвф'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('NoteEditorView renders image embed cleanly', (WidgetTester tester) async {
    final note = Note(
      id: 'test-img-note',
      vaultId: 'TEST-123',
      title: 'Image Note',
      plainText: 'Hello',
      content: jsonEncode([
        {'insert': 'Hello\n'},
        {
          'insert': {
            'image': 'https://fvkbsnzvluhnxsbzeivy.supabase.co/storage/v1/object/public/note-images/V3X-EGF/1795201737549.png'
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

    await tester.pump();
    expect(find.text('Image Note'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

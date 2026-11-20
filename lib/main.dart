import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'notes_screen.dart';
import 'vault_service.dart';

const String supabaseUrl = 'https://fvkbsnzvluhnxsbzeivy.supabase.co';
const String supabaseAnonKey =
    'sb_publishable_Wv1HBMHDBJFkIfwOjCi89A_OMXEQvnS';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Supabase.initialize(
    url: supabaseUrl,
    anonKey: supabaseAnonKey,
  );

  runApp(const NotesApp());
}

class NotesApp extends StatefulWidget {
  const NotesApp({super.key});

  @override
  State<NotesApp> createState() => _NotesAppState();
}

class _NotesAppState extends State<NotesApp> {
  String? _vaultId;

  @override
  void initState() {
    super.initState();
    _loadVault();
  }

  Future<void> _loadVault() async {
    final id = await VaultService.getOrCreateVaultId();
    if (mounted) {
      setState(() => _vaultId = id);
    }
  }

  @override
  Widget build(BuildContext context) {
    const accentColor = Color(0xFF6366F1);

    return MaterialApp(
      title: 'Заметки',
      debugShowCheckedModeBanner: false,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        FlutterQuillLocalizations.delegate,
      ],
      supportedLocales: const [
        Locale('ru', 'RU'),
        Locale('en', 'US'),
      ],
      theme: ThemeData(
        brightness: Brightness.light,
        scaffoldBackgroundColor: const Color(0xFFFFFFFF),
        colorScheme: ColorScheme.light(
          primary: accentColor,
          surface: const Color(0xFFF8FAFC),
          onSurface: const Color(0xFF0F172A),
          surfaceContainerHighest: const Color(0xFFF1F5F9),
          outlineVariant: const Color(0xFFE2E8F0),
        ),
        dividerColor: const Color(0xFFE2E8F0),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF141416),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF818CF8),
          surface: Color(0xFF1A1A1E),
          onSurface: Color(0xFFF4F4F5),
          surfaceContainerHighest: Color(0xFF222228),
          outlineVariant: Color(0xFF2D2D34),
        ),
        dividerColor: const Color(0xFF27272E),
        useMaterial3: true,
      ),
      themeMode: ThemeMode.system,
      home: _vaultId == null
          ? const Scaffold(
              body: Center(
                child: SizedBox(
                  width: 32,
                  height: 32,
                  child: CircularProgressIndicator(strokeWidth: 2.5),
                ),
              ),
            )
          : NotesScreen(
              vaultId: _vaultId!,
              onVaultChanged: (newVault) => setState(() => _vaultId = newVault),
            ),
    );
  }
}

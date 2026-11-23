import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'notes_screen.dart';
import 'vault_service.dart';

const String supabaseUrl = 'https://fvkbsnzvluhnxsbzeivy.supabase.co';
const String supabaseAnonKey =
    'sb_publishable_Wv1HBMHDBJFkIfwOjCi89A_OMXEQvnS';

final ValueNotifier<ThemeMode> appThemeModeNotifier =
    ValueNotifier<ThemeMode>(ThemeMode.system);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Supabase.initialize(
    url: supabaseUrl,
    anonKey: supabaseAnonKey,
  );

  final savedTheme = await VaultService.getThemeMode();
  appThemeModeNotifier.value = savedTheme;

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

    final darkTheme = ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: const Color(0xFF0D0E10), // Base dark canvas
      canvasColor: const Color(0xFF0D0E10),
      cardColor: const Color(0xFF141518), // Floating editor card sheet
      colorScheme: const ColorScheme.dark(
        primary: accentColor,
        surface: Color(0xFF121316), // Sidebar background
        onSurface: Color(0xFFEDEDEF), // Primary text
        onSurfaceVariant: Color(0xFF7E828C), // Secondary text
        surfaceContainerHighest: Color(0xFF1E2026), // Active note card
        outlineVariant: Color(0x14FFFFFF), // Hairline border (rgba(255,255,255,0.08))
      ),
      dividerColor: const Color(0x0FFFFFFF), // Hairline separator (rgba(255,255,255,0.06))
      textSelectionTheme: const TextSelectionThemeData(
        cursorColor: accentColor,
        selectionColor: Color(0x406366F1),
        selectionHandleColor: accentColor,
      ),
      scrollbarTheme: ScrollbarThemeData(
        thumbVisibility: const WidgetStatePropertyAll(false),
        radius: const Radius.circular(8),
        thickness: const WidgetStatePropertyAll(5),
        thumbColor: WidgetStatePropertyAll(Colors.white.withAlpha(50)),
      ),
      useMaterial3: true,
    );

    final lightTheme = ThemeData(
      brightness: Brightness.light,
      scaffoldBackgroundColor: const Color(0xFFF0F1F4), // Base light canvas
      canvasColor: const Color(0xFFF0F1F4),
      cardColor: const Color(0xFFFFFFFF), // Floating editor card sheet
      colorScheme: const ColorScheme.light(
        primary: accentColor,
        surface: Color(0xFFF6F7F9), // Sidebar background
        onSurface: Color(0xFF1A1B1E), // Primary text
        onSurfaceVariant: Color(0xFF6E737D), // Secondary text
        surfaceContainerHighest: Color(0xFFFFFFFF), // Active note card
        outlineVariant: Color(0x12000000), // Hairline border (rgba(0,0,0,0.07))
      ),
      dividerColor: const Color(0x0F000000), // Hairline separator (rgba(0,0,0,0.06))
      textSelectionTheme: const TextSelectionThemeData(
        cursorColor: accentColor,
        selectionColor: Color(0x336366F1),
        selectionHandleColor: accentColor,
      ),
      scrollbarTheme: ScrollbarThemeData(
        thumbVisibility: const WidgetStatePropertyAll(false),
        radius: const Radius.circular(8),
        thickness: const WidgetStatePropertyAll(5),
        thumbColor: WidgetStatePropertyAll(Colors.black.withAlpha(50)),
      ),
      useMaterial3: true,
    );

    return ValueListenableBuilder<ThemeMode>(
      valueListenable: appThemeModeNotifier,
      builder: (context, themeMode, _) {
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
          theme: lightTheme,
          darkTheme: darkTheme,
          themeMode: themeMode,
          home: _vaultId == null
              ? const Scaffold(
                  body: Center(
                    child: SizedBox(
                      width: 28,
                      height: 28,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                )
              : NotesScreen(
                  vaultId: _vaultId!,
                  onVaultChanged: (newVault) =>
                      setState(() => _vaultId = newVault),
                ),
        );
      },
    );
  }
}

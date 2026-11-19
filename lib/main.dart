import 'package:flutter/material.dart';
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
    setState(() => _vaultId = id);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Заметки',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.deepPurple,
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.deepPurple,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      themeMode: ThemeMode.system,
      home: _vaultId == null
          ? const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            )
          : NotesScreen(
              vaultId: _vaultId!,
              onVaultChanged: (newVault) => setState(() => _vaultId = newVault),
            ),
    );
  }
}

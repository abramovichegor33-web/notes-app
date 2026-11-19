import 'dart:math';
import 'package:shared_preferences/shared_preferences.dart';

class VaultService {
  static const _key = 'user_vault_id';

  static Future<String> getOrCreateVaultId() async {
    final prefs = await SharedPreferences.getInstance();
    String? vaultId = prefs.getString(_key);
    if (vaultId == null || vaultId.isEmpty) {
      vaultId = _generateShortCode();
      await prefs.setString(_key, vaultId);
    }
    return vaultId;
  }

  static Future<void> setVaultId(String vaultId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, vaultId.trim().toUpperCase());
  }

  static String _generateShortCode() {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final rand = Random.secure();
    final p1 =
        List.generate(3, (_) => chars[rand.nextInt(chars.length)]).join();
    final p2 =
        List.generate(3, (_) => chars[rand.nextInt(chars.length)]).join();
    return '$p1-$p2';
  }
}

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'vault_service.dart';

class SyncDialog extends StatefulWidget {
  final String currentVaultId;
  final ValueChanged<String> onVaultChanged;

  const SyncDialog({
    super.key,
    required this.currentVaultId,
    required this.onVaultChanged,
  });

  @override
  State<SyncDialog> createState() => _SyncDialogState();
}

class _SyncDialogState extends State<SyncDialog> {
  final _inputController = TextEditingController();
  bool _isCopied = false;
  bool _isConnecting = false;

  @override
  void dispose() {
    _inputController.dispose();
    super.dispose();
  }

  void _copyCode() {
    Clipboard.setData(ClipboardData(text: widget.currentVaultId));
    setState(() => _isCopied = true);
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _isCopied = false);
    });
  }

  Future<void> _connectNewCode() async {
    final code = _inputController.text.trim().toUpperCase();
    if (code.isEmpty || code == widget.currentVaultId) return;

    setState(() => _isConnecting = true);

    try {
      // Переносим существующие заметки старого хранилища в новое
      await Supabase.instance.client
          .from('notes')
          .update({'vault_id': code})
          .eq('vault_id', widget.currentVaultId);
    } catch (_) {}

    await VaultService.setVaultId(code);
    widget.onVaultChanged(code);

    if (mounted) {
      setState(() => _isConnecting = false);
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Устройства связаны! Хранилище: $code'),
          backgroundColor: Colors.green.shade700,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = Theme.of(context).colorScheme.primary;

    return Dialog(
      backgroundColor: isDark ? const Color(0xFF1E1E24) : Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.devices_rounded, size: 22),
                      SizedBox(width: 8),
                      Text(
                        'Синхронизация',
                        style: TextStyle(
                            fontSize: 18, fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 20),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Text(
                'Чтобы синхронизировать заметки с телефоном или другим компьютером, введите этот код на втором устройстве:',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  color: isDark ? Colors.white70 : Colors.black87,
                ),
              ),
              const SizedBox(height: 16),

              // QR код
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withAlpha(20),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: QrImageView(
                  data: widget.currentVaultId,
                  version: QrVersions.auto,
                  size: 150,
                  backgroundColor: Colors.white,
                ),
              ),
              const SizedBox(height: 16),

              // Код хранилища с кнопкой копирования
              InkWell(
                onTap: _copyCode,
                borderRadius: BorderRadius.circular(10),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                  decoration: BoxDecoration(
                    color: accent.withAlpha(isDark ? 40 : 25),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: accent.withAlpha(100), width: 1),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        widget.currentVaultId,
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 2.5,
                          color: isDark ? Colors.white : accent,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Icon(
                        _isCopied ? Icons.check_rounded : Icons.copy_rounded,
                        size: 18,
                        color: _isCopied ? Colors.green : accent,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                _isCopied ? 'Код скопирован!' : 'Нажмите на код, чтобы скопировать',
                style: TextStyle(
                  fontSize: 11,
                  color: _isCopied ? Colors.green : Colors.grey,
                ),
              ),

              const SizedBox(height: 20),
              Divider(color: isDark ? const Color(0xFF2E2E36) : const Color(0xFFE2E8F0)),
              const SizedBox(height: 14),

              Text(
                'Или введите код со своего телефона/Mac:',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                  color: isDark ? Colors.white : Colors.black87,
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _inputController,
                      textCapitalization: TextCapitalization.characters,
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.bold, letterSpacing: 1.5),
                      decoration: InputDecoration(
                        hintText: 'Например: V3X-EGF',
                        hintStyle: TextStyle(
                          fontSize: 13,
                          letterSpacing: 0,
                          color: isDark ? Colors.white24 : Colors.black26,
                        ),
                        filled: true,
                        fillColor: isDark
                            ? const Color(0xFF26262E)
                            : const Color(0xFFF1F5F9),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide.none,
                        ),
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 11),
                      ),
                      onSubmitted: (_) => _connectNewCode(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 11),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8)),
                    ),
                    onPressed: _isConnecting ? null : _connectNewCode,
                    child: _isConnecting
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white),
                          )
                        : const Text('Связать'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

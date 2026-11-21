import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/agent_client.dart';
import '../core/gen/version.dart';
import '../core/paired_devices.dart';
import '../core/pairing_flow.dart';
import '../core/pairing_payload.dart';
import 'send_screen.dart';
import 'qr_scan_screen.dart';
import 'update_button.dart';

/// First run: paste (or scan) the pairing code the PC agent shows, and connect.
///
/// The code is a small JSON document — see [PairingPayload]. It can be pasted, copied from the
/// clipboard with the button below, or scanned with the QR button in the app bar.
class PairScreen extends StatefulWidget {
  const PairScreen({super.key});

  @override
  State<PairScreen> createState() => _PairScreenState();
}

class _PairScreenState extends State<PairScreen> {
  final _payloadController = TextEditingController();
  final _nameController = TextEditingController(text: _defaultDeviceName());

  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _payloadController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  static String _defaultDeviceName() {
    try {
      final host = Platform.localHostname;
      if (host.isNotEmpty && host != 'localhost') return host;
    } on Object {
      // Platform lookups can throw on some builds; fall back below.
    }
    return 'My phone';
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (text == null || text.isEmpty) {
      _showMessage('The clipboard is empty.');
      return;
    }
    _payloadController.text = text;
    setState(() => _error = null);
  }

  Future<void> _scanQr() async {
    final payload = await Navigator.of(context).push<PairingPayload>(
      MaterialPageRoute(builder: (_) => const QrScanScreen()),
    );
    if (payload == null || !mounted) return;
    _payloadController.text = payload.toJson();
    setState(() => _error = null);
  }

  Future<void> _pair() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final payload = PairingPayload.parse(_payloadController.text);
      final name = _nameController.text.trim().isEmpty ? 'Android phone' : _nameController.text.trim();
      final outcome = await pairWithPayload(payload, deviceName: name, appVersion: kCloudBoxVersion);
      // Save before checking `mounted`: even if the screen went away, the pairing is valid and
      // should be available from the Paired devices list next time.
      await PairedDeviceStore.upsert(outcome.record);
      if (!mounted) {
        outcome.client.close();
        return;
      }
      // The destination is chosen on the paired PC, so there is no drive picker here. The agent
      // already told us which folder this device backs up to in `outcome.info`.
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => SendScreen(outcome: outcome)),
      );
    } on CloudBoxException catch (error) {
      setState(() => _error = error.message);
    } on FormatException catch (error) {
      setState(() => _error = error.message);
    } on Object catch (error) {
      setState(() => _error = 'Something went wrong: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Connect to your PC'),
        actions: [
          IconButton(
            tooltip: 'Scan QR',
            icon: const Icon(Icons.qr_code_scanner),
            onPressed: _busy ? null : _scanQr,
          ),
          UpdateButton(platform: 'android'),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
              children: [
                Icon(Icons.cloud_upload_outlined, size: 64, color: theme.colorScheme.primary),
                const SizedBox(height: 16),
                Text(
                  'Start the CloudBox agent on your PC, then scan its QR code or paste the '
                  'pairing code it shows. Your files never touch a server we control.',
                  style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 28),
                TextField(
                  controller: _payloadController,
                  minLines: 3,
                  maxLines: 6,
                  enabled: !_busy,
                  autocorrect: false,
                  enableSuggestions: false,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                  decoration: InputDecoration(
                    labelText: 'Pairing code',
                    alignLabelWithHint: true,
                    border: const OutlineInputBorder(),
                    suffixIcon: IconButton(
                      tooltip: 'Paste from clipboard',
                      onPressed: _busy ? null : _pasteFromClipboard,
                      icon: const Icon(Icons.content_paste),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _nameController,
                  enabled: !_busy,
                  maxLength: 64,
                  decoration: const InputDecoration(
                    labelText: "This phone's name",
                    helperText: 'Shown on the PC so you can tell your devices apart.',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                if (_error != null) ...[
                  _ErrorCard(message: _error!),
                  const SizedBox(height: 16),
                ],
                FilledButton.icon(
                  onPressed: _busy ? null : _pair,
                  icon: _busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.link),
                  label: Text(_busy ? 'Connecting…' : 'Pair'),
                  style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
                ),
                const SizedBox(height: 32),
                Text(
                  'CloudBox $kCloudBoxVersion',
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.error_outline, color: scheme.onErrorContainer),
            const SizedBox(width: 12),
            Expanded(
              child: Text(message, style: TextStyle(color: scheme.onErrorContainer)),
            ),
          ],
        ),
      ),
    );
  }
}

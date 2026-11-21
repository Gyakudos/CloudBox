import 'package:flutter/material.dart';

import '../core/agent_client.dart';
import '../core/paired_devices.dart';
import '../core/pairing_flow.dart';
import 'pair_screen.dart';
import 'send_screen.dart';
import 'update_button.dart';

/// The app's home screen: PCs this phone has already paired with.
///
/// Pairing codes are single-use, so the pairing is saved on the phone. Tapping a PC reconnects
/// with the saved device token and opens the Send screen; no QR scan is needed for later sends.
class PairedDevicesScreen extends StatefulWidget {
  const PairedDevicesScreen({super.key});

  @override
  State<PairedDevicesScreen> createState() => _PairedDevicesScreenState();
}

class _PairedDevicesScreenState extends State<PairedDevicesScreen> {
  List<PairedDeviceRecord> _devices = const [];
  String? _busyKey;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final devices = await PairedDeviceStore.load();
    if (!mounted) return;
    setState(() {
      _devices = devices;
      _loading = false;
    });
  }

  Future<void> _addPc() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const PairScreen()),
    );
    if (!mounted) return;
    setState(() => _loading = true);
    await _load();
  }

  Future<void> _connect(PairedDeviceRecord record) async {
    if (_busyKey != null) return;
    setState(() {
      _busyKey = record.key;
      _error = null;
    });
    try {
      final outcome = await connectToPairedDevice(record);
      // Keep the PC's current name/version fresh, but never lose the original pairing date.
      await PairedDeviceStore.upsert(
        outcome.record.copyWith(pairedAt: record.pairedAt),
      );
      if (!mounted) {
        outcome.client.close();
        return;
      }
      await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => SendScreen(outcome: outcome)),
      );
      if (!mounted) return;
      setState(() => _loading = true);
      await _load();
    } on CloudBoxException catch (error) {
      if (!mounted) return;
      setState(() => _error = error.message);
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _error = 'Could not connect: $error');
    } finally {
      if (mounted) setState(() => _busyKey = null);
    }
  }

  Future<void> _remove(PairedDeviceRecord record) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Forget this PC?'),
        content: Text(
          '${record.serverName} will disappear from this list. Files already copied stay on the PC.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Forget'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await PairedDeviceStore.remove(record);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Paired devices'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _loading
                ? null
                : () {
                    setState(() => _loading = true);
                    _load();
                  },
          ),
          const UpdateButton(platform: 'android'),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addPc,
        icon: const Icon(Icons.add),
        label: const Text('Pair a PC'),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 88),
          children: [
            Text(
              'Pick a PC to send files to. You only need to pair once — after that it stays here.',
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            if (_error != null) ...[
              Card(
                color: theme.colorScheme.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    _error!,
                    style: TextStyle(color: theme.colorScheme.onErrorContainer),
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ],
            if (_loading)
              const Center(child: Padding(
                padding: EdgeInsets.all(32),
                child: CircularProgressIndicator(),
              ))
            else if (_devices.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 48),
                child: Column(
                  children: [
                    Icon(Icons.computer_outlined, size: 64, color: theme.colorScheme.primary),
                    const SizedBox(height: 16),
                    Text('No paired PCs yet', style: theme.textTheme.titleMedium),
                    const SizedBox(height: 8),
                    Text(
                      'Run CloudBox on your PC, then use “Pair a PC” below to scan its QR code.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
              )
            else
              ..._devices.map(
                (device) => _PairedDeviceCard(
                  device: device,
                  busy: _busyKey == device.key,
                  onConnect: () => _connect(device),
                  onRemove: () => _remove(device),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _PairedDeviceCard extends StatelessWidget {
  const _PairedDeviceCard({
    required this.device,
    required this.busy,
    required this.onConnect,
    required this.onRemove,
  });

  final PairedDeviceRecord device;
  final bool busy;
  final VoidCallback onConnect;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lastSeen = device.pairedAt.toLocal().toString().split('.').first;

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.desktop_windows_outlined, color: theme.colorScheme.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(device.serverName, style: theme.textTheme.titleMedium),
                      Text(
                        '${device.deviceName} · paired $lastSeen',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Forget this PC',
                  onPressed: busy ? null : onRemove,
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.tonalIcon(
                onPressed: busy ? null : onConnect,
                icon: busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.cloud_upload_outlined),
                label: Text(busy ? 'Connecting…' : 'Send files'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

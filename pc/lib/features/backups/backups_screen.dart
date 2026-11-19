// Read-only overview of where each paired device is backing up. Configuration lives on the
// Paired Devices tab; this tab answers "where are my backups actually going right now?".

import 'package:flutter/material.dart';

import '../../core/local_api.dart';
import '../../core/models.dart';

class BackupsScreen extends StatefulWidget {
  const BackupsScreen({
    super.key,
    required this.api,
    required this.onConfigure,
  });

  final LocalAgentApi api;

  /// Jump to the Paired Devices tab for a given device.
  final void Function(String deviceId) onConfigure;

  @override
  State<BackupsScreen> createState() => _BackupsScreenState();
}

class _BackupsScreenState extends State<BackupsScreen> {
  List<BackupStatus> _backups = const [];
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final backups = await widget.api.backups();
      if (!mounted) return;
      setState(() {
        _backups = backups;
        _loading = false;
      });
    } on CloudBoxException catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.message;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(28, 24, 28, 40),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Backups', style: theme.textTheme.headlineSmall),
                    const SizedBox(height: 4),
                    Text(
                      'One backup folder per paired device, with its current availability.',
                      style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Refresh',
                onPressed: _loading ? null : _load,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          const SizedBox(height: 20),
          if (_loading)
            const Padding(
              padding: EdgeInsets.all(40),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_error != null)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Row(children: [
                  Icon(Icons.error_outline, color: theme.colorScheme.error),
                  const SizedBox(width: 12),
                  Expanded(child: Text(_error!)),
                  TextButton(onPressed: _load, child: const Text('Retry')),
                ]),
              ),
            )
          else if (_backups.isEmpty)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  children: [
                    Icon(Icons.backup_outlined, size: 44, color: theme.colorScheme.primary),
                    const SizedBox(height: 12),
                    const Text('No backups configured yet.'),
                    const SizedBox(height: 4),
                    const Text(
                      'Pair a phone, then set its backup folder on the Paired Devices tab.',
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            )
          else
            Column(
              children: [
                for (final backup in _backups)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(18),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(
                                backup.enabled ? Icons.cloud_done_outlined : Icons.cloud_off_outlined,
                                color: backup.enabled ? theme.colorScheme.primary : theme.colorScheme.outline,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(backup.deviceName, style: theme.textTheme.titleMedium),
                                    const SizedBox(height: 2),
                                    Text(
                                      backup.enabled ? 'Backup folder active' : 'Using the global destination',
                                      style: theme.textTheme.bodySmall,
                                    ),
                                  ],
                                ),
                              ),
                              Chip(
                                visualDensity: VisualDensity.compact,
                                avatar: Icon(
                                  backup.available ? Icons.check_circle : Icons.warning_amber,
                                  size: 14,
                                ),
                                label: Text(backup.available ? 'Available' : 'Unavailable'),
                              ),
                            ],
                          ),
                          const SizedBox(height: 14),
                          _InfoRow(icon: Icons.folder_outlined, label: backup.root.isEmpty ? 'Default location' : backup.root),
                          _InfoRow(icon: Icons.insert_drive_file_outlined, label: backup.sizeText),
                          if (backup.lastBackupAt.isNotEmpty)
                            _InfoRow(icon: Icons.schedule, label: 'Last backup ${_shortDate(backup.lastBackupAt)}'),
                          const SizedBox(height: 8),
                          Align(
                            alignment: Alignment.centerRight,
                            child: TextButton.icon(
                              onPressed: () => widget.onConfigure(backup.deviceId),
                              icon: const Icon(Icons.tune),
                              label: const Text('Configure folder'),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  static String _shortDate(String raw) {
    final parsed = DateTime.tryParse(raw);
    if (parsed == null) return raw;
    final local = parsed.toLocal();
    return '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')} '
        '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        children: [
          Icon(icon, size: 16, color: Theme.of(context).colorScheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

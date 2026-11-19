// Lists every phone that has paired with this PC and lets the user point each one at its own
// backup folder. The agent persists this configuration next to the device record.

import 'package:flutter/material.dart';

import '../../core/local_api.dart';
import '../../core/models.dart';

class PairedDevicesScreen extends StatefulWidget {
  const PairedDevicesScreen({
    super.key,
    required this.api,
    required this.volumes,
    required this.onAddDevice,
  });

  final LocalAgentApi api;

  /// Drives reported by the agent; used by the per-device backup configuration dialog.
  final List<VolumeInfo> volumes;

  /// Mint a fresh pairing code and take the user to the Pairing tab.
  final Future<void> Function() onAddDevice;

  @override
  State<PairedDevicesScreen> createState() => _PairedDevicesScreenState();
}

class _PairedDevicesScreenState extends State<PairedDevicesScreen> {
  List<PairedDevice> _devices = const [];
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
      final devices = await widget.api.devices();
      if (!mounted) return;
      setState(() {
        _devices = devices;
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

  Future<void> _addDevice() async {
    try {
      await widget.onAddDevice();
    } on CloudBoxException catch (error) {
      if (mounted) _showMessage(error.message);
    }
  }

  Future<void> _configure(PairedDevice device) async {
    final updated = await showDialog<PairedDevice>(
      context: context,
      builder: (context) => _BackupConfigDialog(
        api: widget.api,
        device: device,
        volumes: widget.volumes,
      ),
    );
    if (updated == null || !mounted) return;
    setState(() {
      _devices = _devices.map((d) => d.id == updated.id ? updated : d).toList();
    });
    _showMessage('Backups for ${updated.name} will be saved to ${updated.backup.root.isEmpty ? 'the default folder' : updated.backup.root}.');
  }

  Future<void> _revoke(PairedDevice device) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove this device?'),
        content: Text(
          '${device.name} will no longer be able to back up to this PC. Its saved files are not deleted.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
            child: const Text('Remove device'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await widget.api.revokeDevice(device.id);
      if (!mounted) return;
      setState(() => _devices = _devices.where((d) => d.id != device.id).toList());
      _showMessage('${device.name} was removed.');
    } on CloudBoxException catch (error) {
      if (mounted) _showMessage(error.message);
    }
  }

  void _showMessage(String message) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
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
                    Text('Paired devices', style: theme.textTheme.headlineSmall),
                    const SizedBox(height: 4),
                    Text(
                      'Each phone can use its own backup folder on this PC.',
                      style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              FilledButton.icon(
                onPressed: _addDevice,
                icon: const Icon(Icons.add),
                label: const Text('Add device'),
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
          else if (_devices.isEmpty)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  children: [
                    Icon(Icons.devices_other_outlined, size: 44, color: theme.colorScheme.primary),
                    const SizedBox(height: 12),
                    const Text('No phones have paired yet.'),
                    const SizedBox(height: 4),
                    Text(
                      'Use “Add device” to show a pairing code, then scan it in the CloudBox app.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            )
          else
            Column(
              children: [
                for (final device in _devices)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(18),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              CircleAvatar(
                                backgroundColor: theme.colorScheme.primaryContainer,
                                child: Icon(Icons.smartphone, color: theme.colorScheme.onPrimaryContainer),
                              ),
                              const SizedBox(width: 14),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(device.name, style: theme.textTheme.titleMedium),
                                    const SizedBox(height: 2),
                                    Text(device.subtitle, style: theme.textTheme.bodySmall),
                                  ],
                                ),
                              ),
                              if (device.active)
                                Chip(
                                  avatar: const Icon(Icons.check_circle, size: 14),
                                  label: const Text('Paired'),
                                  visualDensity: VisualDensity.compact,
                                ),
                            ],
                          ),
                          const SizedBox(height: 14),
                          _DetailRow(
                            icon: Icons.folder_outlined,
                            label: device.backup.enabled && device.backup.root.isNotEmpty
                                ? device.backup.root
                                : 'Using the default backup location',
                          ),
                          if (device.lastSeenAt.isNotEmpty)
                            _DetailRow(icon: Icons.schedule, label: 'Last seen ${_shortDate(device.lastSeenAt)}'),
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              TextButton.icon(
                                onPressed: () => _configure(device),
                                icon: const Icon(Icons.settings_outlined),
                                label: const Text('Configure backup'),
                              ),
                              const Spacer(),
                              TextButton.icon(
                                onPressed: () => _revoke(device),
                                icon: Icon(Icons.person_remove_outlined, color: theme.colorScheme.error),
                                label: Text('Remove', style: TextStyle(color: theme.colorScheme.error)),
                              ),
                            ],
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

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.icon, required this.label});

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
              style: Theme.of(context).textTheme.bodySmall,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

class _BackupConfigDialog extends StatefulWidget {
  const _BackupConfigDialog({
    required this.api,
    required this.device,
    required this.volumes,
  });

  final LocalAgentApi api;
  final PairedDevice device;
  final List<VolumeInfo> volumes;

  @override
  State<_BackupConfigDialog> createState() => _BackupConfigDialogState();
}

class _BackupConfigDialogState extends State<_BackupConfigDialog> {
  late String? _volume;
  late final TextEditingController _subfolder;
  late bool _enabled;
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final backup = widget.device.backup;
    final known = widget.volumes.where((v) => v.name == backup.volume).toList();
    _volume = known.isNotEmpty ? backup.volume : (widget.volumes.isNotEmpty ? widget.volumes.first.name : null);
    _subfolder = TextEditingController(
      text: backup.subfolder.isEmpty ? 'CloudBox/${widget.device.name}' : backup.subfolder,
    );
    _enabled = backup.enabled;
  }

  @override
  void dispose() {
    _subfolder.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final volume = _volume;
    final subfolder = _subfolder.text.trim();
    if (volume == null || subfolder.isEmpty) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final updated = await widget.api.setDeviceBackup(
        id: widget.device.id,
        volume: volume,
        subfolder: subfolder,
        enabled: _enabled,
      );
      if (mounted) Navigator.pop(context, updated);
    } on CloudBoxException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selected = widget.volumes.where((v) => v.name == _volume).isEmpty
        ? null
        : widget.volumes.firstWhere((v) => v.name == _volume);
    return AlertDialog(
      title: Text('Backup for ${widget.device.name}'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Files from this phone will be stored under the folder below. Other devices keep their own folders.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            if (widget.volumes.isEmpty)
              Text('No drives are available. Start the agent and try again.', style: TextStyle(color: theme.colorScheme.error))
            else
              DropdownButtonFormField<String>(
                initialValue: _volume,
                decoration: const InputDecoration(
                  labelText: 'Drive',
                  prefixIcon: Icon(Icons.storage_outlined),
                  border: OutlineInputBorder(),
                ),
                items: [
                  for (final volume in widget.volumes)
                    DropdownMenuItem<String>(
                      value: volume.name,
                      child: Text(volume.displayName),
                    ),
                ],
                onChanged: _saving ? null : (value) => setState(() => _volume = value),
              ),
            const SizedBox(height: 12),
            TextField(
              controller: _subfolder,
              enabled: !_saving,
              decoration: const InputDecoration(
                labelText: 'Folder on the drive',
                hintText: 'CloudBox/My phone',
                prefixIcon: Icon(Icons.create_new_folder_outlined),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            SwitchListTile(
              value: _enabled,
              onChanged: _saving ? null : (value) => setState(() => _enabled = value),
              title: const Text('Use this folder for backups'),
              subtitle: const Text('Turn off to keep using the global Storage setting.'),
            ),
            if (selected != null) ...[
              const SizedBox(height: 4),
              Text('Resolved path: ${selected.path}${_subfolder.text}', style: theme.textTheme.bodySmall),
            ],
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: _saving ? null : () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton.icon(
          onPressed: _volume == null || _subfolder.text.trim().isEmpty || _saving ? null : _save,
          icon: _saving
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.save_outlined),
          label: const Text('Save'),
        ),
      ],
    );
  }
}

import 'package:flutter/material.dart';

import '../../core/local_api.dart';
import '../../core/models.dart';

/// Chooses which drive and folder receive the phone's backups.
class StorageScreen extends StatefulWidget {
  const StorageScreen({
    super.key,
    required this.api,
    required this.current,
    required this.onChanged,
  });

  final LocalAgentApi api;
  final DestinationInfo? current;
  final Future<void> Function() onChanged;

  @override
  State<StorageScreen> createState() => _StorageScreenState();
}

class _StorageScreenState extends State<StorageScreen> {
  final _subfolderController = TextEditingController(text: 'CloudBox');
  List<VolumeInfo> _volumes = const [];
  String? _selectedVolume;
  String? _loadError;
  String? _saveError;
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _applyCurrent();
    _load();
  }

  @override
  void dispose() {
    _subfolderController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(StorageScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.current != oldWidget.current && _selectedVolume == null) {
      _applyCurrent();
    }
  }

  void _applyCurrent() {
    final current = widget.current;
    if (current == null) return;
    _selectedVolume = current.volume.isEmpty ? null : current.volume;
    if (current.subfolder.isNotEmpty) {
      _subfolderController.text = current.subfolder;
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final volumes = await widget.api.volumes();
      if (!mounted) return;
      setState(() {
        _volumes = volumes;
        if (_selectedVolume == null && volumes.isNotEmpty) {
          _selectedVolume = volumes.first.name;
        }
        _loading = false;
      });
    } on CloudBoxException catch (error) {
      if (!mounted) return;
      setState(() {
        _loadError = error.message;
        _loading = false;
      });
    }
  }

  Future<void> _save() async {
    final volume = _selectedVolume;
    final subfolder = _subfolderController.text.trim();
    if (volume == null || subfolder.isEmpty) return;

    setState(() {
      _saving = true;
      _saveError = null;
    });
    try {
      final folder = await widget.api.setDestination(volume: volume, subfolder: subfolder);
      await widget.onChanged();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Backups will be saved to ${folder.root}')),
      );
    } on CloudBoxException catch (error) {
      if (!mounted) return;
      setState(() => _saveError = error.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final current = widget.current;
    final selected = _volumes.where((v) => v.name == _selectedVolume).isEmpty
        ? null
        : _volumes.firstWhere((v) => v.name == _selectedVolume);
    final canSave = _selectedVolume != null && _subfolderController.text.trim().isNotEmpty && !_saving;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(28, 24, 28, 40),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Cloud storage', style: theme.textTheme.headlineSmall),
          const SizedBox(height: 4),
          Text(
            'Choose the drive where this PC keeps your phone backups.',
            style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 24),
          Card(
            color: theme.colorScheme.primaryContainer.withValues(alpha: 0.45),
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Row(
                children: [
                  Icon(Icons.folder_shared_outlined, color: theme.colorScheme.primary),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Current backup location', style: theme.textTheme.labelLarge),
                        const SizedBox(height: 4),
                        Text(
                          current == null || current.root.isEmpty ? 'Default location on this PC' : current.root,
                          style: theme.textTheme.bodyMedium,
                        ),
                        if (current != null && current.subfolder.isNotEmpty)
                          Text('Folder: ${current.subfolder}', style: theme.textTheme.bodySmall),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
          Row(
            children: [
              Text('Available drives', style: theme.textTheme.titleMedium),
              const Spacer(),
              IconButton(
                tooltip: 'Refresh drives',
                onPressed: _loading ? null : _load,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (_loading)
            const Padding(
              padding: EdgeInsets.all(40),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_loadError != null)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Row(children: [
                  Icon(Icons.error_outline, color: theme.colorScheme.error),
                  const SizedBox(width: 12),
                  Expanded(child: Text(_loadError!)),
                  TextButton(onPressed: _load, child: const Text('Retry')),
                ]),
              ),
            )
          else if (_volumes.isEmpty)
            const Card(child: Padding(padding: EdgeInsets.all(32), child: Center(child: Text('No drives were found on this PC.'))))
          else
            Card(
              child: RadioGroup<String>(
                groupValue: _selectedVolume,
                onChanged: (value) {
                  if (_saving || value == null) return;
                  setState(() => _selectedVolume = value);
                },
                child: Column(
                  children: [
                    for (final volume in _volumes)
                      RadioListTile<String>(
                        value: volume.name,
                        title: Text(volume.displayName),
                        subtitle: Text(volume.freeText),
                        secondary: _VolumeIcon(volume: volume),
                      ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 20),
          if (selected != null && selected.hasFatLimit)
            _Notice(
              icon: Icons.warning_amber_outlined,
              color: theme.colorScheme.errorContainer,
              text: '${selected.fsType} cannot store a single file larger than 4 GB. Use an NTFS or exFAT drive for large videos.',
            ),
          if (selected != null && selected.removable)
            _Notice(
              icon: Icons.usb_outlined,
              color: theme.colorScheme.tertiaryContainer,
              text: 'This is a removable drive. Backups will pause if it is unplugged.',
            ),
          const SizedBox(height: 20),
          TextField(
            controller: _subfolderController,
            enabled: !_saving,
            decoration: const InputDecoration(
              labelText: 'Folder on the drive',
              hintText: 'CloudBox',
              helperText: 'Created automatically. Use a short name without special characters.',
              prefixIcon: Icon(Icons.create_new_folder_outlined),
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          if (_saveError != null)
            _Notice(icon: Icons.error_outline, color: theme.colorScheme.errorContainer, text: _saveError!),
          const SizedBox(height: 4),
          FilledButton.icon(
            onPressed: canSave ? _save : null,
            icon: _saving
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.save_outlined),
            label: const Text('Use this drive'),
          ),
        ],
      ),
    );
  }
}

class _VolumeIcon extends StatelessWidget {
  const _VolumeIcon({required this.volume});

  final VolumeInfo volume;

  @override
  Widget build(BuildContext context) {
    IconData icon = Icons.storage_outlined;
    if (volume.removable) icon = Icons.usb_outlined;
    if (volume.network) icon = Icons.cloud_queue_outlined;
    return Icon(icon);
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.icon, required this.color, required this.text});

  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) {
    final onColor = Theme.of(context).colorScheme.onSurface;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(8)),
      child: Row(children: [
        Icon(icon, size: 18),
        const SizedBox(width: 10),
        Expanded(child: Text(text, style: TextStyle(color: onColor))),
      ]),
    );
  }
}

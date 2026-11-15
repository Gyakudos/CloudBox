import 'package:flutter/material.dart';

import '../core/agent_client.dart';
import '../core/models.dart';
import '../core/pairing_flow.dart';
import 'send_screen.dart';

/// After pairing: pick which drive on the PC should receive backups.
///
/// Choosing a drive is not cosmetic — it tells the PC which volume to root the sync folder on,
/// then hands off to [SendScreen] to pick and transfer files.
class DrivesScreen extends StatefulWidget {
  const DrivesScreen({super.key, required this.outcome});

  final PairingOutcome outcome;

  @override
  State<DrivesScreen> createState() => _DrivesScreenState();
}

class _DrivesScreenState extends State<DrivesScreen> {
  bool _loading = true;
  String? _error;
  List<CloudBoxDrive> _drives = const [];

  /// The volume name currently being resolved into a destination, if any.
  String? _choosingDrive;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    widget.outcome.client.close();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final drives = await widget.outcome.client.drives();
      if (!mounted) return;
      setState(() {
        _drives = drives;
        _loading = false;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error is Exception ? error.toString() : 'Could not load drives.';
        _loading = false;
      });
    }
  }

  void _onDriveSelected(CloudBoxDrive drive) {
    if (_choosingDrive != null) return;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => _DriveSheet(
        drive: drive,
        onChoose: () {
          Navigator.of(sheetContext).pop();
          _chooseDrive(drive);
        },
      ),
    );
  }

  /// Tells the PC to root backups on [drive], then opens the send screen for the folder it
  /// resolved. The PC answers with the folder it actually created, so the send screen can show
  /// the real destination rather than assuming one.
  Future<void> _chooseDrive(CloudBoxDrive drive) async {
    setState(() => _choosingDrive = drive.name);
    try {
      final folder = await widget.outcome.client.setDestination(volume: drive.name);
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => SendScreen(outcome: widget.outcome, folder: folder),
        ),
      );
    } on CloudBoxException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.message)));
    } on Object catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not use that drive: $error')),
      );
    } finally {
      if (mounted) setState(() => _choosingDrive = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.outcome.info.serverName),
        actions: [
          IconButton(
            tooltip: 'Refresh drives',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          children: [
            if (_choosingDrive != null) ...[
              const LinearProgressIndicator(),
              const SizedBox(height: 12),
            ],
            _ConnectionCard(outcome: widget.outcome),
            const SizedBox(height: 20),
            Text('Choose a drive', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'Backups will be written into the CloudBox folder on the drive you pick.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 12),
            ..._body(),
          ],
        ),
      ),
    );
  }

  List<Widget> _body() {
    if (_loading) {
      return const [
        Padding(
          padding: EdgeInsets.symmetric(vertical: 48),
          child: Center(child: CircularProgressIndicator()),
        ),
      ];
    }
    if (_error != null) {
      return [
        _MessageCard(
          icon: Icons.wifi_off,
          message: _error!,
          actionLabel: 'Try again',
          onAction: _load,
        ),
      ];
    }
    if (_drives.isEmpty) {
      return const [
        _MessageCard(
          icon: Icons.storage,
          message: 'The PC reported no writable drives.',
        ),
      ];
    }
    return [
      for (final drive in _drives)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: _DriveCard(
            drive: drive,
            onTap: _choosingDrive == null ? () => _onDriveSelected(drive) : null,
          ),
        ),
    ];
  }
}

class _ConnectionCard extends StatelessWidget {
  const _ConnectionCard({required this.outcome});

  final PairingOutcome outcome;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final info = outcome.info;
    return Card(
      color: scheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.verified_user, color: scheme.onPrimaryContainer),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Paired securely',
                    style: TextStyle(fontWeight: FontWeight.w600, color: scheme.onPrimaryContainer),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Certificate pin matched. Connected to ${info.serverName} '
                    '(agent ${info.version}, ${info.platform}).',
                    style: TextStyle(color: scheme.onPrimaryContainer),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'This phone: ${info.device.name}',
                    style: TextStyle(color: scheme.onPrimaryContainer.withValues(alpha: 0.8)),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DriveCard extends StatelessWidget {
  const _DriveCard({required this.drive, required this.onTap});

  final CloudBoxDrive drive;
  final VoidCallback? onTap;

  IconData get _icon {
    if (drive.network) return Icons.cloud_outlined;
    if (drive.removable) return Icons.usb;
    return Icons.storage;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(_icon, color: scheme.primary),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(drive.displayName, style: Theme.of(context).textTheme.titleMedium),
                        Text(
                          '${drive.path} · ${drive.fsType}',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                        ),
                      ],
                    ),
                  ),
                  const Icon(Icons.chevron_right),
                ],
              ),
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: drive.usedFraction.clamp(0, 1),
                  minHeight: 6,
                  backgroundColor: scheme.surfaceContainerHighest,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                drive.capacitySummary,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
              if (drive.removable || drive.network) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    if (drive.removable) const Chip(label: Text('Removable'), visualDensity: VisualDensity.compact),
                    if (drive.network) const Chip(label: Text('Network'), visualDensity: VisualDensity.compact),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _DriveSheet extends StatelessWidget {
  const _DriveSheet({required this.drive, required this.onChoose});

  final CloudBoxDrive drive;
  final VoidCallback onChoose;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(drive.displayName, style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 12),
          _DetailRow(label: 'Path', value: drive.path),
          _DetailRow(label: 'Filesystem', value: drive.fsType),
          _DetailRow(label: 'Free', value: formatBytes(drive.freeBytes)),
          _DetailRow(label: 'Total', value: formatBytes(drive.totalBytes)),
          _DetailRow(label: 'Type', value: drive.network ? 'Network' : (drive.removable ? 'Removable' : 'Fixed')),
          const SizedBox(height: 12),
          Text(
            'Backups will be written into the CloudBox folder on this drive. You can change the '
            'drive at any time; files already sent stay where they are.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: onChoose,
              icon: const Icon(Icons.arrow_forward),
              label: Text('Use ${drive.displayName}'),
              style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
            ),
          ),
        ],
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96,
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}

class _MessageCard extends StatelessWidget {
  const _MessageCard({
    required this.icon,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            Icon(icon, size: 40, color: Theme.of(context).colorScheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            if (actionLabel != null) ...[
              const SizedBox(height: 16),
              OutlinedButton(onPressed: onAction, child: Text(actionLabel!)),
            ],
          ],
        ),
      ),
    );
  }
}

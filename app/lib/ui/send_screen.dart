import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../core/folder_picker.dart';
import '../core/models.dart';
import '../core/pairing_flow.dart';
import '../core/transfer.dart';

/// Choose files and send them to the destination configured on the paired PC.
///
/// The transfer itself lives in [TransferController]; this screen only turns taps into calls and
/// renders the progress it reports. There is no drive picker: the PC app's Storage screen owns
/// that choice, and the agent told us the resulting folder during pairing.
class SendScreen extends StatefulWidget {
  const SendScreen({super.key, required this.outcome});

  final PairingOutcome outcome;

  @override
  State<SendScreen> createState() => _SendScreenState();
}

class _SendScreenState extends State<SendScreen> {
  late final TransferController _controller;
  late final CloudBoxFolder _folder;
  bool _picking = false;
  bool _folderMode = false;

  @override
  void initState() {
    super.initState();
    _folder = widget.outcome.destinationFolder;
    _controller = TransferController(
      api: widget.outcome.client,
      folderId: _folder.id,
    );
  }

  @override
  void dispose() {
    // Staged folder copies are only needed while their items are queued. Never clear them during
    // a transfer: the reader may still be working through them.
    if (!_controller.running) {
      FolderPicker.clearCache();
    }
    _controller.dispose();
    // The drive screen used to own the client's lifetime; it no longer exists.
    widget.outcome.client.close();
    super.dispose();
  }

  Future<void> _pickFiles() async {
    setState(() => _picking = true);
    try {
      if (_folderMode) {
        final files = await FolderPicker.pickFolder();
        if (!mounted || files == null) return;
        if (files.isEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('That folder has no files to send.')),
          );
          return;
        }
        _controller.addFiles(sourceFilesFromFolder(files));
        return;
      }
      final files = await FilePicker.pickFiles(dialogTitle: 'Choose files to back up');
      if (!mounted) return;
      _controller.addFiles(files.map(_toSourceFile));
    } on Object catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not open the picker: $error')),
      );
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  SourceFile _toSourceFile(PlatformFile file) => SourceFile(
        name: file.name,
        size: file.lengthSync(),
        // Let the engine hash on a background isolate instead of freezing the UI.
        path: file.path,
        // Re-openable: the engine hashes, uploads, and may re-read after a resume.
        openRead: file.readAsByteStream,
      );

  Future<void> _send() async {
    await _controller.run();
    if (!mounted) return;

    final done = _controller.items.where((i) => i.state == TransferState.done).length;
    final failed = _controller.items.where((i) => i.state == TransferState.failed).length;
    final message = switch ((done, failed)) {
      (_, 0) => 'Sent $done ${done == 1 ? 'file' : 'files'} to ${_folder.name}.',
      (0, _) => 'Nothing was sent. Tap Send to try again.',
      _ => 'Sent $done, $failed failed. Tap Send to retry the rest.',
    };
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Send files'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(20),
          child: Padding(
            padding: const EdgeInsets.only(left: 16, right: 16, bottom: 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Into ${_folder.root.isEmpty ? 'the PC backup folder' : _folder.root} on ${widget.outcome.info.serverName}',
                style: Theme.of(context).textTheme.bodySmall,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ),
      ),
      body: ListenableBuilder(
        listenable: _controller,
        builder: (context, _) {
          if (_controller.items.isEmpty) {
            return _EmptyState(
              onPick: _picking ? null : _pickFiles,
              folderMode: _folderMode,
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: _controller.items.length,
            separatorBuilder: (_, _) => const SizedBox(height: 12),
            itemBuilder: (context, index) {
              final item = _controller.items[index];
              return _TransferTile(
                item: item,
                onRemove: _controller.running ? null : () => _controller.removeAt(index),
              );
            },
          );
        },
      ),
      bottomNavigationBar: ListenableBuilder(
        listenable: _controller,
        builder: (context, _) {
          final running = _controller.running;
          final locked = running || _picking;
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Checkbox(
                        value: _folderMode,
                        onChanged: locked
                            ? null
                            : (value) => setState(() => _folderMode = value ?? false),
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          'Upload a whole folder (keeps subfolders)',
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: locked ? null : _pickFiles,
                          icon: const Icon(Icons.add),
                          label: Text(_folderMode ? 'Add folder' : 'Add files'),
                          style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: running
                            ? FilledButton.tonalIcon(
                                onPressed: _controller.cancel,
                                icon: const Icon(Icons.stop),
                                label: const Text('Stop'),
                                style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
                              )
                            : FilledButton.icon(
                                onPressed: _controller.items.isEmpty ? null : _send,
                                icon: const Icon(Icons.cloud_upload),
                                label: const Text('Send'),
                                style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
                              ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onPick, required this.folderMode});

  final VoidCallback? onPick;
  final bool folderMode;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_upload_outlined, size: 64, color: scheme.primary),
            const SizedBox(height: 16),
            Text('Nothing queued yet', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              folderMode
                  ? 'Pick a folder to send everything inside it. Subfolders are kept on your PC, '
                      'under the folder’s own name.'
                  : 'Pick photos, videos or any other files from this phone. They are hashed here, '
                      'then sent straight to your PC — nothing goes through a server we control.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: onPick,
              icon: const Icon(Icons.folder_open),
              label: Text(folderMode ? 'Choose folder' : 'Choose files'),
            ),
          ],
        ),
      ),
    );
  }
}

class _TransferTile extends StatelessWidget {
  const _TransferTile({required this.item, required this.onRemove});

  final TransferItem item;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (icon, tint) = _statusVisual(item, scheme);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: tint),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(item.source.name, overflow: TextOverflow.ellipsis),
                ),
                if (onRemove != null)
                  IconButton(
                    tooltip: 'Remove',
                    onPressed: onRemove,
                    icon: const Icon(Icons.close),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                // Unknown size (or a hash still in flight) is honest as indeterminate rather
                // than a bar pinned at zero, which looks like a frozen transfer.
                value: item.total <= 0 && item.state == TransferState.hashing
                    ? null
                    : item.state == TransferState.queued
                        ? 0
                        : item.progress,
                minHeight: 6,
                backgroundColor: scheme.surfaceContainerHighest,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              _statusText(item),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: item.state == TransferState.failed ? scheme.error : scheme.onSurfaceVariant,
                  ),
            ),
          ],
        ),
      ),
    );
  }

  static (IconData, Color) _statusVisual(TransferItem item, ColorScheme scheme) {
    switch (item.state) {
      case TransferState.done:
        return (Icons.check_circle, scheme.primary);
      case TransferState.failed:
        return (Icons.error_outline, scheme.error);
      case TransferState.canceled:
        return (Icons.cancel_outlined, scheme.onSurfaceVariant);
      case TransferState.queued:
        return (Icons.schedule, scheme.onSurfaceVariant);
      case TransferState.hashing:
      case TransferState.uploading:
      case TransferState.committing:
        return (Icons.sync, scheme.primary);
    }
  }

  static String _statusText(TransferItem item) {
    final size = item.total > 0 ? formatBytes(item.total) : (item.source.size != null ? formatBytes(item.source.size!) : '');
    switch (item.state) {
      case TransferState.queued:
        return size.isEmpty ? 'Waiting' : 'Waiting · $size';
      case TransferState.hashing:
        return 'Checking ${formatBytes(item.hashed)}${size.isEmpty ? '' : ' of $size'}';
      case TransferState.uploading:
        return 'Sending ${formatBytes(item.uploaded)} of $size';
      case TransferState.committing:
        return 'Finishing on the PC…';
      case TransferState.done:
        final how = item.deduped ? 'Already on the PC' : 'Sent';
        return item.remotePath == null ? how : '$how · ${item.remotePath}';
      case TransferState.failed:
        return item.error ?? 'Failed';
      case TransferState.canceled:
        return 'Stopped';
    }
  }
}

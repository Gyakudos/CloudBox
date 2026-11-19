import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/models.dart';

/// Shows the live pairing code and the QR the phone scans.
class PairingScreen extends StatefulWidget {
  const PairingScreen({
    super.key,
    required this.state,
    required this.error,
    required this.refreshing,
    required this.onRefresh,
  });

  final LocalState? state;
  final String? error;
  final bool refreshing;
  final VoidCallback onRefresh;

  @override
  State<PairingScreen> createState() => _PairingScreenState();
}

class _PairingScreenState extends State<PairingScreen> {
  DateTime _now = DateTime.now();
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    if (state == null) {
      return Center(
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.link_off, size: 48),
                const SizedBox(height: 16),
                Text(
                  widget.error ?? 'Looking for the CloudBox agent…',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: widget.onRefresh,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Try again'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(28, 24, 28, 40),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Pair your phone', style: theme.textTheme.headlineSmall),
          const SizedBox(height: 4),
          Text(
            'Scan this code in the CloudBox app to connect your phone to ${state.serverName}.',
            style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 24),
          if (widget.error != null) _WarningBanner(message: widget.error!),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _QrImage(data: state.qrPngBase64),
                  const SizedBox(width: 28),
                  Expanded(child: _PairingDetails(state: state, now: _now, refreshing: widget.refreshing, onRefresh: widget.onRefresh)),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Icon(Icons.info_outline, size: 18, color: theme.colorScheme.primary),
                    const SizedBox(width: 8),
                    Text('How pairing works', style: theme.textTheme.titleSmall),
                  ]),
                  const SizedBox(height: 12),
                  const _Step(number: '1', text: 'Open CloudBox on your phone and choose Add a PC.'),
                  const SizedBox(height: 8),
                  const _Step(number: '2', text: 'Scan the QR code above, or type the pairing code.'),
                  const SizedBox(height: 8),
                  const _Step(number: '3', text: 'The code is single-use and expires after a few minutes.'),
                  const SizedBox(height: 8),
                  const _Step(number: '4', text: 'Pick the backup drive on the Storage tab.'),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _QrImage extends StatefulWidget {
  const _QrImage({required this.data});

  final String data;

  @override
  State<_QrImage> createState() => _QrImageState();
}

class _QrImageState extends State<_QrImage> {
  // The parent rebuilds every second for the countdown and every few seconds for status polls.
  // Decoding the PNG on each of those builds produced a fresh Uint8List, and therefore a fresh
  // MemoryImage cache key, which made Flutter briefly show an empty frame. Keep one provider and
  // replace it only when the agent actually issues a new code.
  MemoryImage? _image;

  @override
  void initState() {
    super.initState();
    _decode();
  }

  @override
  void didUpdateWidget(_QrImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.data != oldWidget.data) {
      _decode();
    }
  }

  void _decode() {
    if (widget.data.isEmpty) {
      _image = null;
      return;
    }
    try {
      _image = MemoryImage(Uint8List.fromList(base64.decode(widget.data)));
    } on FormatException {
      _image = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    final content = image == null
        ? const Icon(Icons.qr_code_2, size: 96)
        : Image(image: image, width: 248, height: 248, fit: BoxFit.contain);
    return Container(
      width: 272,
      height: 272,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Theme.of(context).dividerColor),
      ),
      child: Center(child: content),
    );
  }
}

class _PairingDetails extends StatelessWidget {
  const _PairingDetails({
    required this.state,
    required this.now,
    required this.refreshing,
    required this.onRefresh,
  });

  final LocalState state;
  final DateTime now;
  final bool refreshing;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pairing = state.pairing;
    final expired = pairing.expiresAt.isBefore(now);
    final waiting = pairing.active && !expired;
    final remaining = pairing.expiresAt.difference(now);
    final countdown = remaining.isNegative
        ? 'Expired'
        : '${remaining.inMinutes.toString().padLeft(2, '0')}:${(remaining.inSeconds % 60).toString().padLeft(2, '0')}';

    final chipColor = waiting
        ? theme.colorScheme.primaryContainer
        : expired
            ? theme.colorScheme.errorContainer
            : theme.colorScheme.tertiaryContainer;
    final chipText = waiting ? 'Waiting for phone' : expired ? 'Code expired' : 'Phone paired';
    final chipForeground = waiting
        ? theme.colorScheme.onPrimaryContainer
        : expired
            ? theme.colorScheme.onErrorContainer
            : theme.colorScheme.onTertiaryContainer;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(color: chipColor, borderRadius: BorderRadius.circular(100)),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(waiting ? Icons.schedule : expired ? Icons.error_outline : Icons.check_circle_outline, size: 16, color: chipForeground),
              const SizedBox(width: 6),
              Text(chipText, style: theme.textTheme.labelLarge?.copyWith(color: chipForeground)),
            ],
          ),
        ),
        const SizedBox(height: 20),
        Text('PAIRING CODE', style: theme.textTheme.labelSmall?.copyWith(letterSpacing: 1.2)),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SelectableText(
                  pairing.token.isEmpty ? '—' : pairing.token,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 15),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              tooltip: 'Copy pairing code',
              onPressed: pairing.token.isEmpty
                  ? null
                  : () => Clipboard.setData(ClipboardData(text: pairing.token)),
              icon: const Icon(Icons.copy),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(children: [
          Icon(Icons.timer_outlined, size: 16, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Text('Expires in $countdown', style: theme.textTheme.bodyMedium),
        ]),
        const SizedBox(height: 20),
        FilledButton.icon(
          onPressed: refreshing ? null : onRefresh,
          icon: refreshing
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.autorenew),
          label: const Text('Show a new code'),
        ),
        const SizedBox(height: 20),
        const Divider(),
        const SizedBox(height: 12),
        _DetailRow(label: 'PC', value: state.serverName),
        const SizedBox(height: 6),
        _DetailRow(label: 'Server ID', value: state.serverId.isEmpty ? '—' : state.serverId.substring(0, state.serverId.length.clamp(0, 12))),
        const SizedBox(height: 6),
        _DetailRow(label: 'Agent', value: state.version.isEmpty ? '—' : state.version),
      ],
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        SizedBox(width: 84, child: Text(label, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant))),
        Expanded(child: Text(value, style: theme.textTheme.bodyMedium)),
      ],
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.number, required this.text});

  final String number;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CircleAvatar(radius: 12, child: Text(number, style: const TextStyle(fontSize: 12))),
        const SizedBox(width: 10),
        Expanded(child: Text(text)),
      ],
    );
  }
}

class _WarningBanner extends StatelessWidget {
  const _WarningBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(children: [
        Icon(Icons.cloud_off, size: 18, color: theme.colorScheme.onErrorContainer),
        const SizedBox(width: 10),
        Expanded(child: Text(message, style: TextStyle(color: theme.colorScheme.onErrorContainer))),
      ]),
    );
  }
}

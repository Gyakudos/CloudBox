import 'package:flutter/material.dart';

import '../../core/models.dart';

/// The agent's own surface, shown inside the desktop app so a single desktop shortcut is enough.
///
/// Status comes from the same /local/status data as the Pairing tab; the log lines are a bounded
/// in-memory tail from the agent, so nothing has to open a second console window.
class AgentScreen extends StatelessWidget {
  const AgentScreen({
    super.key,
    required this.state,
    required this.logs,
    required this.error,
    required this.starting,
    required this.onStart,
  });

  final LocalState? state;
  final List<String> logs;
  final String? error;
  final bool starting;
  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final running = state != null;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(28, 24, 28, 40),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Agent service', style: theme.textTheme.headlineSmall),
          const SizedBox(height: 4),
          Text(
            'CloudBox starts the agent when this app opens. It keeps running after you close the '
            'window, so phones can still back up.',
            style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 24),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: _Notice(message: error!, isError: true),
            ),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        running ? Icons.check_circle : Icons.cloud_off,
                        color: running ? theme.colorScheme.primary : theme.colorScheme.error,
                      ),
                      const SizedBox(width: 10),
                      Text(
                        starting ? 'Starting agent…' : running ? 'Running' : 'Not running',
                        style: theme.textTheme.titleMedium,
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  if (running) ...[
                    _Detail(label: 'Server', value: state!.serverName),
                    _Detail(label: 'Version', value: state!.version),
                    if (state!.startedAt != null)
                      _Detail(label: 'Started', value: state!.startedAt!.toLocal().toString().split('.').first),
                    _Detail(
                      label: 'Listening on',
                      value: state!.endpoints.isNotEmpty ? state!.endpoints.join(', ') : '—',
                    ),
                  ] else if (!starting)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: FilledButton.icon(
                        onPressed: onStart,
                        icon: const Icon(Icons.play_arrow),
                        label: const Text('Start agent'),
                      ),
                    ),
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
                    Icon(Icons.terminal, size: 18, color: theme.colorScheme.primary),
                    const SizedBox(width: 8),
                    Text('Recent agent activity', style: theme.textTheme.titleSmall),
                  ]),
                  const SizedBox(height: 12),
                  Container(
                    constraints: const BoxConstraints(minHeight: 180, maxHeight: 360),
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerLow,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: SingleChildScrollView(
                      child: SelectableText(
                        logs.isEmpty ? 'No activity yet.' : logs.join('\n'),
                        style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'Consolas'),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'This is the same output shown by the CloudBox Agent console shortcut.',
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Detail extends StatelessWidget {
  const _Detail({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 96, child: Text(label, style: Theme.of(context).textTheme.bodySmall)),
          Expanded(child: Text(value, style: Theme.of(context).textTheme.bodyMedium)),
        ],
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.message, required this.isError});

  final String message;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = isError ? theme.colorScheme.errorContainer : theme.colorScheme.primaryContainer;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(8)),
      child: Text(message),
    );
  }
}

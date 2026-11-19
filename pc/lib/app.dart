import 'dart:async';

import 'package:flutter/material.dart';

import 'core/agent_launcher.dart';
import 'core/config.dart';
import 'core/gen/version.dart';
import 'core/local_api.dart';
import 'core/models.dart';
import 'features/agent/agent_screen.dart';
import 'features/backups/backups_screen.dart';
import 'features/devices/paired_devices_screen.dart';
import 'features/pairing/pairing_screen.dart';
import 'features/storage/storage_screen.dart';
import 'ui/update_button.dart';

class CloudBoxPcApp extends StatelessWidget {
  const CloudBoxPcApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CloudBox PC',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1565C0)),
      ),
      home: const CloudBoxHome(),
    );
  }
}

class CloudBoxHome extends StatefulWidget {
  const CloudBoxHome({super.key});

  @override
  State<CloudBoxHome> createState() => _CloudBoxHomeState();
}

class _CloudBoxHomeState extends State<CloudBoxHome> {
  LocalAgentApi? _api;
  LocalState? _state;
  List<VolumeInfo> _volumes = const [];
  List<String> _logs = const [];
  String? _configError;
  String? _pollError;
  bool _initializing = true;
  bool _refreshing = false;
  bool _polling = false;
  int _selected = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _connect();
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => _poll());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _api?.close();
    super.dispose();
  }

  /// Starts the agent if needed, then binds the app to a live local endpoint.
  Future<void> _connect() async {
    if (mounted) {
      setState(() {
        _initializing = true;
        _configError = null;
      });
    }
    try {
      final config = await ensureLocalAgent();
      if (config == null) {
        throw const ConfigException(
          'Could not start the CloudBox agent. Open CloudBox Agent from the Start Menu to see why it failed.',
        );
      }
      _api?.close();
      final api = PinnedLocalAgentApi(config);
      _api = api;
      await Future.wait([_poll(), _loadVolumes(), _loadLogs()]);
    } on ConfigException catch (error) {
      if (mounted) setState(() => _configError = error.message);
    } finally {
      if (mounted) setState(() => _initializing = false);
    }
  }

  /// Polls the agent silently. A transient failure keeps the last good state on screen so the
  /// QR does not blank out while the agent is busy.
  Future<void> _poll() async {
    final api = _api;
    if (api == null || _polling) return;
    _polling = true;
    try {
      final state = await api.status();
      List<String>? logs;
      try {
        logs = await api.logs();
      } on Object {
        // A failed log fetch must not blank out the status the app already has.
      }
      if (!mounted) return;
      setState(() {
        _state = state;
        _pollError = null;
        if (logs != null) _logs = logs;
      });
    } on CloudBoxException catch (error) {
      if (!mounted) return;
      setState(() => _pollError = error.message);
    } finally {
      _polling = false;
    }
  }

  /// Volumes only change when the user swaps a drive, so load them once per connection rather
  /// than on every three-second status poll.
  Future<void> _loadVolumes() async {
    final api = _api;
    if (api == null) return;
    try {
      final volumes = await api.volumes();
      if (!mounted) return;
      setState(() => _volumes = volumes);
    } on Object {
      // The status poll shows connectivity problems; keep whatever drive list we last had.
    }
  }

  /// Mint a fresh code and switch to the Pairing tab so a second phone can be added.
  Future<void> _addDevice() async {
    final api = _api;
    if (api == null) {
      setState(() {
        _initializing = true;
        _selected = 0;
      });
      await _connect();
      return;
    }
    setState(() => _refreshing = true);
    try {
      final state = await api.refreshPairing();
      if (!mounted) return;
      setState(() {
        _state = state;
        _pollError = null;
        _selected = 0;
      });
    } on CloudBoxException catch (error) {
      if (!mounted) return;
      setState(() => _pollError = error.message);
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  Future<void> _loadLogs() async {
    final api = _api;
    if (api == null) return;
    try {
      final logs = await api.logs();
      if (mounted) setState(() => _logs = logs);
    } on Object {
      // The status poll surfaces connectivity problems; keep whatever log tail we last had.
    }
  }

  /// Explicit retry from the UI: mint a fresh code so a used or expired one never leaves the
  /// user staring at a dead QR.
  Future<void> _retry() async {
    final api = _api;
    if (api == null) {
      setState(() => _initializing = true);
      await _connect();
      return;
    }
    setState(() => _refreshing = true);
    try {
      final state = await api.refreshPairing();
      if (!mounted) return;
      setState(() {
        _state = state;
        _pollError = null;
      });
    } on CloudBoxException catch (error) {
      if (!mounted) return;
      setState(() => _pollError = error.message);
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Row(
        children: [
          NavigationRail(
            selectedIndex: _selected,
            onDestinationSelected: (index) => setState(() => _selected = index),
            labelType: NavigationRailLabelType.all,
            leading: Padding(
              padding: const EdgeInsets.only(bottom: 20),
              child: Icon(Icons.cloud_done, color: theme.colorScheme.primary, size: 32),
            ),
            trailing: Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Text('v${kCloudBoxVersion.split(".").take(3).join(".")}', style: theme.textTheme.bodySmall),
            ),
            destinations: const [
              NavigationRailDestination(icon: Icon(Icons.qr_code_2_outlined), selectedIcon: Icon(Icons.qr_code_2), label: Text('Pairing')),
              NavigationRailDestination(icon: Icon(Icons.storage_outlined), selectedIcon: Icon(Icons.storage), label: Text('Storage')),
              NavigationRailDestination(icon: Icon(Icons.devices_other_outlined), selectedIcon: Icon(Icons.devices_other), label: Text('Paired Devices')),
              NavigationRailDestination(icon: Icon(Icons.backup_outlined), selectedIcon: Icon(Icons.backup), label: Text('Backups')),
              NavigationRailDestination(icon: Icon(Icons.terminal_outlined), selectedIcon: Icon(Icons.terminal), label: Text('Agent')),
            ],
          ),
          const VerticalDivider(width: 1),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  height: 56,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 28),
                    child: Row(
                      children: [
                        Text('CloudBox PC', style: theme.textTheme.titleMedium),
                        const SizedBox(width: 16),
                        _ConnectionChip(error: _configError ?? _pollError),
                        const Spacer(),
                        const UpdateButton(platform: 'windows'),
                      ],
                    ),
                  ),
                ),
                const Divider(height: 1),
                Expanded(child: _body()),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _body() {
    // The Agent tab is useful even when the agent is down: it explains what happened and offers
    // a retry, so it must render before the generic "could not connect" body below.
    if (_selected == 4) {
      return AgentScreen(
        state: _state,
        logs: _logs,
        error: _configError ?? _pollError,
        starting: _initializing,
        onStart: _initializing ? () {} : _connect,
      );
    }
    if (_initializing) {
      return const Center(child: CircularProgressIndicator());
    }
    final api = _api;
    if (api == null) {
      return Center(
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.cloud_off, size: 48),
                const SizedBox(height: 16),
                Text(_configError ?? 'Could not connect to the agent.', textAlign: TextAlign.center),
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: _retry,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Try again'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    switch (_selected) {
      case 0:
        return PairingScreen(
          state: _state,
          error: _pollError,
          refreshing: _refreshing,
          onRefresh: _retry,
        );
      case 1:
        return StorageScreen(
          api: api,
          current: _state?.destination,
          onChanged: _poll,
        );
      case 2:
        return PairedDevicesScreen(
          api: api,
          volumes: _volumes,
          onAddDevice: _addDevice,
        );
      default:
        return BackupsScreen(
          api: api,
          onConfigure: (_) => setState(() => _selected = 2),
        );
    }
  }
}

class _ConnectionChip extends StatelessWidget {
  const _ConnectionChip({required this.error});

  final String? error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final connected = error == null;
    final color = connected ? theme.colorScheme.primary : theme.colorScheme.error;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: connected ? theme.colorScheme.primaryContainer : theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(100),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(connected ? Icons.circle : Icons.cloud_off, size: 10, color: color),
          const SizedBox(width: 6),
          Text(
            connected ? 'Agent connected' : 'Agent offline',
            style: theme.textTheme.labelSmall?.copyWith(color: connected ? theme.colorScheme.onPrimaryContainer : theme.colorScheme.onErrorContainer),
          ),
        ],
      ),
    );
  }
}

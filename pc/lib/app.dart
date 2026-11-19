import 'dart:async';

import 'package:flutter/material.dart';

import 'core/config.dart';
import 'core/gen/version.dart';
import 'core/local_api.dart';
import 'core/models.dart';
import 'features/pairing/pairing_screen.dart';
import 'features/storage/storage_screen.dart';

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

  Future<void> _connect() async {
    try {
      final config = readAgentConfig();
      _api = PinnedLocalAgentApi(config);
      await _poll();
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
      if (!mounted) return;
      setState(() {
        _state = state;
        _pollError = null;
      });
    } on CloudBoxException catch (error) {
      if (!mounted) return;
      setState(() => _pollError = error.message);
    } finally {
      _polling = false;
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

    if (_selected == 0) {
      return PairingScreen(
        state: _state,
        error: _pollError,
        refreshing: _refreshing,
        onRefresh: _retry,
      );
    }
    return StorageScreen(
      api: api,
      current: _state?.destination,
      onChanged: _poll,
    );
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

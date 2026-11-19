// Starts the Go agent on demand and waits until the PC app can talk to it.
//
// The installed layout is <app>\cloudbox.exe plus <app>\pc\cloudbox_pc.exe, so the same hidden
// launcher used at sign-in works when the app starts the agent itself. Development builds have no
// installer next to them; there we fall back to agent/dist/cloudbox.exe, or to the paths supplied
// through CLOUDBOX_AGENT_LAUNCHER / CLOUDBOX_AGENT_EXE.

import 'dart:async';
import 'dart:io';

import 'config.dart';
import 'local_api.dart';

/// Returns true when [config] belongs to a live agent.
typedef AgentStatusProbe = Future<bool> Function(AgentConfig config);

/// Makes sure a reachable agent is running and returns its handshake config.
///
/// This is intentionally idempotent: if the agent is already up (for example from the sign-in
/// task), nothing is started. Otherwise it launches the agent hidden and waits for a fresh
/// handshake and a successful status call, so the app never shows a stale QR from a dead process.
Future<AgentConfig?> ensureLocalAgent({
  AgentStatusProbe? probe,
  String? dataDirectory,
  Duration timeout = const Duration(seconds: 12),
}) async {
  final check = probe ?? _defaultProbe;
  final existing = await _liveConfig(check, dataDirectory);
  if (existing != null) return existing;

  if (!await startAgentHidden()) return null;

  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 250));
    final config = await _liveConfig(check, dataDirectory);
    if (config != null) return config;
  }
  return null;
}

Future<AgentConfig?> _liveConfig(AgentStatusProbe probe, String? dataDirectory) async {
  final AgentConfig config;
  try {
    config = readAgentConfig(dataDirectory: dataDirectory);
  } on ConfigException {
    return null;
  }
  return await probe(config) ? config : null;
}

Future<bool> _defaultProbe(AgentConfig config) async {
  final api = PinnedLocalAgentApi(config);
  try {
    await api.status();
    return true;
  } on Object {
    return false;
  } finally {
    api.close();
  }
}

/// Launches `cloudbox serve` without leaving a console window. The agent is detached: closing the
/// PC app does not stop it, so phones can keep backing up and the sign-in task can own it later.
Future<bool> startAgentHidden() async {
  final envLauncher = Platform.environment['CLOUDBOX_AGENT_LAUNCHER'];
  if (envLauncher != null && envLauncher.isNotEmpty && File(envLauncher).existsSync()) {
    return _spawn('wscript.exe', <String>['//nologo', envLauncher]);
  }

  final exeDir = _dirname(Platform.resolvedExecutable);
  final installDir = _dirname(exeDir);
  final searchDirs = <String>[
    installDir,
    exeDir,
    Directory.current.path,
    _dirname(Directory.current.path),
  ];

  for (final dir in searchDirs) {
    final vbs = _join(dir, 'cloudbox-autostart.vbs');
    if (File(vbs).existsSync()) {
      return _spawn('wscript.exe', <String>['//nologo', vbs]);
    }
  }

  final envExe = Platform.environment['CLOUDBOX_AGENT_EXE'];
  final candidates = <String>[
    if (envExe != null && envExe.isNotEmpty) envExe,
    for (final dir in searchDirs) _join(dir, 'cloudbox.exe'),
    for (final dir in searchDirs) _join(_join(_join(dir, 'agent'), 'dist'), 'cloudbox.exe'),
  ];
  for (final exe in candidates) {
    if (File(exe).existsSync()) {
      return _spawn(exe, const <String>['serve']);
    }
  }
  return false;
}

Future<bool> _spawn(String executable, List<String> args) async {
  try {
    await Process.start(executable, args, mode: ProcessStartMode.detached);
    return true;
  } on Object {
    return false;
  }
}

String _join(String base, String child) {
  final left = base.replaceAll(RegExp(r'[\\/]+$'), '');
  final right = child.replaceAll(RegExp(r'^[\\/]+'), '');
  return '$left${Platform.pathSeparator}$right';
}

String _dirname(String path) {
  final normalized = path.replaceAll(RegExp(r'[\\/]+$'), '');
  final separator = normalized.lastIndexOf(RegExp(r'[\\/]'));
  if (separator <= 0) return normalized;
  return normalized.substring(0, separator);
}

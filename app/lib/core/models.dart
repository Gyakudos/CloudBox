// Data types mirroring the agent's JSON API. Field names match the Go struct tags exactly,
// so a drift here is a protocol bug rather than a cosmetic one.

/// A PC the phone has paired with, as described by `POST /v1/pair`.
class PairingResult {
  const PairingResult({
    required this.deviceId,
    required this.deviceToken,
    required this.serverId,
    required this.serverName,
    required this.serverVersion,
  });

  final String deviceId;

  /// The bearer token the phone presents on every subsequent request. It is a secret; it is
  /// never logged and never leaves the device.
  final String deviceToken;

  final String serverId;
  final String serverName;
  final String serverVersion;

  factory PairingResult.fromJson(Map<String, dynamic> json) => PairingResult(
        deviceId: json['device_id'] as String? ?? '',
        deviceToken: json['device_token'] as String? ?? '',
        serverId: json['server_id'] as String? ?? '',
        serverName: json['server_name'] as String? ?? '',
        serverVersion: json['server_version'] as String? ?? '',
      );
}

/// This phone's registration as the PC sees it, nested in `GET /v1/system/info`.
class PairedDevice {
  const PairedDevice({
    required this.id,
    required this.name,
    required this.platform,
    required this.appVersion,
    this.createdAt,
  });

  final String id;
  final String name;
  final String platform;
  final String appVersion;
  final DateTime? createdAt;

  factory PairedDevice.fromJson(Map<String, dynamic> json) => PairedDevice(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        platform: json['platform'] as String? ?? '',
        appVersion: json['app_version'] as String? ?? '',
        createdAt: DateTime.tryParse(json['created_at'] as String? ?? ''),
      );
}

/// A destination folder the PC exposes for backups.
class CloudBoxFolder {
  const CloudBoxFolder({required this.id, required this.name, required this.root});

  final String id;
  final String name;
  final String root;

  factory CloudBoxFolder.fromJson(Map<String, dynamic> json) => CloudBoxFolder(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        root: json['root'] as String? ?? '',
      );
}

/// The PC's identity and capabilities, from `GET /v1/system/info`.
class ServerInfo {
  const ServerInfo({
    required this.serverId,
    required this.serverName,
    required this.version,
    required this.platform,
    required this.device,
    required this.folders,
  });

  final String serverId;
  final String serverName;
  final String version;
  final String platform;
  final PairedDevice device;
  final List<CloudBoxFolder> folders;

  factory ServerInfo.fromJson(Map<String, dynamic> json) => ServerInfo(
        serverId: json['server_id'] as String? ?? '',
        serverName: json['server_name'] as String? ?? '',
        version: json['version'] as String? ?? '',
        platform: json['platform'] as String? ?? '',
        device: PairedDevice.fromJson(
          (json['device'] as Map?)?.cast<String, dynamic>() ?? const {},
        ),
        folders: ((json['folders'] as List?) ?? const [])
            .whereType<Map>()
            .map((f) => CloudBoxFolder.fromJson(f.cast<String, dynamic>()))
            .toList(growable: false),
      );
}

/// A drive on the PC, from `GET /v1/system/volumes`.
class CloudBoxDrive {
  const CloudBoxDrive({
    required this.name,
    required this.label,
    required this.path,
    required this.fsType,
    required this.totalBytes,
    required this.freeBytes,
    required this.removable,
    required this.network,
  });

  final String name;
  final String label;
  final String path;
  final String fsType;
  final int totalBytes;
  final int freeBytes;
  final bool removable;
  final bool network;

  factory CloudBoxDrive.fromJson(Map<String, dynamic> json) => CloudBoxDrive(
        name: json['name'] as String? ?? '',
        label: json['label'] as String? ?? '',
        path: json['path'] as String? ?? '',
        fsType: json['fs_type'] as String? ?? '',
        totalBytes: (json['total_bytes'] as num?)?.toInt() ?? 0,
        freeBytes: (json['free_bytes'] as num?)?.toInt() ?? 0,
        removable: json['removable'] as bool? ?? false,
        network: json['network'] as bool? ?? false,
      );

  /// What to show as the headline: the volume label when the PC set one, else the drive letter.
  String get displayName => label.isNotEmpty ? label : name;

  int get usedBytes => totalBytes > freeBytes ? totalBytes - freeBytes : 0;

  double get usedFraction => totalBytes <= 0 ? 0 : usedBytes / totalBytes;

  /// `12.4 GB of 465 GB free`.
  String get capacitySummary => '${formatBytes(freeBytes)} free of ${formatBytes(totalBytes)}';
}

/// Formats a byte count with one decimal, using binary units (KiB/MiB/GiB/TiB).
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KiB', 'MiB', 'GiB', 'TiB', 'PiB'];
  var value = bytes / 1024;
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(value >= 100 ? 0 : 1)} ${units[unit]}';
}

// Wire models for the agent's loopback-only /local/* API. The field names mirror the Go structs
// in agent/internal/api/local.go and agent/internal/volume/volume.go.

class LocalPairing {
  const LocalPairing({
    required this.token,
    required this.expiresAt,
    required this.active,
  });

  factory LocalPairing.fromJson(Map<String, dynamic> json) {
    return LocalPairing(
      token: json['token'] as String? ?? '',
      expiresAt: DateTime.tryParse(json['expires_at'] as String? ?? '') ?? DateTime.now(),
      active: json['active'] as bool? ?? false,
    );
  }

  final String token;
  final DateTime expiresAt;
  final bool active;
}

class DestinationInfo {
  const DestinationInfo({
    required this.volume,
    required this.subfolder,
    required this.root,
  });

  factory DestinationInfo.fromJson(Map<String, dynamic> json) {
    return DestinationInfo(
      volume: json['volume'] as String? ?? '',
      subfolder: json['subfolder'] as String? ?? '',
      root: json['root'] as String? ?? '',
    );
  }

  final String volume;
  final String subfolder;
  final String root;
}

class VolumeInfo {
  const VolumeInfo({
    required this.name,
    required this.label,
    required this.path,
    required this.fsType,
    required this.total,
    required this.free,
    required this.removable,
    required this.network,
  });

  factory VolumeInfo.fromJson(Map<String, dynamic> json) {
    return VolumeInfo(
      name: json['name'] as String? ?? '',
      label: json['label'] as String? ?? '',
      path: json['path'] as String? ?? '',
      fsType: json['fs_type'] as String? ?? '',
      total: (json['total_bytes'] as num?)?.toInt() ?? 0,
      free: (json['free_bytes'] as num?)?.toInt() ?? 0,
      removable: json['removable'] as bool? ?? false,
      network: json['network'] as bool? ?? false,
    );
  }

  final String name;
  final String label;
  final String path;
  final String fsType;
  final int total;
  final int free;
  final bool removable;
  final bool network;

  String get displayName => label.isEmpty ? name : '$name  $label';

  String get freeText => free <= 0 ? 'space unknown' : '${_formatBytes(free)} free of ${_formatBytes(total)}';

  /// FAT32 cannot hold a file over 4 GiB — worth saying before a long video is backed up.
  bool get hasFatLimit => fsType.toUpperCase().contains('FAT');

  static String _formatBytes(int bytes) {
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var value = bytes.toDouble();
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    final digits = unit == 0 || value >= 100 ? 0 : 1;
    return '${value.toStringAsFixed(digits)} ${units[unit]}';
  }
}

/// Backup destination assigned to one paired phone.
///
/// The agent stores this alongside the device record, so each phone can send its files to a
/// different volume/subfolder. [enabled] false means the client-supplied folder id is used as-is.
class DeviceBackupConfig {
  const DeviceBackupConfig({
    required this.folderId,
    required this.volume,
    required this.subfolder,
    required this.root,
    required this.enabled,
  });

  factory DeviceBackupConfig.fromJson(Map<String, dynamic> json) {
    return DeviceBackupConfig(
      folderId: json['folder_id'] as String? ?? '',
      volume: json['volume'] as String? ?? '',
      subfolder: json['subfolder'] as String? ?? '',
      root: json['root'] as String? ?? '',
      enabled: json['enabled'] as bool? ?? true,
    );
  }

  final String folderId;
  final String volume;
  final String subfolder;
  final String root;
  final bool enabled;

  Map<String, dynamic> toJson() => {
        'volume': volume,
        'subfolder': subfolder,
        'enabled': enabled,
      };
}

class PairedDevice {
  const PairedDevice({
    required this.id,
    required this.name,
    required this.platform,
    required this.appVersion,
    required this.createdAt,
    required this.lastSeenAt,
    required this.active,
    required this.backup,
  });

  factory PairedDevice.fromJson(Map<String, dynamic> json) {
    final backupJson = json['backup'];
    return PairedDevice(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? 'Unnamed device',
      platform: json['platform'] as String? ?? '',
      appVersion: json['app_version'] as String? ?? '',
      createdAt: json['created_at'] as String? ?? '',
      lastSeenAt: json['last_seen_at'] as String? ?? '',
      // A device in the agent's registry is paired by definition; the agent does not mark
      // records inactive, it only updates last_seen_at when the phone checks in.
      active: json['active'] as bool? ?? true,
      backup: backupJson is Map
          ? DeviceBackupConfig.fromJson(backupJson.cast<String, dynamic>())
          : const DeviceBackupConfig(folderId: '', volume: '', subfolder: '', root: '', enabled: false),
    );
  }

  final String id;
  final String name;
  final String platform;
  final String appVersion;
  final String createdAt;
  final String lastSeenAt;
  final bool active;
  final DeviceBackupConfig backup;

  String get subtitle {
    final parts = <String>[];
    if (platform.isNotEmpty) parts.add(platform);
    if (appVersion.isNotEmpty) parts.add('v$appVersion');
    if (parts.isEmpty) parts.add('Paired device');
    return parts.join(' · ');
  }

  PairedDevice copyWith({
    String? name,
    String? platform,
    String? appVersion,
    String? createdAt,
    String? lastSeenAt,
    bool? active,
    DeviceBackupConfig? backup,
  }) {
    return PairedDevice(
      id: id,
      name: name ?? this.name,
      platform: platform ?? this.platform,
      appVersion: appVersion ?? this.appVersion,
      createdAt: createdAt ?? this.createdAt,
      lastSeenAt: lastSeenAt ?? this.lastSeenAt,
      active: active ?? this.active,
      backup: backup ?? this.backup,
    );
  }
}

class BackupStatus {
  const BackupStatus({
    required this.deviceId,
    required this.deviceName,
    required this.folderId,
    required this.volume,
    required this.subfolder,
    required this.root,
    required this.available,
    required this.enabled,
    required this.lastBackupAt,
    required this.fileCount,
    required this.bytes,
  });

  factory BackupStatus.fromJson(Map<String, dynamic> json) {
    return BackupStatus(
      deviceId: json['device_id'] as String? ?? '',
      deviceName: json['device_name'] as String? ?? 'Unnamed device',
      folderId: json['folder_id'] as String? ?? '',
      volume: json['volume'] as String? ?? '',
      subfolder: json['subfolder'] as String? ?? '',
      root: json['root'] as String? ?? '',
      available: json['available'] as bool? ?? false,
      enabled: json['enabled'] as bool? ?? true,
      // The agent reports last_seen_at; older drafts called it last_backup_at. Accept both.
      lastBackupAt: (json['last_backup_at'] as String?) ?? (json['last_seen_at'] as String?) ?? '',
      fileCount: (json['file_count'] as num?)?.toInt() ?? 0,
      bytes: (json['bytes'] as num?)?.toInt() ?? 0,
    );
  }

  final String deviceId;
  final String deviceName;
  final String folderId;
  final String volume;
  final String subfolder;
  final String root;
  final bool available;
  final bool enabled;
  final String lastBackupAt;
  final int fileCount;
  final int bytes;

  String get sizeText {
    if (bytes <= 0) return 'Transfer totals not tracked yet';
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var value = bytes.toDouble();
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    final digits = unit == 0 || value >= 100 ? 0 : 1;
    return '${value.toStringAsFixed(digits)} ${units[unit]}';
  }
}

class SelectedFolder {
  const SelectedFolder({
    required this.id,
    required this.name,
    required this.root,
  });

  factory SelectedFolder.fromJson(Map<String, dynamic> json) {
    return SelectedFolder(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      root: json['root'] as String? ?? '',
    );
  }

  final String id;
  final String name;
  final String root;
}

class LocalState {
  const LocalState({
    required this.serverName,
    required this.serverId,
    required this.version,
    required this.pin,
    required this.endpoints,
    this.startedAt,
    required this.pairing,
    required this.destination,
    required this.payload,
    required this.qrPngBase64,
  });

  factory LocalState.fromJson(Map<String, dynamic> json) {
    final pairingJson = json['pairing'];
    final destinationJson = json['destination'];
    return LocalState(
      serverName: json['server_name'] as String? ?? 'CloudBox PC',
      serverId: json['server_id'] as String? ?? '',
      version: json['version'] as String? ?? '',
      pin: json['pin'] as String? ?? '',
      endpoints: (json['endpoints'] as List?)?.whereType<String>().toList() ?? const <String>[],
      startedAt: DateTime.tryParse(json['started_at'] as String? ?? ''),
      pairing: pairingJson is Map
          ? LocalPairing.fromJson(pairingJson.cast<String, dynamic>())
          : LocalPairing(token: '', expiresAt: DateTime.now(), active: false),
      destination: destinationJson is Map ? DestinationInfo.fromJson(destinationJson.cast<String, dynamic>()) : null,
      payload: json['payload'] as String? ?? '',
      qrPngBase64: json['qr_png_base64'] as String? ?? '',
    );
  }

  final String serverName;
  final String serverId;
  final String version;
  final String pin;
  final List<String> endpoints;
  final DateTime? startedAt;
  final LocalPairing pairing;
  final DestinationInfo? destination;
  final String payload;
  final String qrPngBase64;

  LocalState copyWithPairing(LocalPairing value) => LocalState(
        serverName: serverName,
        serverId: serverId,
        version: version,
        pin: pin,
        endpoints: endpoints,
        startedAt: startedAt,
        pairing: value,
        destination: destination,
        payload: payload,
        qrPngBase64: qrPngBase64,
      );
}

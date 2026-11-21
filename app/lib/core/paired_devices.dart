// Pairings saved on the phone.
//
// A pairing code is single-use, so throwing away the result after one send would force the user to
// scan the QR code again every time. We persist the device token, the endpoint list and the
// certificate pin, which is everything needed to rebuild an authenticated client later.

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'pairing_payload.dart';

/// One PC this phone has paired with, in a form safe to write to disk.
class PairedDeviceRecord {
  const PairedDeviceRecord({
    required this.deviceId,
    required this.deviceToken,
    required this.deviceName,
    required this.serverId,
    required this.serverName,
    required this.serverVersion,
    required this.platform,
    required this.appVersion,
    required this.endpoints,
    required this.pin,
    required this.pairedAt,
  });

  final String deviceId;
  final String deviceToken;
  final String deviceName;
  final String serverId;
  final String serverName;
  final String serverVersion;
  final String platform;
  final String appVersion;
  final List<String> endpoints;
  final String pin;
  final DateTime pairedAt;

  /// The original QR payload, reconstructed for [CloudBoxClient.forPairedDevice].
  PairingPayload toPayload() => PairingPayload(
        version: 1,
        serverId: serverId,
        endpoints: endpoints,
        pin: pin,
        // The single-use pairing token is deliberately not stored: reconnecting uses deviceToken.
        token: '',
      );

  Map<String, dynamic> toJson() => {
        'device_id': deviceId,
        'device_token': deviceToken,
        'device_name': deviceName,
        'server_id': serverId,
        'server_name': serverName,
        'server_version': serverVersion,
        'platform': platform,
        'app_version': appVersion,
        'endpoints': endpoints,
        'pin': pin,
        'paired_at': pairedAt.toIso8601String(),
      };

  factory PairedDeviceRecord.fromJson(Map<String, dynamic> json) => PairedDeviceRecord(
        deviceId: json['device_id'] as String? ?? '',
        deviceToken: json['device_token'] as String? ?? '',
        deviceName: json['device_name'] as String? ?? '',
        serverId: json['server_id'] as String? ?? '',
        serverName: json['server_name'] as String? ?? '',
        serverVersion: json['server_version'] as String? ?? '',
        platform: json['platform'] as String? ?? 'android',
        appVersion: json['app_version'] as String? ?? '',
        endpoints: (json['endpoints'] as List?)
                ?.whereType<String>()
                .toList(growable: false) ??
            const [],
        pin: json['pin'] as String? ?? '',
        pairedAt: DateTime.tryParse(json['paired_at'] as String? ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0),
      );

  /// Two phones pairing with the same PC are two independent records.
  String get key => '$serverId/$deviceId';

  PairedDeviceRecord copyWith({
    String? serverName,
    String? serverVersion,
    DateTime? pairedAt,
  }) => PairedDeviceRecord(
        deviceId: deviceId,
        deviceToken: deviceToken,
        deviceName: deviceName,
        serverId: serverId,
        serverName: serverName ?? this.serverName,
        serverVersion: serverVersion ?? this.serverVersion,
        platform: platform,
        appVersion: appVersion,
        endpoints: endpoints,
        pin: pin,
        pairedAt: pairedAt ?? this.pairedAt,
      );
}

/// Persists the list of paired PCs. Corrupt data is dropped rather than crashing the app: the
/// user can always pair again, and a broken record must not hide the good ones.
abstract final class PairedDeviceStore {
  static const key = 'cloudbox.paired.v1';

  static Future<List<PairedDeviceRecord>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(key);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map>()
          .map((map) => PairedDeviceRecord.fromJson(map.cast<String, dynamic>()))
          .where((record) => record.deviceToken.isNotEmpty && record.endpoints.isNotEmpty)
          .toList(growable: false);
    } on Object {
      return const [];
    }
  }

  static Future<void> save(List<PairedDeviceRecord> records) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      key,
      jsonEncode(records.map((record) => record.toJson()).toList()),
    );
  }

  /// Adds a new pairing, or refreshes an existing one with the same PC and device id.
  static Future<void> upsert(PairedDeviceRecord record) async {
    final records = await load();
    final kept = records.where((existing) => existing.key != record.key).toList();
    await save([...kept, record]);
  }

  static Future<void> remove(PairedDeviceRecord record) async {
    final records = await load();
    await save(records.where((existing) => existing.key != record.key).toList());
  }
}

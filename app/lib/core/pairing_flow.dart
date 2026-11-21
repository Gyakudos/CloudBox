// The pairing handshake, kept out of the widgets so it can be reasoned about (and tested)
// without a widget tree.

import 'agent_client.dart';
import 'models.dart';
import 'paired_devices.dart';
import 'pairing_payload.dart';

/// The result of a successful pairing or a reconnect to a saved PC: a live client plus what we
/// learned about the PC.
class PairingOutcome {
  const PairingOutcome({
    required this.client,
    required this.pairing,
    required this.info,
    required this.payload,
    required this.deviceName,
    required this.appVersion,
    required this.platform,
  });

  final CloudBoxClient client;
  final PairingResult pairing;
  final ServerInfo info;

  /// The QR payload the pairing came from, kept so the pairing can be saved for later sends.
  final PairingPayload payload;

  /// The name the phone gave the PC during pairing.
  final String deviceName;

  /// This app's version at pairing time, shown on the PC's paired-devices screen.
  final String appVersion;

  /// Platform reported to the PC at pairing time.
  final String platform;

  /// Everything needed to reconnect next time without scanning the QR code again.
  PairedDeviceRecord get record => PairedDeviceRecord(
        deviceId: pairing.deviceId,
        deviceToken: pairing.deviceToken,
        deviceName: deviceName,
        serverId: pairing.serverId,
        serverName: info.serverName,
        serverVersion: info.version,
        platform: platform,
        appVersion: appVersion,
        endpoints: payload.endpoints,
        pin: payload.pin,
        pairedAt: DateTime.now(),
      );

  /// The backup destination the PC configured for this phone.
  ///
  /// The agent gives every paired device its own `backup-<device id>` folder and includes it in
  /// `GET /v1/system/info`. Older agents may only expose the shared `default` folder, so fall back
  /// to that, then to anything the agent advertised. The phone never picks a drive itself: the PC
  /// app's Storage screen owns that choice.
  CloudBoxFolder get destinationFolder {
    final deviceFolderId = 'backup-${pairing.deviceId}';
    for (final folder in info.folders) {
      if (folder.id == deviceFolderId) return folder;
    }
    for (final folder in info.folders) {
      if (folder.id == 'default') return folder;
    }
    if (info.folders.isNotEmpty) return info.folders.first;
    return const CloudBoxFolder(id: 'default', name: 'CloudBox', root: '');
  }
}

/// Pairs using [payload], then fetches the PC's info.
///
/// Closes the client if anything fails, so a retry never leaks a connection pool.
Future<PairingOutcome> pairWithPayload(
  PairingPayload payload, {
  required String deviceName,
  required String appVersion,
  String platform = 'android',
}) async {
  final client = CloudBoxClient.forPayload(payload);
  try {
    final pairing = await client.pair(
      pairingToken: payload.token,
      deviceName: deviceName,
      appVersion: appVersion,
      platform: platform,
    );
    final info = await client.info();
    return PairingOutcome(
      client: client,
      pairing: pairing,
      info: info,
      payload: payload,
      deviceName: deviceName,
      appVersion: appVersion,
      platform: platform,
    );
  } catch (_) {
    client.close();
    rethrow;
  }
}

/// Reconnects using a pairing saved on the phone. No single-use pairing token is involved: the
/// device token from the original handshake authenticates the request.
///
/// Closes the client if the PC cannot be reached, so a retry never leaks a connection pool.
Future<PairingOutcome> connectToPairedDevice(PairedDeviceRecord record) async {
  final payload = record.toPayload();
  final client = CloudBoxClient.forPairedDevice(payload, record.deviceToken);
  try {
    final info = await client.info();
    return PairingOutcome(
      client: client,
      pairing: PairingResult(
        deviceId: record.deviceId,
        deviceToken: record.deviceToken,
        serverId: record.serverId,
        serverName: info.serverName,
        serverVersion: record.serverVersion,
      ),
      info: info,
      payload: payload,
      deviceName: record.deviceName,
      appVersion: record.appVersion,
      platform: record.platform,
    );
  } catch (_) {
    client.close();
    rethrow;
  }
}

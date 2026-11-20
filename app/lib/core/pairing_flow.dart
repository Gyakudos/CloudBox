// The pairing handshake, kept out of the widgets so it can be reasoned about (and tested)
// without a widget tree.

import 'agent_client.dart';
import 'models.dart';
import 'pairing_payload.dart';

/// The result of a successful pairing: a live client plus what we learned about the PC.
class PairingOutcome {
  const PairingOutcome({required this.client, required this.pairing, required this.info});

  final CloudBoxClient client;
  final PairingResult pairing;
  final ServerInfo info;

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
    return PairingOutcome(client: client, pairing: pairing, info: info);
  } catch (_) {
    client.close();
    rethrow;
  }
}

import 'dart:convert';

import 'package:cloudbox_pc/core/models.dart';
import 'package:flutter_test/flutter_test.dart';

const _stateJson = '''
{
  "server_name": "MY-PC",
  "server_id": "0123456789abcdef0123456789abcdef",
  "version": "0.01.15.11.26",
  "pin": "pin-value",
  "endpoints": ["127.0.0.1:8443"],
  "pairing": {
    "token": "one-time-token",
    "expires_at": "2026-11-19T12:00:00Z",
    "active": true
  },
  "destination": {
    "volume": "E:",
    "subfolder": "CloudBox",
    "root": "E:\\\\CloudBox"
  },
  "payload": "{\\"tok\\":\\"one-time-token\\"}",
  "qr_png_base64": "aGVsbG8="
}
''';

void main() {
  test('parses the agent status envelope', () {
    final state = LocalState.fromJson(jsonDecode(_stateJson) as Map<String, dynamic>);

    expect(state.serverName, 'MY-PC');
    expect(state.serverId, hasLength(32));
    expect(state.version, '0.01.15.11.26');
    expect(state.endpoints, ['127.0.0.1:8443']);
    expect(state.pairing.token, 'one-time-token');
    expect(state.pairing.active, isTrue);
    expect(state.destination?.volume, 'E:');
    expect(state.destination?.root, r'E:\CloudBox');
    expect(state.qrPngBase64, 'aGVsbG8=');
  });

  test('tolerates a missing destination on first run', () {
    final json = jsonDecode(_stateJson) as Map<String, dynamic>;
    json.remove('destination');
    expect(LocalState.fromJson(json).destination, isNull);
  });

  test('formats drive capacity for people', () {
    final volume = VolumeInfo.fromJson({
      'name': 'E:',
      'label': 'Elements',
      'fs_type': 'NTFS',
      'total_bytes': 2000398934016,
      'free_bytes': 1073741824000,
      'removable': true,
    });

    expect(volume.displayName, 'E:  Elements');
    expect(volume.freeText, contains('free of'));
    expect(volume.freeText, contains('TB'));
    expect(volume.hasFatLimit, isFalse);
    expect(volume.removable, isTrue);
  });

  test('flags FAT32 so large videos get a warning', () {
    final volume = VolumeInfo.fromJson({'name': 'F:', 'fs_type': 'FAT32', 'total_bytes': 1000, 'free_bytes': 500});
    expect(volume.hasFatLimit, isTrue);
  });

  test('parses persisted devices and backup rows from the agent', () {
    final device = PairedDevice.fromJson({
      'id': 'dev-1',
      'name': 'Pixel 8',
      'platform': 'android',
      'app_version': '0.01.15.11.26',
      'created_at': '2026-11-15T10:00:00Z',
      'last_seen_at': '2026-11-15T11:00:00Z',
      'backup': {
        'folder_id': 'backup-dev-1',
        'volume': 'E:',
        'subfolder': 'CloudBox/Pixel-8',
        'root': r'E:\CloudBox\Pixel-8',
        'enabled': true,
      },
    });
    expect(device.active, isTrue);
    expect(device.backup.folderId, 'backup-dev-1');
    expect(device.subtitle, contains('android'));

    final backup = BackupStatus.fromJson({
      'device_id': 'dev-1',
      'device_name': 'Pixel 8',
      'folder_id': 'backup-dev-1',
      'volume': 'E:',
      'root': r'E:\CloudBox\Pixel-8',
      'available': true,
      'enabled': true,
      'last_seen_at': '2026-11-15T11:00:00Z',
    });
    expect(backup.available, isTrue);
    expect(backup.lastBackupAt, '2026-11-15T11:00:00Z');
    expect(backup.sizeText, 'Transfer totals not tracked yet');
  });
}

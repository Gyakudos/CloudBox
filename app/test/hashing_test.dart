import 'dart:io';
import 'dart:typed_data';

import 'package:cloudbox/core/hashing.dart';
import 'package:flutter_test/flutter_test.dart';

/// Cross-language vectors: the digest the Go agent computes for the same bytes, via
/// `cloudbox hash <file>` (zeebo/blake3, the official Go implementation). If the Dart and Go
/// sides ever disagree, no upload can commit — the agent answers `422 HASH_MISMATCH` — so this
/// is the test that keeps the two halves of the protocol honest.
///
/// Regenerate by writing the same byte pattern to a file and running
/// `go run ./cmd/cloudbox hash <file>` in `agent/`.
const _emptyHex = 'af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262';
const _abcHex = '6437b3ac38465133ffb63b75273a8db548c558465d79db03fd359c6cd5bd9d85';
const _pattern1024Hex = '882179b8dbccd285cda241d968cfcccb3156c5edac2fa3761bb6eda7ff8cb172';
const _pattern1025Hex = '3e85e5a7ffcd07c23794c079d43ebb27372d06bb1f75e4b47732fcaaf1a8cf3d';
const _pattern3000Hex = 'e8399322cd0777e24d185a1db40fac663edeeab8c800b87d2d890b74a2818e25';
const _pattern2500000Hex = '3548deaa73dc9324192ac9a38a48af26ff752ded38867f8ee83b0b8758b0cdef';

/// Byte[i] = i % 256, the pattern used for the 1024/1025 vectors.
Uint8List _mod256(int length) =>
    Uint8List.fromList(List<int>.generate(length, (i) => i % 256));

/// Byte[i] = (i * 31 + 7) % 256, the pattern used for the 3000/2.5M vectors.
Uint8List _mix(int length) =>
    Uint8List.fromList(List<int>.generate(length, (i) => (i * 31 + 7) % 256));

Future<File> _write(Uint8List bytes) async {
  final dir = await Directory.systemTemp.createTemp('cloudbox-hash');
  final file = File('${dir.path}${Platform.pathSeparator}blob.bin');
  await file.writeAsBytes(bytes);
  return file;
}

void main() {
  group('blake3HexOfBytes', () {
    test('matches the official vector for the empty input', () {
      expect(blake3HexOfBytes(const []), _emptyHex);
    });

    test('matches the Go agent for "abc"', () {
      expect(blake3HexOfBytes('abc'.codeUnits), _abcHex);
    });

    test('is 64 lowercase hex characters', () {
      final hex = blake3HexOfBytes(const [1, 2, 3]);
      expect(hex, matches(RegExp(r'^[0-9a-f]{64}$')));
    });
  });

  group('blake3HexOfFile', () {
    // The 1024/1025 pair straddles BLAKE3's internal chunk length; the 3000-byte and 2.5 MB
    // cases exercise the multi-chunk tree and the 1 MiB streaming read loop respectively.
    final cases = <String, (Uint8List, String)>{
      'empty': (Uint8List(0), _emptyHex),
      'abc': (Uint8List.fromList('abc'.codeUnits), _abcHex),
      '1024': (_mod256(1024), _pattern1024Hex),
      '1025': (_mod256(1025), _pattern1025Hex),
      '3000': (_mix(3000), _pattern3000Hex),
      '2.5MB': (_mix(2500000), _pattern2500000Hex),
    };

    for (final entry in cases.entries) {
      test('matches the Go agent for ${entry.key} bytes', () async {
        final file = await _write(entry.value.$1);
        addTearDown(() => file.parent.delete(recursive: true));
        expect(await blake3HexOfFile(file.path), entry.value.$2);
      });
    }

    test('background isolate hashing matches the main-isolate digest', () async {
      final bytes = _mix(2500000);
      final file = await _write(bytes);
      addTearDown(() => file.parent.delete(recursive: true));

      final direct = await blake3HexOfFile(file.path);
      final reported = <int>[];
      final outcome = await blake3HexOfFileInBackground(
        file.path,
        totalBytes: bytes.length,
        onProgress: (read, total) => reported.add(read),
      );

      expect(outcome.hash, direct);
      expect(outcome.length, bytes.length);
      expect(reported, isNotEmpty);
      expect(reported.every((read) => read > 0 && read <= bytes.length), isTrue);
    });

    test('reports progress that ends at the file size', () async {
      final bytes = _mix(3000);
      final file = await _write(bytes);
      addTearDown(() => file.parent.delete(recursive: true));

      var lastRead = 0;
      var lastTotal = 0;
      await blake3HexOfFile(file.path, onProgress: (read, total) {
        lastRead = read;
        lastTotal = total;
      });

      expect(lastRead, 3000);
      expect(lastTotal, 3000);
    });
  });
}

// BLAKE3-256, the content hash the transfer protocol is built on.
//
// The agent declares a file's identity by its BLAKE3-256 digest (`docs/sync-protocol.md` §1),
// and re-verifies the bytes it receives against it. The phone must therefore compute the same
// digest, over the same bytes, before it can even open an upload.
//
// Why the private import: `package:blake3_dart` verifies against the official test vectors but
// only exports one-shot helpers, which would require reading a whole video into memory. Its
// streaming `HashContext` lives in `src/`. Importing it is deliberate and pinned: the package
// is pure Dart with no transitive dependencies, and a future version that moves the file is a
// compile error here, not a silent wrong hash — `hashing_test.dart` locks the vectors.

// ignore: implementation_imports
import 'package:blake3_dart/src/blake3_compact.dart' as blake3;

import 'dart:io';
import 'dart:typed_data';

/// Returns the lowercase hex BLAKE3-256 digest of [bytes].
String blake3HexOfBytes(List<int> bytes) {
  final ctx = blake3.HashContext.unkeyed();
  ctx.update(bytes is Uint8List ? bytes : Uint8List.fromList(bytes));
  final out = Uint8List(32);
  ctx.finalize(out);
  return blake3.asHexString(out);
}

/// Streams [path] through BLAKE3 and returns the lowercase hex digest.
///
/// The file is read in bounded chunks, so a multi-gigabyte video costs a megabyte of memory
/// rather than its own size. [onProgress] is called with the bytes hashed so far and the file's
/// total size, for a determinate progress bar during the (potentially long) hash phase.
Future<String> blake3HexOfFile(
  String path, {
  void Function(int read, int total)? onProgress,
}) async {
  final file = File(path);
  final total = await file.length();
  return blake3HexOfStream(
    file.openRead(),
    totalBytes: total,
    onProgress: onProgress,
  );
}

/// Streams [stream] through BLAKE3 and returns the lowercase hex digest.
///
/// This is the form the upload flow uses, because a picked file may be readable only as a
/// stream (an Android `content://` URI has no filesystem path). [totalBytes] is optional: when
/// it is known, [onProgress] gets a determinate total, and when it is not the caller can use the
/// final read count as the size.
Future<String> blake3HexOfStream(
  Stream<List<int>> stream, {
  int? totalBytes,
  void Function(int read, int total)? onProgress,
}) async {
  final ctx = blake3.HashContext.unkeyed();
  var read = 0;

  await for (final data in stream) {
    ctx.update(data is Uint8List ? data : Uint8List.fromList(data));
    read += data.length;
    if (onProgress != null && totalBytes != null) onProgress(read, totalBytes);
  }

  final out = Uint8List(32);
  ctx.finalize(out);
  return blake3.asHexString(out);
}

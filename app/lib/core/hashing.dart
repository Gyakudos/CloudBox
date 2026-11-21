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

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

/// A digest together with the number of bytes actually hashed.
///
/// The byte count matters as much as the hash: a picked file's reported size can be stale, and
/// the upload is sized from the bytes the hash pass really read.
class HashOutcome {
  const HashOutcome(this.hash, this.length);

  final String hash;
  final int length;
}

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
/// This is the form the upload flow uses when a picked file has no filesystem path (an Android
/// `content://` URI). [totalBytes] is optional: when it is known, [onProgress] gets a determinate
/// total, and when it is not the caller can use the final read count as the size.
Future<String> blake3HexOfStream(
  Stream<List<int>> stream, {
  int? totalBytes,
  void Function(int read, int total)? onProgress,
}) async {
  final outcome = await blake3HexAndLengthOfStream(
    stream,
    totalBytes: totalBytes,
    onProgress: onProgress,
  );
  return outcome.hash;
}

/// As [blake3HexOfStream], but also reports how many bytes were read.
Future<HashOutcome> blake3HexAndLengthOfStream(
  Stream<List<int>> stream, {
  int? totalBytes,
  void Function(int read, int total)? onProgress,
}) async {
  final ctx = blake3.HashContext.unkeyed();
  var read = 0;

  await for (final data in stream) {
    final bytes = data is Uint8List ? data : Uint8List.fromList(data);
    ctx.update(bytes);
    read += bytes.length;
    if (onProgress != null && totalBytes != null) onProgress(read, totalBytes);
  }

  final out = Uint8List(32);
  ctx.finalize(out);
  return HashOutcome(blake3.asHexString(out), read);
}

/// Hashes a file on a background isolate so BLAKE3 never blocks the UI thread.
///
/// Hashing a large photo or video is CPU-bound pure Dart. Running it on the main isolate made the
/// whole app stop responding while a transfer was prepared, so the transfer engine calls this
/// whenever the picked file has a readable path (which both the file picker and the folder picker
/// provide on Android). Progress messages are throttled in the isolate to one per megabyte; the
/// caller throttles UI rebuilds further.
Future<HashOutcome> blake3HexOfFileInBackground(
  String path, {
  int? totalBytes,
  void Function(int read, int total)? onProgress,
}) async {
  final port = ReceivePort();
  // Capture only the SendPort: a closure that references `port` itself is unsendable and makes
  // Isolate.run throw before the isolate even starts.
  final sendPort = port.sendPort;
  StreamSubscription<Object?>? subscription;
  subscription = port.listen((message) {
    if (onProgress == null) return;
    if (message is List && message.length == 2) {
      onProgress(message[0] as int, message[1] as int);
    }
  });
  try {
    return await Isolate.run(
      () => _hashFileForIsolate(path, totalBytes, sendPort),
      debugName: 'cloudbox-hash',
    );
  } finally {
    await subscription.cancel();
    port.close();
  }
}

/// Top-level so it can be sent to a fresh isolate by [Isolate.run].
Future<HashOutcome> _hashFileForIsolate(
  String path,
  int? totalBytes,
  SendPort progress,
) async {
  final ctx = blake3.HashContext.unkeyed();
  const reportEvery = 1 << 20; // 1 MiB
  var nextReport = reportEvery;
  var read = 0;

  await for (final data in File(path).openRead()) {
    final bytes = data is Uint8List ? data : Uint8List.fromList(data);
    ctx.update(bytes);
    read += bytes.length;
    if (read >= nextReport) {
      progress.send([read, totalBytes ?? 0]);
      nextReport = read + reportEvery;
    }
  }

  final out = Uint8List(32);
  ctx.finalize(out);
  return HashOutcome(blake3.asHexString(out), read);
}

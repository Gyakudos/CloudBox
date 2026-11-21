// The engine that moves picked files from the phone to the PC.
//
// It is deliberately free of Flutter: the widget layer drives it and listens for changes, but
// the interesting behaviour — hashing in a streaming pass, uploading in bounded chunks, and
// resuming from wherever the PC says it got to — is all testable against a fake [UploadApi].

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'agent_client.dart';
import 'hashing.dart';
import 'models.dart';
import 'upload_api.dart';

/// A file the user chose to back up.
///
/// Decoupled from `file_picker`'s `PlatformFile` so the engine can be tested without a native
/// picker, and so a picked file that exists only as an Android `content://` URI (no filesystem
/// path) is first-class: everything goes through [openRead].
class SourceFile {
  const SourceFile({required this.name, required this.openRead, this.size, this.path});

  /// Destination path inside the sync folder. A plain file uses its base name (`photo.jpg`);
  /// a folder upload carries a slash-separated relative path (`DCIM/Camera/IMG_001.jpg`).
  final String name;

  /// The size in bytes, when the picker knew it. The engine does not rely on it: the hash pass
  /// counts the bytes it actually reads and that count is the size it uploads.
  final int? size;

  /// Opens a fresh stream over the file's bytes. Called more than once (hash pass, then upload,
  /// then a re-open after a resume), so it must be re-openable.
  final Stream<Uint8List> Function() openRead;

  /// A readable filesystem path, when the picker provided one. Both the Android file picker and
  /// the folder picker stage files on disk, so hashing normally happens on a background isolate
  /// instead of blocking the UI thread. Null only when bytes are reachable as a stream alone.
  final String? path;
}

/// Where one file is in its journey.
enum TransferState { queued, hashing, uploading, committing, done, failed, canceled }

/// One file's progress through the engine, observed by the UI.
class TransferItem {
  TransferItem(this.source);

  final SourceFile source;

  TransferState state = TransferState.queued;

  /// Bytes hashed so far, and the total once it is known.
  int hashed = 0;

  /// Bytes the PC has acknowledged, and the total being uploaded.
  int uploaded = 0;
  int total = 0;

  /// Set when the PC already held the content and only a commit was needed.
  bool deduped = false;

  /// The relative path the PC wrote, once committed.
  String? remotePath;

  /// A message for the user when [state] is [TransferState.failed].
  String? error;

  /// Overall fraction complete, folding the hash pass into the first half. Zero until the size
  /// is known.
  double get progress {
    if (state == TransferState.done) return 1;
    if (total <= 0) return 0;
    if (state == TransferState.hashing) return 0.5 * (hashed / total);
    return (0.5 + 0.5 * (uploaded / total)).clamp(0, 1);
  }

  bool get isTerminal =>
      state == TransferState.done ||
      state == TransferState.failed ||
      state == TransferState.canceled;
}

/// Runs a queue of [TransferItem]s to completion, one at a time.
///
/// One at a time is deliberate: a phone on Wi-Fi gains nothing from parallel uploads to a single
/// PC, and sequential transfers keep the progress the user sees honest.
class TransferController extends ChangeNotifier {
  TransferController({
    required this.api,
    this.folderId = 'default',
    this.chunkSize = 4 << 20, // 4 MiB
  });

  final UploadApi api;

  /// The folder ID the drive picker configured (see the agent's destination package).
  final String folderId;

  /// Size of each PATCH body. Bounds the memory a transfer holds to one chunk.
  final int chunkSize;

  final List<TransferItem> items = [];

  bool _running = false;
  bool _cancelRequested = false;

  bool get running => _running;

  /// Adds files to the queue. Already-present duplicates (same name and size) are ignored so a
  /// double tap on the picker does not queue the same photo twice.
  void addFiles(Iterable<SourceFile> files) {
    for (final file in files) {
      final duplicate = items.any(
        (item) => item.source.name == file.name && item.source.size == file.size,
      );
      if (!duplicate) items.add(TransferItem(file));
    }
    notifyListeners();
  }

  void removeAt(int index) {
    if (_running) return;
    items.removeAt(index);
    notifyListeners();
  }

  void clear() {
    if (_running) return;
    items.clear();
    notifyListeners();
  }

  /// Asks the running transfer to stop after the current chunk. Already-committed files stay
  /// committed; the file in flight is abandoned on the PC and resumes from its offset next time.
  void cancel() {
    _cancelRequested = true;
  }

  /// Uploads every queued file. Safe to call again after a cancel or a failure: finished files
  /// are skipped and failed ones are retried.
  Future<void> run() async {
    if (_running) return;
    _running = true;
    _cancelRequested = false;
    notifyListeners();

    try {
      for (final item in items) {
        if (_cancelRequested) break;
        if (item.state == TransferState.done) continue;
        await _transfer(item);
      }
    } finally {
      _running = false;
      notifyListeners();
    }
  }

  Future<void> _transfer(TransferItem item) async {
    try {
      item.error = null;
      item.state = TransferState.hashing;
      item.hashed = 0;
      notifyListeners();

      final hashOutcome = await _hash(item);
      final hash = hashOutcome.hash;
      // The hash pass is authoritative for the size: it counted the bytes we will actually send.
      item.hashed = hashOutcome.length;
      item.total = hashOutcome.length;
      notifyListeners();

      if (_cancelRequested) {
        _abandon(item);
        return;
      }

      final ticket = await api.createUpload(
        hash: hash,
        size: item.total,
        folderId: folderId,
      );

      if (ticket.complete) {
        item.state = TransferState.committing;
        notifyListeners();
        final result = await api.commitUpload(ticket.uploadId, hash: hash, path: item.source.name);
        _finish(item, result, deduped: true);
        return;
      }

      item.state = TransferState.uploading;
      item.uploaded = ticket.offset;
      notifyListeners();

      final reader = _SourceReader(item.source);
      try {
        var offset = ticket.offset;
        while (offset < item.total) {
          if (_cancelRequested) {
            _abandon(item);
            return;
          }
          await reader.seek(offset);
          final chunk = await reader.read(chunkSize);
          if (chunk == null || chunk.isEmpty) {
            throw CloudBoxException('The file ended before every byte had been sent.');
          }
          try {
            offset = await api.appendUpload(
              ticket.uploadId,
              offset: offset,
              chunk: chunk,
              totalSize: item.total,
            );
          } on CloudBoxException catch (error) {
            // The PC is ahead of us (a previous attempt got further before dropping). Skip to
            // where it actually is instead of re-sending bytes it already has.
            if (error.statusCode == 409 && error.offset != null) {
              offset = error.offset!;
              continue;
            }
            rethrow;
          }
          item.uploaded = offset;
          _notifyProgress();
        }
      } finally {
        await reader.close();
      }

      item.state = TransferState.committing;
      notifyListeners();
      final result = await api.commitUpload(ticket.uploadId, hash: hash, path: item.source.name);
      _finish(item, result, deduped: false);
    } on CloudBoxException catch (error) {
      item.state = TransferState.failed;
      item.error = error.message;
      notifyListeners();
    } on Object catch (error) {
      item.state = TransferState.failed;
      item.error = '$error';
      notifyListeners();
    }
  }

  DateTime? _lastProgressAt;

  /// Rebuilds are expensive when a picked folder holds hundreds of files, and hashing emits a
  /// progress event for every 64 KiB chunk. Cap UI updates at roughly 12 fps: the state changes
  /// around each phase still notify immediately, so the bar always reaches 100%.
  void _notifyProgress() {
    final now = DateTime.now();
    final last = _lastProgressAt;
    if (last != null && now.difference(last).inMilliseconds < 80) return;
    _lastProgressAt = now;
    notifyListeners();
  }

  /// Hashes on a background isolate whenever the picker gave us a path. Both Android pickers
  /// stage files on disk; the stream-only branch remains for platforms that cannot.
  Future<HashOutcome> _hash(TransferItem item) {
    void progress(int read, int total) {
      item.hashed = read;
      if (total > 0) item.total = total;
      _notifyProgress();
    }

    final path = item.source.path;
    if (path != null) {
      return blake3HexOfFileInBackground(
        path,
        totalBytes: item.source.size,
        onProgress: progress,
      );
    }
    return blake3HexAndLengthOfStream(
      item.source.openRead(),
      totalBytes: item.source.size,
      onProgress: progress,
    );
  }

  void _finish(TransferItem item, CommitResult result, {required bool deduped}) {
    item.deduped = result.deduped || deduped;
    item.remotePath = result.path;
    item.state = TransferState.done;
    item.uploaded = item.total;
    notifyListeners();
  }

  void _abandon(TransferItem item) {
    item.state = TransferState.canceled;
    notifyListeners();
  }
}

/// Reads a [SourceFile] sequentially, able to seek forward (to resume) or rewind (to restart).
///
/// The upload loop hands it the offset the PC confirmed; after a dropped connection that offset
/// can be ahead of where we stopped, so the reader discards the bytes in between rather than
/// re-opening the file for every chunk.
class _SourceReader {
  _SourceReader(this.source);

  final SourceFile source;

  StreamIterator<Uint8List>? _iterator;
  Uint8List _pending = Uint8List(0);

  /// Absolute offset of the next byte this reader will hand out.
  int _position = 0;

  Future<void> _open() async {
    await _iterator?.cancel();
    _iterator = StreamIterator<Uint8List>(source.openRead());
    _pending = Uint8List(0);
    _position = 0;
  }

  /// Positions the reader so its next byte is at [offset].
  Future<void> seek(int offset) async {
    if (_iterator == null || offset < _position) {
      await _open();
    }
    while (_position < offset) {
      if (_pending.isEmpty) {
        if (!await _iterator!.moveNext()) return; // EOF before the requested offset
        _pending = _iterator!.current;
        continue;
      }
      final skip = offset - _position;
      if (_pending.length <= skip) {
        _position += _pending.length;
        _pending = Uint8List(0);
      } else {
        _pending = Uint8List.sublistView(_pending, skip);
        _position = offset;
      }
    }
  }

  /// Returns up to [size] bytes at the current position, or null at end of file.
  Future<Uint8List?> read(int size) async {
    final builder = BytesBuilder(copy: false);
    while (builder.length < size) {
      if (_pending.isEmpty) {
        if (_iterator == null || !await _iterator!.moveNext()) break;
        _pending = _iterator!.current;
        continue;
      }
      final want = size - builder.length;
      if (_pending.length <= want) {
        builder.add(_pending);
        _position += _pending.length;
        _pending = Uint8List(0);
      } else {
        builder.add(Uint8List.sublistView(_pending, 0, want));
        _pending = Uint8List.sublistView(_pending, want);
        _position += want;
      }
    }
    return builder.isEmpty ? null : builder.takeBytes();
  }

  Future<void> close() async {
    await _iterator?.cancel();
    _iterator = null;
  }
}

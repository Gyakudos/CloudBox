import 'dart:math';
import 'dart:typed_data';

import 'package:cloudbox/core/agent_client.dart';
import 'package:cloudbox/core/models.dart';
import 'package:cloudbox/core/transfer.dart';
import 'package:cloudbox/core/upload_api.dart';
import 'package:flutter_test/flutter_test.dart';

/// A stand-in for the PC that keeps the bytes it has "received" per upload, enforces the same
/// fixed-offset rule the real agent does, and can be told to behave like a connection that
/// dropped after the server had already written part of a chunk.
class FakeUploadApi implements UploadApi {
  FakeUploadApi({
    this.completeOnCreate = false,
    this.seedBytes,
    this.reportCreateOffset = true,
    this.failAppend = false,
    this.onCommit,
  });

  /// Mimic a cache hit: create says the content is already on the PC.
  final bool completeOnCreate;

  /// Bytes the server already holds when the upload is created (a partial earlier attempt).
  final List<int>? seedBytes;

  /// When false, create claims offset 0 even though [seedBytes] are held, which forces the
  /// engine to discover the real offset through a 409.
  final bool reportCreateOffset;

  /// When true, every append throws a 500, for the failure path.
  final bool failAppend;

  /// Called when a commit is received, so a test can act mid-run (e.g. cancel).
  final void Function()? onCommit;

  final Map<String, List<int>> _uploads = {};
  final List<({int offset, int length})> appends = [];
  final List<String> commitPaths = [];
  final List<String> createFolders = [];
  int createCalls = 0;

  @override
  Future<UploadTicket> createUpload({
    required String hash,
    required int size,
    String folderId = 'default',
  }) async {
    createCalls++;
    createFolders.add(folderId);
    final id = 'upload-$createCalls';
    if (completeOnCreate) {
      return UploadTicket(uploadId: id, offset: size, complete: true);
    }
    _uploads[id] = [...?seedBytes];
    return UploadTicket(
      uploadId: id,
      offset: reportCreateOffset ? _uploads[id]!.length : 0,
      complete: false,
    );
  }

  @override
  Future<int> appendUpload(
    String uploadId, {
    required int offset,
    required List<int> chunk,
    required int totalSize,
  }) async {
    if (failAppend) {
      throw CloudBoxException('the PC could not write the file', statusCode: 500, code: 'INTERNAL');
    }
    final buffer = _uploads[uploadId]!;
    if (offset != buffer.length) {
      throw CloudBoxException(
        'body does not start at the expected offset',
        statusCode: 409,
        code: 'OFFSET_MISMATCH',
        offset: buffer.length,
      );
    }
    appends.add((offset: offset, length: chunk.length));
    buffer.addAll(chunk);
    return buffer.length;
  }

  @override
  Future<UploadStatus> uploadStatus(String uploadId) async => throw UnimplementedError();

  @override
  Future<CommitResult> commitUpload(
    String uploadId, {
    required String hash,
    required String path,
    int? mtimeMs,
  }) async {
    commitPaths.add(path);
    onCommit?.call();
    return CommitResult(
      committed: true,
      path: path,
      deduped: completeOnCreate,
      replaced: false,
    );
  }

  List<int> bytesFor(String uploadId) => _uploads[uploadId]!;
}

SourceFile _source(String name, List<int> bytes, {int partSize = 1 << 20}) {
  return SourceFile(
    name: name,
    size: bytes.length,
    openRead: () => _chunks(bytes, partSize),
  );
}

Stream<Uint8List> _chunks(List<int> bytes, int partSize) async* {
  for (var i = 0; i < bytes.length; i += partSize) {
    yield Uint8List.fromList(bytes.sublist(i, min(i + partSize, bytes.length)));
  }
}

List<int> _pattern(int length) => List<int>.generate(length, (i) => (i * 7 + 3) % 256);

void main() {
  group('TransferController', () {
    test('hashes, uploads in order, and commits a small file', () async {
      final bytes = _pattern(500);
      final api = FakeUploadApi();
      final controller = TransferController(api: api, chunkSize: 256);
      controller.addFiles([_source('photo.jpg', bytes)]);

      await controller.run();

      final item = controller.items.single;
      expect(item.state, TransferState.done);
      expect(item.error, isNull);
      expect(item.total, 500);
      expect(item.remotePath, 'photo.jpg');
      expect(item.deduped, isFalse);

      // Two appends: 0..255 then 256..499.
      expect(api.appends.map((a) => a.offset).toList(), [0, 256]);
      expect(api.appends.map((a) => a.length).toList(), [256, 244]);
      expect(api.bytesFor('upload-1'), bytes);
    });

    test('commits a folder upload at its relative path', () async {
      final bytes = _pattern(300);
      final api = FakeUploadApi();
      final controller = TransferController(api: api, chunkSize: 256);
      controller.addFiles([_source('DCIM/Camera/IMG_001.jpg', bytes)]);

      await controller.run();

      final item = controller.items.single;
      expect(item.state, TransferState.done);
      expect(item.error, isNull);
      // The agent creates parent directories, so the whole relative path must reach commit.
      expect(api.commitPaths, ['DCIM/Camera/IMG_001.jpg']);
      expect(item.remotePath, 'DCIM/Camera/IMG_001.jpg');
    });

    test('reads a file delivered in several stream events', () async {
      final bytes = _pattern(1000);
      final api = FakeUploadApi();
      final controller = TransferController(api: api, chunkSize: 300);
      // The source yields 64-byte events, smaller than both the chunk and the hash read.
      controller.addFiles([_source('clip.mp4', bytes, partSize: 64)]);

      await controller.run();

      expect(controller.items.single.state, TransferState.done);
      expect(api.bytesFor('upload-1'), bytes);
      expect(api.appends.map((a) => a.offset).toList(), [0, 300, 600, 900]);
    });

    test('resumes from the offset the PC reports after a 409', () async {
      final bytes = _pattern(1000);
      // The PC already holds the first 400 bytes, but create lies and says offset 0, exactly as
      // it would if the ack for those bytes was lost with the connection.
      final api = FakeUploadApi(seedBytes: bytes.sublist(0, 400), reportCreateOffset: false);
      final controller = TransferController(api: api, chunkSize: 256);
      controller.addFiles([_source('movie.mp4', bytes)]);

      await controller.run();

      final item = controller.items.single;
      expect(item.state, TransferState.done);
      // The first append is rejected and never recorded; the next starts at the real offset.
      expect(api.appends.first.offset, 400);
      expect(api.bytesFor('upload-1'), bytes);
    });

    test('commits a cached file without sending any bytes', () async {
      final bytes = _pattern(2048);
      final api = FakeUploadApi(completeOnCreate: true);
      final controller = TransferController(api: api, chunkSize: 256);
      controller.addFiles([_source('duplicate.jpg', bytes)]);

      await controller.run();

      final item = controller.items.single;
      expect(item.state, TransferState.done);
      expect(item.deduped, isTrue);
      expect(api.appends, isEmpty);
      expect(api.commitPaths, ['duplicate.jpg']);
    });

    test('marks the file failed and keeps the message when a chunk is refused', () async {
      final api = FakeUploadApi(failAppend: true);
      final controller = TransferController(api: api, chunkSize: 256);
      controller.addFiles([_source('broken.bin', _pattern(300))]);

      await controller.run();

      final item = controller.items.single;
      expect(item.state, TransferState.failed);
      expect(item.error, 'the PC could not write the file');
    });

    test('transfers a queue in order and skips files already done', () async {
      final api = FakeUploadApi();
      final controller = TransferController(api: api, chunkSize: 512);
      controller.addFiles([
        _source('a.bin', _pattern(100)),
        _source('b.bin', _pattern(200)),
      ]);

      await controller.run();
      expect(controller.items.every((i) => i.state == TransferState.done), isTrue);
      expect(api.createCalls, 2);

      // A second run must not re-upload the finished files.
      await controller.run();
      expect(api.createCalls, 2);
    });

    test('retarget keeps the queue and sends it to the new PC and folder', () async {
      final first = FakeUploadApi();
      final second = FakeUploadApi();
      final controller = TransferController(api: first, chunkSize: 512);
      controller.addFiles([
        _source('a.bin', _pattern(100)),
        _source('b.bin', _pattern(200)),
      ]);

      await controller.run();
      expect(controller.items.every((i) => i.state == TransferState.done), isTrue);
      expect(first.createFolders, ['default', 'default']);

      controller.retarget(api: second, folderId: 'backup-other');
      expect(controller.items, hasLength(2));
      expect(controller.items.every((i) => i.state == TransferState.queued), isTrue);
      expect(controller.api, same(second));
      expect(controller.folderId, 'backup-other');

      // Adding after the switch joins the very same queue.
      controller.addFiles([_source('c.bin', _pattern(50))]);
      await controller.run();

      expect(first.createCalls, 2);
      expect(second.createCalls, 3);
      expect(second.createFolders, ['backup-other', 'backup-other', 'backup-other']);
      expect(second.commitPaths, ['a.bin', 'b.bin', 'c.bin']);
      expect(controller.items.every((i) => i.state == TransferState.done), isTrue);
    });

    test('retarget resets failed items so they are retried on the new PC', () async {
      final first = FakeUploadApi(failAppend: true);
      final second = FakeUploadApi();
      final controller = TransferController(api: first, chunkSize: 128);
      controller.addFiles([_source('bad.bin', _pattern(200))]);

      await controller.run();
      expect(controller.items.single.state, TransferState.failed);

      controller.retarget(api: second, folderId: 'backup-other');
      expect(controller.items.single.state, TransferState.queued);
      expect(controller.items.single.error, isNull);

      await controller.run();
      expect(controller.items.single.state, TransferState.done);
      expect(second.commitPaths, ['bad.bin']);
    });

    test('retarget refuses while a transfer is running', () async {
      late TransferController controller;
      StateError? refused;
      final api = FakeUploadApi(onCommit: () {
        // onCommit runs mid-transfer, while the old upload ticket is still in flight.
        try {
          controller.retarget(api: FakeUploadApi(), folderId: 'other');
        } on StateError catch (error) {
          refused = error;
        }
      });
      controller = TransferController(api: api, chunkSize: 128);
      controller.addFiles([_source('one.bin', _pattern(100))]);

      await controller.run();

      expect(refused, isNotNull);
      expect(controller.folderId, 'default');
      expect(controller.items.single.state, TransferState.done);
    });

    test('ignores duplicate picks of the same name and size', () {
      final controller = TransferController(api: FakeUploadApi());
      controller.addFiles([_source('x.jpg', _pattern(10))]);
      controller.addFiles([_source('x.jpg', _pattern(10))]);
      expect(controller.items, hasLength(1));
    });

    test('cancel stops before the next file', () async {
      late TransferController controller;
      final api = FakeUploadApi(onCommit: () => controller.cancel());
      controller = TransferController(api: api, chunkSize: 128);
      controller.addFiles([
        _source('one.bin', _pattern(100)),
        _source('two.bin', _pattern(100)),
      ]);

      await controller.run();

      // The first file finishes; the cancel raised on its commit stops the queue.
      expect(controller.items[0].state, TransferState.done);
      expect(controller.items[1].state, TransferState.queued);
      expect(api.createCalls, 1);
    });
  });
}

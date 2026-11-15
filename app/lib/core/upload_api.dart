// The slice of the PC API the transfer engine depends on.
//
// Keeping it an interface — rather than calling CloudBoxClient directly — lets the engine be
// tested against a fake that can simulate a dropped connection or a 409 resume without a live
// socket, which is exactly the behaviour that is hardest to exercise by hand.

import 'models.dart';

/// Upload operations the transfer engine needs, as implemented by [CloudBoxClient].
abstract interface class UploadApi {
  /// Reserves an upload for content with [hash] and [size] bytes in [folderId].
  ///
  /// The returned ticket may already be [UploadTicket.complete], in which case the bytes are
  /// cached on the PC and only a commit is needed.
  Future<UploadTicket> createUpload({
    required String hash,
    required int size,
    String folderId,
  });

  /// Appends [chunk] at [offset] and returns the server's new confirmed offset.
  ///
  /// A server that has more bytes than [offset] answers with a `409` carrying the real offset;
  /// [CloudBoxClient] surfaces that as a [CloudBoxException] with [CloudBoxException.offset].
  Future<int> appendUpload(
    String uploadId, {
    required int offset,
    required List<int> chunk,
    required int totalSize,
  });

  /// Asks the server where an interrupted upload should resume.
  Future<UploadStatus> uploadStatus(String uploadId);

  /// Finalises an upload into the sync folder at [path].
  Future<CommitResult> commitUpload(
    String uploadId, {
    required String hash,
    required String path,
    int? mtimeMs,
  });
}

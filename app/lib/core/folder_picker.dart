// Dart side of the Android SAF folder picker.
//
// The native plugin copies every document in the picked tree into a private cache directory and
// returns ordinary file paths plus the path each file should take on the PC. Keeping the mapping
// in a pure function makes it testable without a device: [sourceFilesFromFolder] only needs
// [FolderFile] values, which the tests can build by hand.

import 'dart:io';

import 'package:flutter/services.dart';

import 'transfer.dart';

/// One file staged by the native folder picker.
class FolderFile {
  const FolderFile({
    required this.relativePath,
    required this.path,
    required this.size,
  });

  /// Slash-separated destination path, starting with the picked folder's name.
  final String relativePath;

  /// A readable file in the app cache.
  final String path;

  final int size;
}

/// Result of [FolderPicker.pickFolder]: the staged files, or null when the user cancelled.
typedef FolderPickResult = Future<List<FolderFile>?> Function();

/// Talks to [FolderPickerPlugin] on Android.
abstract final class FolderPicker {
  static const MethodChannel _channel = MethodChannel('dev.cloudbox.cloudbox/folder');

  /// Opens the system folder picker and stages the whole tree. Returns null on cancel.
  static Future<List<FolderFile>?> pickFolder() async {
    final List<Map<Object?, Object?>>? raw;
    try {
      raw = await _channel.invokeListMethod<Map<Object?, Object?>>('pickFolder');
    } on PlatformException catch (error) {
      throw FolderPickerException(error.message ?? 'Could not open that folder.');
    }
    if (raw == null) return null;

    return raw.map((map) {
      final relativePath = map['relativePath'] as String? ?? '';
      final path = map['path'] as String? ?? '';
      final size = map['size'] as int? ?? 0;
      return FolderFile(relativePath: relativePath, path: path, size: size);
    }).where((file) => file.relativePath.isNotEmpty && file.path.isNotEmpty).toList(growable: false);
  }

  /// Frees cached copies from earlier picks. Safe to call before opening the picker again.
  static Future<void> clearCache() async {
    try {
      await _channel.invokeMethod<void>('clearCache');
    } on Object {
      // A stale cache is only wasted space; it must never block a folder pick.
    }
  }
}

class FolderPickerException implements Exception {
  const FolderPickerException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Turns staged files into transfer sources. The native side already preserves the relative path
/// (including the picked folder's name), so no further path rewriting is needed here.
List<SourceFile> sourceFilesFromFolder(Iterable<FolderFile> files) {
  return files.map((file) {
    return SourceFile(
      name: file.relativePath,
      size: file.size,
      openRead: () => File(file.path).openRead().map(
            (chunk) => chunk is Uint8List ? chunk : Uint8List.fromList(chunk),
          ),
    );
  }).toList(growable: false);
}

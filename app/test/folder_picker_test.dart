import 'dart:io';

import 'package:cloudbox/core/folder_picker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('staged files keep their slash-separated destination paths', () {
    final sources = sourceFilesFromFolder(const [
      FolderFile(relativePath: 'DCIM/Camera/IMG_001.jpg', path: '/cache/one.jpg', size: 3),
      FolderFile(relativePath: 'DCIM/notes.txt', path: '/cache/notes.txt', size: 5),
    ]);

    expect(sources.map((s) => s.name), [
      'DCIM/Camera/IMG_001.jpg',
      'DCIM/notes.txt',
    ]);
    expect(sources.map((s) => s.size), [3, 5]);
    expect(sources.map((s) => s.path), ['/cache/one.jpg', '/cache/notes.txt']);
  });

  test('a staged source reopens and reads its file', () async {
    final dir = await Directory.systemTemp.createTemp('cloudbox-folder-test-');
    addTearDown(() => dir.delete(recursive: true));
    final staged = File('${dir.path}${Platform.pathSeparator}staged.bin');
    await staged.writeAsBytes(const [1, 2, 3, 4]);

    final source = sourceFilesFromFolder([
      FolderFile(
        relativePath: 'Pictures/Album/staged.bin',
        path: staged.path,
        size: 4,
      ),
    ]).single;

    final bytes = await source.openRead().expand((chunk) => chunk).toList();
    expect(bytes, [1, 2, 3, 4]);
    expect(source.name, 'Pictures/Album/staged.bin');
  });
}

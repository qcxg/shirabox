import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

import 'adb_core.dart';
import 'ascii_staging.dart';
import 'local_path_codec.dart';
import 'operation_context.dart';
import 'owned_process.dart';

class _ExtractionBudget {
  _ExtractionBudget(this.limit);

  final int limit;
  int written = 0;

  void claim(int count) {
    if (count < 0 || written + count > limit) {
      throw const FormatException(
        'Archive expands beyond the total extraction limit.',
      );
    }
    written += count;
  }
}

/// Counts bytes emitted by the decoder instead of trusting ZIP metadata.
class _LimitedOutputStream extends OutputStream {
  _LimitedOutputStream(
    this._delegate, {
    required this.entryLimit,
    required this.budget,
  }) : super(byteOrder: _delegate.byteOrder);

  final OutputStream _delegate;
  final int entryLimit;
  final _ExtractionBudget budget;
  int _written = 0;

  @override
  int get length => _written;

  @override
  bool get isOpen => _delegate.isOpen;

  void _claim(int count) {
    if (count < 0 || _written + count > entryLimit) {
      throw const FormatException(
        'An APK expands beyond the per-entry extraction limit.',
      );
    }
    budget.claim(count);
    _written += count;
  }

  @override
  void clear() => _delegate.clear();

  @override
  void flush() => _delegate.flush();

  @override
  void writeByte(int value) {
    _claim(1);
    _delegate.writeByte(value);
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    final count = length ?? bytes.length;
    if (count > bytes.length) {
      throw const FormatException('Decoder emitted an invalid byte count.');
    }
    _claim(count);
    _delegate.writeBytes(bytes, length: count);
  }

  @override
  void writeStream(InputStream stream) {
    const chunkSize = 1024 * 1024;
    while (!stream.isEOS) {
      final remaining = stream.length;
      if (remaining <= 0) break;
      final count = min(chunkSize, remaining);
      final bytes = stream.readBytes(count).toUint8List();
      if (bytes.isEmpty) {
        throw const FormatException('Archive decoder stopped unexpectedly.');
      }
      writeBytes(bytes);
    }
  }

  @override
  Uint8List subset(int start, [int? end]) => _delegate.subset(start, end);
}

Future<void> _zipTask(Map<String, dynamic> args) async {
  final filesMap = args['files'] as Map<String, String>;
  final destPath = args['dest'] as String;
  final outputStream = OutputFileStream(destPath);
  final encoder = ZipEncoder();
  encoder.startEncode(outputStream);
  try {
    for (final entry in filesMap.entries) {
      final srcFile = File(entry.key);
      final entryName = entry.value;
      if (await srcFile.exists()) {
        final inputStream = InputFileStream(srcFile.path);
        final archiveFile = ArchiveFile.stream(entryName, inputStream);
        archiveFile.lastModTime =
            srcFile.lastModifiedSync().millisecondsSinceEpoch ~/ 1000;
        encoder.add(archiveFile);
        await inputStream.close();
      }
    }
  } catch (e) {
    debugPrint("Zip Error: $e");
    rethrow;
  } finally {
    encoder.endEncode();
    await outputStream.close();
  }
}

Future<void> preflightInstallArchive(File source) async {
  const eocdLength = 22;
  const centralHeaderLength = 46;
  const centralHeaderSignature = 0x02014b50;
  const maxCommentLength = 0xffff;
  const maxEntries = 1024;
  const maxCentralDirectoryBytes = 32 * 1024 * 1024;
  final length = await source.length();
  if (length < eocdLength) {
    throw const FormatException('Archive is too short to be a ZIP file.');
  }

  final tailLength = min(length, eocdLength + maxCommentLength);
  final handle = await source.open();
  late final List<int> tail;
  try {
    await handle.setPosition(length - tailLength);
    tail = await handle.read(tailLength);
  } finally {
    await handle.close();
  }

  var eocdOffset = -1;
  for (var index = tail.length - eocdLength; index >= 0; index--) {
    if (tail[index] == 0x50 &&
        tail[index + 1] == 0x4b &&
        tail[index + 2] == 0x05 &&
        tail[index + 3] == 0x06) {
      final candidateCommentLength = tail[index + 20] | (tail[index + 21] << 8);
      if (index + eocdLength + candidateCommentLength == tail.length) {
        eocdOffset = index;
        break;
      }
    }
  }
  if (eocdOffset < 0) {
    throw const FormatException('ZIP end-of-central-directory is missing.');
  }

  final data = ByteData.sublistView(Uint8List.fromList(tail));
  final diskNumber = data.getUint16(eocdOffset + 4, Endian.little);
  final centralDisk = data.getUint16(eocdOffset + 6, Endian.little);
  final entriesOnDisk = data.getUint16(eocdOffset + 8, Endian.little);
  final totalEntries = data.getUint16(eocdOffset + 10, Endian.little);
  final centralSize = data.getUint32(eocdOffset + 12, Endian.little);
  final centralOffset = data.getUint32(eocdOffset + 16, Endian.little);
  final commentLength = data.getUint16(eocdOffset + 20, Endian.little);
  if (diskNumber != 0 || centralDisk != 0 || entriesOnDisk != totalEntries) {
    throw UnsupportedError('Multi-disk ZIP archives are not supported.');
  }
  if (totalEntries == 0xffff ||
      centralSize == 0xffffffff ||
      centralOffset == 0xffffffff) {
    throw UnsupportedError('ZIP64 install archives are not supported.');
  }
  if (totalEntries > maxEntries || centralSize > maxCentralDirectoryBytes) {
    throw const FormatException('ZIP central directory exceeds safety limits.');
  }
  final eocdAbsolute = length - tailLength + eocdOffset;
  if (eocdOffset + eocdLength + commentLength > tail.length ||
      centralOffset + centralSize != eocdAbsolute) {
    throw const FormatException('ZIP central directory is malformed.');
  }

  final centralHandle = await source.open();
  late final Uint8List centralDirectory;
  try {
    await centralHandle.setPosition(centralOffset);
    centralDirectory = Uint8List(centralSize);
    var bytesRead = 0;
    while (bytesRead < centralSize) {
      final count = await centralHandle.readInto(
        centralDirectory,
        bytesRead,
        centralSize,
      );
      if (count == 0) {
        throw const FormatException('ZIP central directory is truncated.');
      }
      bytesRead += count;
    }
  } finally {
    await centralHandle.close();
  }

  final centralData = ByteData.sublistView(centralDirectory);
  var cursor = 0;
  var actualEntries = 0;
  while (cursor < centralDirectory.length) {
    if (centralDirectory.length - cursor < centralHeaderLength ||
        centralData.getUint32(cursor, Endian.little) !=
            centralHeaderSignature) {
      throw const FormatException(
        'ZIP central directory contains an invalid record.',
      );
    }

    final compressedSize = centralData.getUint32(cursor + 20, Endian.little);
    final uncompressedSize = centralData.getUint32(cursor + 24, Endian.little);
    final nameLength = centralData.getUint16(cursor + 28, Endian.little);
    final extraLength = centralData.getUint16(cursor + 30, Endian.little);
    final entryCommentLength = centralData.getUint16(
      cursor + 32,
      Endian.little,
    );
    final startingDisk = centralData.getUint16(cursor + 34, Endian.little);
    final localHeaderOffset = centralData.getUint32(
      cursor + 42,
      Endian.little,
    );

    if (startingDisk != 0) {
      throw UnsupportedError('Multi-disk ZIP archives are not supported.');
    }
    if (compressedSize == 0xffffffff ||
        uncompressedSize == 0xffffffff ||
        localHeaderOffset == 0xffffffff) {
      throw UnsupportedError('ZIP64 install archives are not supported.');
    }

    final recordLength =
        centralHeaderLength + nameLength + extraLength + entryCommentLength;
    if (cursor + recordLength > centralDirectory.length) {
      throw const FormatException(
        'ZIP central-directory record exceeds its declared boundary.',
      );
    }

    cursor += recordLength;
    actualEntries++;
    if (actualEntries > maxEntries) {
      throw const FormatException(
          'ZIP central directory exceeds safety limits.');
    }
  }

  if (cursor != centralDirectory.length || actualEntries != totalEntries) {
    throw const FormatException(
      'ZIP central-directory entry count does not match its records.',
    );
  }
}

Future<List<String>> _unzipTask(Map<String, String> arguments) async {
  const maxArchiveBytes = 4 * 1024 * 1024 * 1024;
  const maxApkEntries = 256;
  const maxSingleApkBytes = 1024 * 1024 * 1024;
  const maxTotalApkBytes = 2 * 1024 * 1024 * 1024;
  final zipPath = arguments['zipPath'];
  final tempPath = arguments['tempPath'];
  if (zipPath == null || tempPath == null) {
    throw const FormatException('Missing archive extraction arguments.');
  }
  final archiveSource = File(zipPath);
  if (!await archiveSource.exists()) {
    throw FileSystemException('Archive does not exist.', zipPath);
  }
  if (await archiveSource.length() > maxArchiveBytes) {
    throw const FormatException('Archive is larger than the safety limit.');
  }
  await preflightInstallArchive(archiveSource);

  final inputStream = InputFileStream(zipPath);
  final tempDir = Directory(tempPath);
  if (!await tempDir.exists()) {
    throw FileSystemException(
        'Archive staging directory does not exist.', tempPath);
  }
  final extractedFiles = <String>[];
  final extractionBudget = _ExtractionBudget(maxTotalApkBytes);
  var declaredTotalBytes = 0;

  try {
    final archive = ZipDecoder().decodeStream(inputStream);
    final lowerNames = archive
        .where((entry) => entry.isFile)
        .map((entry) => entry.name.replaceAll('\\', '/').toLowerCase())
        .toList(growable: false);
    if (p.extension(zipPath).toLowerCase() == '.apks' &&
        lowerNames.any((name) => p.posix.basename(name) == 'toc.pb')) {
      throw UnsupportedError(
        'Bundletool APKS variant selection is not implemented.',
      );
    }
    if (lowerNames.any(
      (name) => name.endsWith('.obb') || name.contains('/android/obb/'),
    )) {
      throw UnsupportedError(
        'XAPK archives containing OBB payloads are not supported safely.',
      );
    }
    for (final file in archive) {
      if (!file.isFile || !file.name.toLowerCase().endsWith('.apk')) continue;
      if (extractedFiles.length >= maxApkEntries) {
        throw const FormatException('Archive contains too many APK entries.');
      }

      final size = file.size;
      if (size < 0 || size > maxSingleApkBytes) {
        throw FormatException('APK entry has an invalid size: ${file.name}');
      }
      declaredTotalBytes += size;
      if (declaredTotalBytes > maxTotalApkBytes) {
        throw const FormatException('Archive expands beyond the safety limit.');
      }

      // Archive entry names are untrusted. Extract to generated ASCII names so
      // traversal, invalid Windows characters, and duplicate names are inert.
      final safeName =
          'apk_${extractedFiles.length.toString().padLeft(4, '0')}.apk';
      final outFile = File(p.join(tempDir.path, safeName));
      await outFile.create();
      final outputStream = OutputFileStream(outFile.path);
      final limitedOutput = _LimitedOutputStream(
        outputStream,
        entryLimit: maxSingleApkBytes,
        budget: extractionBudget,
      );
      try {
        file.writeContent(limitedOutput);
        limitedOutput.flush();
        if (limitedOutput.length != size) {
          throw FormatException(
            'APK size does not match archive metadata: ${file.name}',
          );
        }
      } finally {
        await outputStream.close();
      }
      extractedFiles.add(outFile.path);
    }
    return extractedFiles;
  } finally {
    await inputStream.close();
  }
}

String quoteRemoteShellArg(String value) {
  if (value.contains('\u0000')) {
    throw const FormatException('Remote paths cannot contain NUL bytes.');
  }
  return "'${value.replaceAll("'", "'\"'\"'")}'";
}

enum AdbFileType { file, directory, symlink, other }

enum RecursiveSymlinkPolicy { skip, reject }

const _smallTransferBatchBytes = 4 * 1024 * 1024;
const _smallTransferBatchFiles = 32;
const _smallTransferBatchArgumentBytes = 12000;

class RecursiveTransferLimits {
  const RecursiveTransferLimits({
    this.maxDepth = 32,
    this.maxEntries = 50000,
    this.maxTotalBytes = 50 * 1024 * 1024 * 1024,
    this.maxSingleFileBytes = 16 * 1024 * 1024 * 1024,
  });

  final int maxDepth;
  final int maxEntries;
  final int maxTotalBytes;
  final int maxSingleFileBytes;

  void validate() {
    if (maxDepth <= 0 ||
        maxEntries <= 0 ||
        maxTotalBytes < 0 ||
        maxSingleFileBytes < 0 ||
        maxSingleFileBytes > maxTotalBytes) {
      throw ArgumentError('Recursive transfer limits are invalid.');
    }
  }
}

class TransferCancelledException implements Exception {
  const TransferCancelledException();

  @override
  String toString() => 'Transfer cancelled.';
}

class RecursiveTransferEntry {
  const RecursiveTransferEntry({
    required this.path,
    required this.relativeComponents,
    required this.type,
    required this.size,
  });

  final String path;
  final List<String> relativeComponents;
  final AdbFileType type;
  final int size;

  int get depth => relativeComponents.length;
}

class RecursiveTransferManifest {
  const RecursiveTransferManifest({
    required this.entries,
    required this.totalBytes,
    required this.skippedSymlinks,
  });

  final List<RecursiveTransferEntry> entries;
  final int totalBytes;
  final int skippedSymlinks;
}

/// Scans a local tree without following links and applies safety quotas before
/// any device mutation starts. The stable order also makes collision mapping
/// deterministic when the same tree is retried.
Future<RecursiveTransferManifest> scanLocalTransferTree(
  String localPath, {
  RecursiveTransferLimits limits = const RecursiveTransferLimits(),
  RecursiveSymlinkPolicy symlinkPolicy = RecursiveSymlinkPolicy.skip,
  bool Function()? isCancelled,
}) async {
  limits.validate();
  _throwIfTransferCancelled(isCancelled);
  final root = p.normalize(p.absolute(localPath));
  final rootType = await FileSystemEntity.type(root, followLinks: false);
  if (rootType == FileSystemEntityType.link) {
    throw FileSystemException(
      'The transfer root cannot be a symbolic link.',
      localPath,
    );
  }
  if (rootType != FileSystemEntityType.directory) {
    throw FileSystemException('Transfer root is not a directory.', localPath);
  }

  final entries = <RecursiveTransferEntry>[];
  final pending = <_LocalDirectoryScan>[
    _LocalDirectoryScan(Directory(root), const <String>[]),
  ];
  var totalBytes = 0;
  var visitedEntries = 0;
  var skippedSymlinks = 0;
  while (pending.isNotEmpty) {
    _throwIfTransferCancelled(isCancelled);
    final current = pending.removeLast();
    final children = <FileSystemEntity>[];
    await for (final child in current.directory.list(followLinks: false)) {
      _throwIfTransferCancelled(isCancelled);
      // Bound the per-directory buffer before sorting. The global quota is
      // checked again when each buffered entry is consumed.
      if (children.length >= limits.maxEntries - visitedEntries) {
        throw const FormatException(
          'Directory tree exceeds the recursive entry limit.',
        );
      }
      children.add(child);
    }
    children.sort((a, b) {
      final aName = p.basename(a.path);
      final bName = p.basename(b.path);
      final insensitive = aName.toLowerCase().compareTo(bName.toLowerCase());
      return insensitive != 0 ? insensitive : aName.compareTo(bName);
    });
    // Reverse insertion keeps the depth-first traversal lexically stable.
    final directories = <_LocalDirectoryScan>[];
    for (final child in children) {
      _throwIfTransferCancelled(isCancelled);
      final name = p.basename(child.path);
      if (name.isEmpty ||
          name == '.' ||
          name == '..' ||
          name.contains('\u0000')) {
        throw FileSystemException('Unsafe local path component.', child.path);
      }
      final components = List<String>.unmodifiable(
        <String>[...current.components, name],
      );
      if (components.length > limits.maxDepth) {
        throw const FormatException(
          'Directory tree exceeds the recursive depth limit.',
        );
      }
      if (++visitedEntries > limits.maxEntries) {
        throw const FormatException(
          'Directory tree exceeds the recursive entry limit.',
        );
      }
      if (!p.isWithin(root, p.normalize(p.absolute(child.path)))) {
        throw FileSystemException(
          'Directory entry escaped the transfer root.',
          child.path,
        );
      }

      // Directory.list already reports concrete entity classes when links are
      // not followed. Reusing that result avoids a second metadata syscall for
      // every entry; retain the type() fallback for unusual platform entities.
      final listedType = _listedEntityType(child);
      final type = listedType ??
          await FileSystemEntity.type(child.path, followLinks: false);
      if (type == FileSystemEntityType.link) {
        if (symlinkPolicy == RecursiveSymlinkPolicy.reject) {
          throw FileSystemException(
            'Symbolic links are not allowed in recursive transfers.',
            child.path,
          );
        }
        skippedSymlinks++;
        continue;
      }
      if (type == FileSystemEntityType.directory) {
        entries.add(RecursiveTransferEntry(
          path: child.path,
          relativeComponents: components,
          type: AdbFileType.directory,
          size: 0,
        ));
        directories.add(_LocalDirectoryScan(Directory(child.path), components));
        continue;
      }
      if (type == FileSystemEntityType.file) {
        final size = await File(child.path).length();
        _claimTransferBytes(size, limits, totalBytes);
        totalBytes += size;
        entries.add(RecursiveTransferEntry(
          path: child.path,
          relativeComponents: components,
          type: AdbFileType.file,
          size: size,
        ));
        continue;
      }
      throw FileSystemException(
        'Unsupported filesystem entry in recursive transfer.',
        child.path,
      );
    }
    for (final directory in directories.reversed) {
      pending.add(directory);
    }
  }
  entries.sort(_compareTransferEntries);
  return RecursiveTransferManifest(
    entries: List.unmodifiable(entries),
    totalBytes: totalBytes,
    skippedSymlinks: skippedSymlinks,
  );
}

FileSystemEntityType? _listedEntityType(FileSystemEntity entity) {
  if (entity is Link) return FileSystemEntityType.link;
  if (entity is Directory) return FileSystemEntityType.directory;
  if (entity is File) return FileSystemEntityType.file;
  return null;
}

class _LocalDirectoryScan {
  const _LocalDirectoryScan(this.directory, this.components);

  final Directory directory;
  final List<String> components;
}

void _claimTransferBytes(
  int size,
  RecursiveTransferLimits limits,
  int bytesAlreadyClaimed,
) {
  if (size < 0 || size > limits.maxSingleFileBytes) {
    throw const FormatException(
      'A file exceeds the recursive per-file byte limit.',
    );
  }
  if (bytesAlreadyClaimed > limits.maxTotalBytes - size) {
    throw const FormatException(
      'Directory tree exceeds the recursive total-byte limit.',
    );
  }
}

int _compareTransferEntries(
  RecursiveTransferEntry a,
  RecursiveTransferEntry b,
) {
  if (a.depth != b.depth) return a.depth.compareTo(b.depth);
  if (a.type == AdbFileType.directory && b.type != AdbFileType.directory) {
    return -1;
  }
  if (a.type != AdbFileType.directory && b.type == AdbFileType.directory) {
    return 1;
  }
  return a.relativeComponents.join('\u0000').compareTo(
        b.relativeComponents.join('\u0000'),
      );
}

class AdbDirectoryPage {
  const AdbDirectoryPage({
    required this.entries,
    required this.pageIndex,
    required this.isLast,
  });

  final List<AdbFile> entries;
  final int pageIndex;
  final bool isLast;
}

/// Incrementally decodes the NUL-framed `kind, absolute path` records emitted
/// by the device-side directory scanner. A frame is bounded so a corrupt or
/// hostile device cannot make one filename grow host memory without limit.
class DeviceDirectoryListingDecoder {
  DeviceDirectoryListingDecoder(
    String targetPath, {
    this.maxEntries = 100000,
    this.maxFieldBytes = 64 * 1024,
  }) : targetPath = p.posix.normalize(targetPath) {
    if (!this.targetPath.startsWith('/')) {
      throw const FormatException('Remote path must be absolute.');
    }
    if (maxEntries <= 0 || maxFieldBytes <= 0) {
      throw ArgumentError('Listing limits must be positive.');
    }
  }

  final String targetPath;
  final int maxEntries;
  final int maxFieldBytes;
  final BytesBuilder _field = BytesBuilder(copy: false);
  final List<String> _record = <String>[];
  int _entries = 0;

  List<AdbFile> addBytes(List<int> bytes) {
    final decoded = <AdbFile>[];
    for (final byte in bytes) {
      if (byte == 0) {
        final field = utf8.decode(_field.takeBytes());
        _record.add(field);
        if (_record.length == 2) {
          if (++_entries > maxEntries) {
            throw const FormatException(
              'Device directory exceeds the entry safety limit.',
            );
          }
          decoded.add(_decodeEntry(_record[0], _record[1]));
          _record.clear();
        }
      } else {
        if (_field.length >= maxFieldBytes) {
          throw const FormatException(
            'Device directory contains an oversized filename frame.',
          );
        }
        _field.addByte(byte);
      }
    }
    return decoded;
  }

  void finish() {
    if (_field.length != 0 || _record.isNotEmpty) {
      throw const FormatException('Truncated device directory listing.');
    }
  }

  AdbFile _decodeEntry(String kind, String fullPath) {
    final type = switch (kind) {
      'D' => AdbFileType.directory,
      'F' => AdbFileType.file,
      'L' => AdbFileType.symlink,
      'O' => AdbFileType.other,
      _ => throw const FormatException('Malformed device directory listing.'),
    };
    final expectedPrefix = targetPath == '/' ? '/' : '$targetPath/';
    if (!fullPath.startsWith(expectedPrefix)) {
      throw const FormatException('Malformed device directory listing.');
    }
    final name = fullPath.substring(expectedPrefix.length);
    if (name.isEmpty || name == '.' || name == '..' || name.contains('/')) {
      throw const FormatException('Unsafe device directory entry.');
    }
    return AdbFile.typed(name: name, path: fullPath, type: type);
  }
}

/// Incremental decoder for recursive `kind, path, byte size` records.
class RemoteTreeListingDecoder {
  RemoteTreeListingDecoder(
    String rootPath, {
    this.limits = const RecursiveTransferLimits(),
    this.symlinkPolicy = RecursiveSymlinkPolicy.skip,
    this.maxFieldBytes = 64 * 1024,
  }) : rootPath = p.posix.normalize(rootPath) {
    limits.validate();
    if (maxFieldBytes <= 0) {
      throw ArgumentError('Remote listing field limit must be positive.');
    }
    if (!this.rootPath.startsWith('/') || this.rootPath == '/') {
      throw const FormatException(
        'Recursive remote source must be an absolute non-root path.',
      );
    }
  }

  final String rootPath;
  final RecursiveTransferLimits limits;
  final RecursiveSymlinkPolicy symlinkPolicy;
  final int maxFieldBytes;
  final BytesBuilder _field = BytesBuilder(copy: false);
  final List<String> _record = <String>[];
  final List<RecursiveTransferEntry> _entries = <RecursiveTransferEntry>[];
  int _visitedEntries = 0;
  int _totalBytes = 0;
  int _skippedSymlinks = 0;

  List<RecursiveTransferEntry> addBytes(List<int> bytes) {
    final emitted = <RecursiveTransferEntry>[];
    for (final byte in bytes) {
      if (byte == 0) {
        _record.add(utf8.decode(_field.takeBytes()));
        if (_record.length == 3) {
          final entry = _decodeRecord(_record[0], _record[1], _record[2]);
          if (entry != null) {
            _entries.add(entry);
            emitted.add(entry);
          }
          _record.clear();
        }
      } else {
        if (_field.length >= maxFieldBytes) {
          throw const FormatException(
            'Remote tree contains an oversized filename frame.',
          );
        }
        _field.addByte(byte);
      }
    }
    return emitted;
  }

  RecursiveTransferManifest finish() {
    if (_field.length != 0 || _record.isNotEmpty) {
      throw const FormatException('Truncated remote tree listing.');
    }
    _entries.sort(_compareTransferEntries);
    return RecursiveTransferManifest(
      entries: List.unmodifiable(_entries),
      totalBytes: _totalBytes,
      skippedSymlinks: _skippedSymlinks,
    );
  }

  RecursiveTransferEntry? _decodeRecord(
    String kind,
    String fullPath,
    String sizeField,
  ) {
    if (++_visitedEntries > limits.maxEntries) {
      throw const FormatException(
        'Remote tree exceeds the recursive entry limit.',
      );
    }
    final prefix = '$rootPath/';
    if (!fullPath.startsWith(prefix)) {
      throw const FormatException('Remote tree entry escaped its source root.');
    }
    final relative = fullPath.substring(prefix.length);
    final components = relative.split('/');
    if (components.isEmpty ||
        components.length > limits.maxDepth ||
        components.any(
          (part) =>
              part.isEmpty ||
              part == '.' ||
              part == '..' ||
              part.contains('\u0000'),
        )) {
      throw const FormatException('Unsafe remote tree entry.');
    }
    final size = int.tryParse(sizeField);
    if (size == null || size < 0) {
      throw const FormatException('Remote tree has invalid size metadata.');
    }
    final type = switch (kind) {
      'D' => AdbFileType.directory,
      'F' => AdbFileType.file,
      'L' => AdbFileType.symlink,
      'O' => AdbFileType.other,
      _ => throw const FormatException('Remote tree has an invalid type.'),
    };
    if (type == AdbFileType.symlink) {
      if (symlinkPolicy == RecursiveSymlinkPolicy.reject) {
        throw const FormatException(
          'Remote tree contains a symbolic link.',
        );
      }
      _skippedSymlinks++;
      return null;
    }
    if (type == AdbFileType.other) {
      throw const FormatException(
        'Remote tree contains an unsupported filesystem entry.',
      );
    }
    if (type == AdbFileType.directory && size != 0) {
      throw const FormatException(
          'Remote directory has invalid size metadata.');
    }
    if (type == AdbFileType.file) {
      _claimTransferBytes(size, limits, _totalBytes);
      _totalBytes += size;
    }
    return RecursiveTransferEntry(
      path: fullPath,
      relativeComponents: List.unmodifiable(components),
      type: type,
      size: size,
    );
  }
}

List<AdbFile> parseDeviceDirectoryListing(String output, String targetPath) {
  final decoder = DeviceDirectoryListingDecoder(targetPath);
  final files = decoder.addBytes(utf8.encode(output));
  decoder.finish();
  files.sort((a, b) {
    if (a.isDir && !b.isDir) return -1;
    if (!a.isDir && b.isDir) return 1;
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  });
  return files;
}

class AdbFileService {
  final AdbCore _core;
  static int _nextJobId = 0;

  AdbFileService(this._core);

  /// Compatibility API. New UIs should consume [listFilePages] so the first
  /// rows can render before a large directory has completely finished.
  Future<List<AdbFile>> listFiles(
    String path, {
    String? serial,
    int maxEntries = 100000,
  }) async {
    final files = <AdbFile>[];
    await for (final page in listFilePages(
      path,
      serial: serial,
      maxEntries: maxEntries,
    )) {
      files.addAll(page.entries);
    }
    files.sort(_compareAdbFiles);
    return files;
  }

  /// Streams bounded, page-locally sorted pages from one shell process instead
  /// of capturing one giant stdout string. Cancelling the subscription kills
  /// the owned scanner. Consumers may globally sort after the terminal page.
  Stream<AdbDirectoryPage> listFilePages(
    String path, {
    String? serial,
    int pageSize = 256,
    int maxEntries = 100000,
  }) async* {
    if (pageSize <= 0 || pageSize > 2048) {
      throw ArgumentError('pageSize must be between 1 and 2048.');
    }
    if (maxEntries <= 0) {
      throw ArgumentError('maxEntries must be positive.');
    }
    final deviceSerial = serial ?? _core.targetSerial;
    final requested = path.trim().isEmpty ? '/' : path;
    final targetPath = p.posix.normalize(requested);
    if (!targetPath.startsWith('/')) {
      throw const FormatException('Remote path must be absolute.');
    }

    final quotedPath = quoteRemoteShellArg(targetPath);
    final directoryPrefix = targetPath == '/' ? '/' : '$targetPath/';
    final quotedPrefix = quoteRemoteShellArg(directoryPrefix);
    final command = '''
if [ ! -d $quotedPath ]; then echo 'Not a directory' >&2; exit 20; fi
if [ ! -r $quotedPath ]; then echo 'Directory is not readable' >&2; exit 21; fi
for entry in $quotedPrefix* $quotedPrefix.[!.]* $quotedPrefix..?*; do
  if [ ! -e "\$entry" ] && [ ! -L "\$entry" ]; then continue; fi
  if [ -L "\$entry" ]; then
    printf 'L\\0%s\\0' "\$entry"
  elif [ -d "\$entry" ]; then
    printf 'D\\0%s\\0' "\$entry"
  elif [ -f "\$entry" ]; then
    printf 'F\\0%s\\0' "\$entry"
  else
    printf 'O\\0%s\\0' "\$entry"
  fi
done
''';
    OwnedCommandHandle? process;
    Future<String>? stderrFuture;
    var exitedNormally = false;
    try {
      process = await _core.startOwnedProcess(
        ['shell', command],
        serial: deviceSerial,
      );
      stderrFuture = _captureBoundedText(process.stderr);
      final decoder = DeviceDirectoryListingDecoder(
        targetPath,
        maxEntries: maxEntries,
      );
      var page = <AdbFile>[];
      var pageIndex = 0;
      await for (final chunk in process.stdout.timeout(
        const Duration(seconds: 30),
      )) {
        for (final entry in decoder.addBytes(chunk)) {
          page.add(entry);
          if (page.length == pageSize) {
            page.sort(_compareAdbFiles);
            yield AdbDirectoryPage(
              entries: List.unmodifiable(page),
              pageIndex: pageIndex++,
              isLast: false,
            );
            page = <AdbFile>[];
          }
        }
      }
      final exit = await process.done.timeout(
        const Duration(seconds: 30),
      );
      final stderr = await stderrFuture;
      if (exit.reason == OwnedCommandEndReason.cancelled) {
        throw const AdbCommandException('Directory listing was cancelled.');
      }
      if (exit.exitCode != 0) {
        throw AdbCommandException(
          stderr.trim().isEmpty ? 'Unable to list $targetPath.' : stderr.trim(),
          exitCode: exit.exitCode,
        );
      }
      decoder.finish();
      page.sort(_compareAdbFiles);
      yield AdbDirectoryPage(
        entries: List.unmodifiable(page),
        pageIndex: pageIndex,
        isLast: true,
      );
      exitedNormally = true;
    } finally {
      if (!exitedNormally && process != null) {
        try {
          if (!process.isCompleted) await process.cancel();
        } catch (_) {}
      }
      if (stderrFuture != null) {
        try {
          await stderrFuture.timeout(const Duration(seconds: 2));
        } catch (_) {}
      }
    }
  }

  /// UI-friendly alias that exposes only entry batches.
  Stream<List<AdbFile>> listFileBatches(
    String path, {
    String? serial,
    int batchSize = 256,
    int maxEntries = 100000,
  }) async* {
    await for (final page in listFilePages(
      path,
      serial: serial,
      pageSize: batchSize,
      maxEntries: maxEntries,
    )) {
      if (page.entries.isNotEmpty) yield page.entries;
    }
  }

  /// Uploads a local directory into a hidden remote staging directory, then
  /// publishes the complete tree with one rename. Links are never followed.
  Future<void> pushDirectory(
    String localPath,
    String remoteDir, {
    String? serial,
    void Function(double progress)? onProgress,
    bool Function()? isCancelled,
    OperationContext? operation,
    RecursiveTransferLimits limits = const RecursiveTransferLimits(),
    RecursiveSymlinkPolicy symlinkPolicy = RecursiveSymlinkPolicy.skip,
  }) async {
    _throwIfTransferCancelled(isCancelled);
    final manifest = await scanLocalTransferTree(
      localPath,
      limits: limits,
      symlinkPolicy: symlinkPolicy,
      isCancelled: isCancelled,
    );
    _throwIfTransferCancelled(isCancelled);

    final deviceSerial = serial ?? _core.targetSerial;
    final remoteBase = p.posix.normalize(remoteDir);
    if (!remoteBase.startsWith('/')) {
      throw const FormatException('Remote destination must be absolute.');
    }
    final sourceName = p.basename(p.normalize(localPath));
    if (sourceName.isEmpty ||
        sourceName == '.' ||
        sourceName == '..' ||
        sourceName.contains('/') ||
        sourceName.contains('\u0000')) {
      throw const FormatException('Local directory has an unsafe name.');
    }

    final jobId = _newTransferJobId();
    final remoteStage = p.posix.join(remoteBase, '.shirabox_$jobId.part');
    final remoteFinal = p.posix.join(remoteBase, sourceName);
    final quotedBase = quoteRemoteShellArg(remoteBase);
    final quotedStage = quoteRemoteShellArg(remoteStage);
    final quotedFinal = quoteRemoteShellArg(remoteFinal);
    var published = false;
    var lastProgress = 0.0;

    void report(double value) {
      final bounded = value.clamp(0.0, 1.0).toDouble();
      if (bounded >= lastProgress) {
        lastProgress = bounded;
        onProgress?.call(bounded);
      }
    }

    try {
      report(0);
      await _core.runSafe(
        [
          'shell',
          'if [ ! -d $quotedBase ]; then '
              'echo "Destination parent is not a directory" >&2; '
              'exit 72; fi; '
              'if [ -e $quotedFinal ] || [ -L $quotedFinal ]; then '
              'echo "Destination already exists" >&2; exit 73; fi; '
              'if [ -e $quotedStage ] || [ -L $quotedStage ]; then '
              'echo "Staging path already exists" >&2; exit 74; fi; '
              'mkdir -- $quotedStage',
        ],
        serial: deviceSerial,
        operation: operation,
      );

      final directories = manifest.entries
          .where((entry) => entry.type == AdbFileType.directory)
          .map(
            (entry) => p.posix.joinAll(
              <String>[remoteStage, ...entry.relativeComponents],
            ),
          )
          .toList(growable: false);
      await _createRemoteDirectories(
        directories,
        serial: deviceSerial,
        isCancelled: isCancelled,
        operation: operation,
      );

      final files = manifest.entries
          .where((entry) => entry.type == AdbFileType.file)
          .toList(growable: false);
      final preparedFiles = <_PreparedTransferFile>[];
      for (final entry in files) {
        _throwIfTransferCancelled(isCancelled);
        final type = await FileSystemEntity.type(
          entry.path,
          followLinks: false,
        );
        if (type != FileSystemEntityType.file) {
          throw FileSystemException(
            'Local source changed during transfer.',
            entry.path,
          );
        }
        final currentSize = await File(entry.path).length();
        if (currentSize != entry.size) {
          throw FileSystemException(
            'Local source size changed during transfer.',
            entry.path,
          );
        }
        final remoteTarget = p.posix.joinAll(
          <String>[remoteStage, ...entry.relativeComponents],
        );
        preparedFiles.add(
          _PreparedTransferFile(
            entry: entry,
            remoteDirectory: p.posix.dirname(remoteTarget),
          ),
        );
      }

      final batches = _batchSmallTransfers(preparedFiles);
      var completedBytes = 0;
      var completedFiles = 0;
      for (final batch in batches) {
        _throwIfTransferCancelled(isCancelled);
        if (batch.items.length == 1 ||
            batch.totalBytes > _smallTransferBatchBytes) {
          final item = batch.items.single;
          await _core.runSafe(
            ['push', item.entry.path, item.remotePath],
            serial: deviceSerial,
            timeout: const Duration(minutes: 30),
            onProgress: (fileProgress) {
              if (manifest.totalBytes > 0) {
                report(
                  (completedBytes + fileProgress * item.entry.size) /
                      manifest.totalBytes,
                );
              }
            },
            operation: operation,
          );
        } else {
          final args = <String>[
            'push',
            ...batch.items.map((item) => item.entry.path),
            batch.remoteDirectory,
          ];
          await _core.runSafe(
            args,
            serial: deviceSerial,
            timeout: const Duration(minutes: 30),
            onProgress: (batchProgress) {
              if (manifest.totalBytes > 0) {
                report(
                  (completedBytes + batchProgress * batch.totalBytes) /
                      manifest.totalBytes,
                );
              }
            },
            operation: operation,
          );
        }
        completedBytes += batch.totalBytes;
        completedFiles += batch.items.length;
        if (manifest.totalBytes > 0) {
          report(completedBytes / manifest.totalBytes);
        } else if (files.isNotEmpty) {
          report(completedFiles / files.length);
        }
        _throwIfTransferCancelled(isCancelled);
      }

      await _core.runSafe(
        [
          'shell',
          'if [ -e $quotedFinal ] || [ -L $quotedFinal ]; then '
              'echo "Destination appeared during transfer" >&2; exit 73; fi; '
              'mv -- $quotedStage $quotedFinal',
        ],
        serial: deviceSerial,
        operation: operation,
      );
      published = true;
      report(1);
    } finally {
      if (!published) {
        try {
          await _deleteRemotePath(remoteStage, serial: deviceSerial);
        } catch (_) {}
      }
    }
  }

  /// Downloads a remote directory to the exact [localPath]. The complete tree
  /// is assembled in a same-parent hidden staging directory and then renamed.
  Future<void> pullDirectory(
    String remotePath,
    String localPath, {
    String? serial,
    void Function(double progress)? onProgress,
    bool Function()? isCancelled,
    OperationContext? operation,
    RecursiveTransferLimits limits = const RecursiveTransferLimits(),
    RecursiveSymlinkPolicy symlinkPolicy = RecursiveSymlinkPolicy.skip,
  }) async {
    if (!p.isAbsolute(localPath)) {
      throw const FormatException('Local destination must be absolute.');
    }
    _throwIfTransferCancelled(isCancelled);
    final deviceSerial = serial ?? _core.targetSerial;
    final source = p.posix.normalize(remotePath);
    final manifest = await _scanRemoteTree(
      source,
      serial: deviceSerial,
      limits: limits,
      symlinkPolicy: symlinkPolicy,
      isCancelled: isCancelled,
      operation: operation,
    );
    _throwIfTransferCancelled(isCancelled);

    final destination = p.normalize(p.absolute(localPath));
    final parent = Directory(p.dirname(destination));
    await parent.create(recursive: true);
    if (await FileSystemEntity.type(destination, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw FileSystemException(
        'Local destination already exists.',
        destination,
      );
    }
    final stage = Directory(
      p.join(parent.path, '.shirabox_pull_${_newTransferJobId()}.part'),
    );
    await stage.create();
    var published = false;
    var lastProgress = 0.0;

    void report(double value) {
      final bounded = value.clamp(0.0, 1.0).toDouble();
      if (bounded >= lastProgress) {
        lastProgress = bounded;
        onProgress?.call(bounded);
      }
    }

    try {
      report(0);
      final mappedDirectories = <String, String>{'': stage.path};
      final reservedPaths = <String>{};
      final plannedFiles = <_PlannedRemoteFile>[];
      for (final entry in manifest.entries) {
        final parentKey = entry.relativeComponents.length == 1
            ? ''
            : entry.relativeComponents
                .sublist(0, entry.relativeComponents.length - 1)
                .join('/');
        final localParent = mappedDirectories[parentKey];
        if (localParent == null) {
          throw const FormatException(
            'Remote manifest references a missing parent directory.',
          );
        }
        final localEntryPath = await chooseLocalDownloadPath(
          localParent,
          entry.relativeComponents.last,
          reservedPaths: reservedPaths,
          windows: Platform.isWindows,
        );
        if (!p.isWithin(stage.path, localEntryPath)) {
          throw FileSystemException(
            'Mapped download path escaped its staging directory.',
            localEntryPath,
          );
        }
        final entryKey = entry.relativeComponents.join('/');
        if (entry.type == AdbFileType.directory) {
          await Directory(localEntryPath).create();
          mappedDirectories[entryKey] = localEntryPath;
        } else if (entry.type == AdbFileType.file) {
          plannedFiles.add(_PlannedRemoteFile(entry, localEntryPath));
        }
      }

      await _validateRemoteRegularFiles(
        plannedFiles.map((item) => item.entry.path).toList(growable: false),
        serial: deviceSerial,
        isCancelled: isCancelled,
        operation: operation,
      );
      var completedBytes = 0;
      var completedFiles = 0;
      for (final planned in plannedFiles) {
        _throwIfTransferCancelled(isCancelled);
        final entry = planned.entry;
        await pullFile(
          entry.path,
          planned.localPath,
          serial: deviceSerial,
          onProgress: (fileProgress) {
            if (manifest.totalBytes > 0) {
              report(
                (completedBytes + fileProgress * entry.size) /
                    manifest.totalBytes,
              );
            }
          },
          operation: operation,
        );
        final actualSize = await File(planned.localPath).length();
        if (actualSize != entry.size) {
          throw FileSystemException(
            'Remote file size changed during transfer.',
            entry.path,
          );
        }
        completedBytes += actualSize;
        completedFiles++;
        if (manifest.totalBytes > 0) {
          report(completedBytes / manifest.totalBytes);
        } else if (plannedFiles.isNotEmpty) {
          report(completedFiles / plannedFiles.length);
        }
        _throwIfTransferCancelled(isCancelled);
      }

      if (await FileSystemEntity.type(destination, followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw FileSystemException(
          'Local destination appeared during transfer.',
          destination,
        );
      }
      await stage.rename(destination);
      published = true;
      report(1);
    } finally {
      if (!published) await _deleteLocalEntity(stage.path);
    }
  }

  Future<RecursiveTransferManifest> _scanRemoteTree(
    String remotePath, {
    required String? serial,
    required RecursiveTransferLimits limits,
    required RecursiveSymlinkPolicy symlinkPolicy,
    bool Function()? isCancelled,
    OperationContext? operation,
  }) async {
    final root = p.posix.normalize(remotePath);
    // Constructing the decoder validates the root and limits before launching.
    final decoder = RemoteTreeListingDecoder(
      root,
      limits: limits,
      symlinkPolicy: symlinkPolicy,
    );
    final quotedRoot = quoteRemoteShellArg(root);
    final command = '''
root=$quotedRoot
if [ -L "\$root" ]; then echo 'Source is a symbolic link' >&2; exit 22; fi
if [ ! -d "\$root" ]; then echo 'Source is not a directory' >&2; exit 20; fi
if [ ! -r "\$root" ]; then echo 'Source is not readable' >&2; exit 21; fi
if ! command -v stat >/dev/null 2>&1; then
  echo 'Device stat command is unavailable' >&2; exit 24
fi
walk_shirabox() {
  current="\$1"
  prefix="\$current/"
  for entry in "\$prefix"* "\$prefix".[!.]* "\$prefix"..?*; do
    if [ ! -e "\$entry" ] && [ ! -L "\$entry" ]; then continue; fi
    if [ -L "\$entry" ]; then
      printf 'L\\0%s\\0%s\\0' "\$entry" '0'
    elif [ -d "\$entry" ]; then
      printf 'D\\0%s\\0%s\\0' "\$entry" '0'
      walk_shirabox "\$entry" || return \$?
    elif [ -f "\$entry" ]; then
      size=\$(stat -c %s "\$entry" 2>/dev/null) || {
        echo "Unable to stat a source file" >&2; return 25;
      }
      case "\$size" in ''|*[!0-9]*)
        echo "Invalid file size from stat" >&2; return 25;;
      esac
      printf 'F\\0%s\\0%s\\0' "\$entry" "\$size"
    else
      printf 'O\\0%s\\0%s\\0' "\$entry" '0'
    fi
  done
}
walk_shirabox "\$root"
''';

    OwnedCommandHandle? process;
    Future<String>? stderrFuture;
    var exitedNormally = false;
    try {
      _throwIfTransferCancelled(isCancelled);
      process = await _core.startOwnedProcess(
        ['shell', command],
        serial: serial,
        operation: operation,
      );
      stderrFuture = _captureBoundedText(process.stderr);
      await for (final chunk in process.stdout.timeout(
        const Duration(seconds: 30),
      )) {
        _throwIfTransferCancelled(isCancelled);
        decoder.addBytes(chunk);
      }
      final exit = await process.done.timeout(
        const Duration(seconds: 30),
      );
      final stderr = await stderrFuture;
      if (exit.exitCode != 0) {
        throw AdbCommandException(
          stderr.trim().isEmpty
              ? 'Unable to scan remote directory $root.'
              : stderr.trim(),
          exitCode: exit.exitCode,
        );
      }
      final manifest = decoder.finish();
      exitedNormally = true;
      return manifest;
    } finally {
      if (!exitedNormally && process != null) {
        try {
          if (!process.isCompleted) await process.cancel();
        } catch (_) {}
      }
      if (stderrFuture != null) {
        try {
          await stderrFuture.timeout(const Duration(seconds: 2));
        } catch (_) {}
      }
    }
  }

  Future<void> _createRemoteDirectories(
    List<String> directories, {
    required String? serial,
    bool Function()? isCancelled,
    OperationContext? operation,
  }) async {
    var batch = <String>[];
    var commandLength = 0;

    Future<void> flush() async {
      if (batch.isEmpty) return;
      _throwIfTransferCancelled(isCancelled);
      await _core.runSafe(
        ['shell', 'mkdir -p -- ${batch.join(' ')}'],
        serial: serial,
        operation: operation,
      );
      batch = <String>[];
      commandLength = 0;
    }

    for (final directory in directories) {
      final quoted = quoteRemoteShellArg(directory);
      if (batch.isNotEmpty &&
          (batch.length >= 64 || commandLength + quoted.length > 16000)) {
        await flush();
      }
      batch.add(quoted);
      commandLength += quoted.length + 1;
    }
    await flush();
  }

  Future<void> _validateRemoteRegularFiles(
    List<String> files, {
    required String? serial,
    bool Function()? isCancelled,
    OperationContext? operation,
  }) async {
    var checks = <String>[];
    var commandLength = 0;

    Future<void> flush() async {
      if (checks.isEmpty) return;
      _throwIfTransferCancelled(isCancelled);
      await _core.runSafe(
        ['shell', checks.join(' ')],
        serial: serial,
        operation: operation,
      );
      checks = <String>[];
      commandLength = 0;
    }

    for (final file in files) {
      final quoted = quoteRemoteShellArg(file);
      final check = 'if [ -L $quoted ] || [ ! -f $quoted ]; then '
          'echo "Remote source changed during transfer" >&2; exit 75; fi;';
      if (checks.isNotEmpty &&
          (checks.length >= 64 || commandLength + check.length > 16000)) {
        await flush();
      }
      checks.add(check);
      commandLength += check.length + 1;
    }
    await flush();
  }

  String _newTransferJobId() =>
      '${DateTime.now().microsecondsSinceEpoch}_${_nextJobId++ & 0x7fffffff}';

  Future<void> pushFile(
    String localPath,
    String remoteDir, {
    String? serial,
    void Function(double progress)? onProgress,
    OperationContext? operation,
  }) async {
    final entityType =
        await FileSystemEntity.type(localPath, followLinks: false);
    if (entityType == FileSystemEntityType.notFound) {
      throw FileSystemException('Local source does not exist.', localPath);
    }
    if (entityType == FileSystemEntityType.link) {
      throw FileSystemException(
        'Symbolic links are not followed during upload.',
        localPath,
      );
    }
    if (entityType == FileSystemEntityType.directory) {
      await pushDirectory(
        localPath,
        remoteDir,
        serial: serial,
        onProgress: onProgress,
        operation: operation,
      );
      return;
    }
    if (entityType != FileSystemEntityType.file) {
      throw FileSystemException(
          'Local source is not a regular file.', localPath);
    }

    final deviceSerial = serial ?? _core.targetSerial;
    final remoteBase = p.posix.normalize(remoteDir);
    if (!remoteBase.startsWith('/')) {
      throw const FormatException('Remote destination must be absolute.');
    }

    final filename = p.basename(localPath);
    final jobId =
        '${DateTime.now().microsecondsSinceEpoch}_${_nextJobId++ & 0x7fffffff}';
    final remoteTemp = p.posix.join(remoteBase, '.shirabox_$jobId.part');
    final remoteFinal = p.posix.join(remoteBase, filename);
    var moved = false;

    try {
      await _core.runSafe(
        ['push', localPath, remoteTemp],
        serial: deviceSerial,
        timeout: const Duration(minutes: 30),
        onProgress: (value) => onProgress?.call(value * 0.98),
        operation: operation,
      );

      final quotedTemp = quoteRemoteShellArg(remoteTemp);
      final quotedFinal = quoteRemoteShellArg(remoteFinal);
      final conflictGuard = entityType == FileSystemEntityType.directory
          ? 'if [ -e $quotedFinal ] || [ -L $quotedFinal ]; then '
              'echo "Destination already exists" >&2; exit 73; fi; '
          : 'if [ -d $quotedFinal ]; then '
              'echo "Destination is a directory" >&2; exit 73; fi; ';
      final moveCommand = '$conflictGuard'
          'mv -f -- $quotedTemp $quotedFinal';
      await _core.runSafe(
        ['shell', moveCommand],
        serial: deviceSerial,
        operation: operation,
      );
      moved = true;
      onProgress?.call(1);
    } finally {
      if (!moved) {
        try {
          await _deleteRemotePath(remoteTemp, serial: deviceSerial);
        } catch (_) {}
      }
    }
  }

  Future<void> pullFile(
    String remotePath,
    String localPath, {
    String? serial,
    void Function(double progress)? onProgress,
    OperationContext? operation,
  }) async {
    if (!p.isAbsolute(localPath)) {
      throw const FormatException('Local destination must be absolute.');
    }
    final deviceSerial = serial ?? _core.targetSerial;
    final parent = Directory(p.dirname(localPath));
    await parent.create(recursive: true);
    final tempPath = p.join(
      parent.path,
      '.shirabox_pull_${DateTime.now().microsecondsSinceEpoch}_'
      '${_nextJobId++ & 0x7fffffff}.part',
    );

    try {
      await _core.runSafe(
        ['pull', remotePath, tempPath],
        serial: deviceSerial,
        timeout: const Duration(minutes: 30),
        onProgress: (value) => onProgress?.call(value * 0.99),
        operation: operation,
      );
      final tempType =
          await FileSystemEntity.type(tempPath, followLinks: false);
      if (tempType == FileSystemEntityType.directory) {
        throw const FormatException(
          'Directory download requires recursive safe-name mapping.',
        );
      }
      if (tempType != FileSystemEntityType.file) {
        throw const FormatException('ADB pull did not produce a regular file.');
      }
      if (await FileSystemEntity.type(localPath, followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw FileSystemException(
            'Local destination already exists.', localPath);
      }
      await File(tempPath).rename(localPath);
      onProgress?.call(1);
    } finally {
      await _deleteLocalEntity(tempPath);
    }
  }

  Future<void> _deleteLocalEntity(String path) async {
    try {
      final type = await FileSystemEntity.type(path, followLinks: false);
      if (type == FileSystemEntityType.directory) {
        await Directory(path).delete(recursive: true);
      } else if (type != FileSystemEntityType.notFound) {
        await File(path).delete();
      }
    } catch (_) {}
  }

  Future<void> deleteFile(
    String remotePath, {
    String? serial,
    OperationContext? operation,
  }) async {
    final path = p.posix.normalize(remotePath);
    final protected = <String>{
      '/',
      '/sdcard',
      '/data',
      '/system',
      '/vendor',
      '/product',
      '/storage',
      '/storage/emulated',
      '/storage/emulated/0',
    };
    if (protected.contains(path)) throw "Protected Path";
    if (!path.startsWith('/')) {
      throw const FormatException('Remote path must be absolute.');
    }
    final command = 'rm -rf -- ${quoteRemoteShellArg(path)}';
    await _core.runSafe(
      ['shell', command],
      serial: serial ?? _core.targetSerial,
      operation: operation,
    );
  }

  Future<void> _deleteRemotePath(String remotePath, {String? serial}) async {
    final command = 'rm -rf -- ${quoteRemoteShellArg(remotePath)}';
    await _core.runSafe(['shell', command], serial: serial);
  }

  Future<void> installApk(
    String path, {
    String? serial,
    void Function(double progress)? onProgress,
    OperationContext? operation,
  }) async {
    final source = File(path);
    if (!await source.exists()) {
      throw FileSystemException('APK does not exist.', path);
    }

    final deviceSerial = serial ?? _core.targetSerial;
    Directory? stagingDir;
    var installPath = path;
    final needsStaging =
        path.length >= 240 || path.codeUnits.any((c) => c > 0x7f);

    try {
      if (needsStaging) {
        stagingDir = await createAdbSafeTempDirectory('shirabox_install_');
        installPath = p.join(stagingDir.path, 'package.apk');
        await source.copy(installPath);
      }

      await _core.runSafe(
        ['install', '-r', installPath],
        serial: deviceSerial,
        timeout: const Duration(minutes: 15),
        onProgress: onProgress,
        operation: operation,
      );
    } finally {
      if (stagingDir != null) await _safeDeleteDir(stagingDir);
    }
  }

  Future<void> extractApp(
      String pkg, String targetDir, List<String> splitPaths, String mainPath,
      {String? serial}) async {
    final deviceSerial = serial ?? _core.targetSerial;
    final extension = splitPaths.isEmpty ? '.apk' : '.apks';
    final finalPath = await chooseLocalDownloadPath(
      targetDir,
      '$pkg$extension',
    );
    final outputTemp = File(p.join(
      targetDir,
      '.shirabox_export_${DateTime.now().microsecondsSinceEpoch}_'
      '${_nextJobId++ & 0x7fffffff}.part',
    ));

    if (splitPaths.isEmpty) {
      try {
        await pullFile(mainPath, outputTemp.path, serial: deviceSerial);
        if (!await outputTemp.exists() || await outputTemp.length() == 0) {
          throw const FormatException('Pulled APK is empty.');
        }
        await outputTemp.rename(finalPath);
      } finally {
        try {
          if (await outputTemp.exists()) await outputTemp.delete();
        } catch (_) {}
      }
      return;
    }
    Directory tempDir = await createAdbSafeTempDirectory('adb_extract_');
    try {
      List<String> allRemotePaths = [mainPath, ...splitPaths];
      Map<String, String> filesToZip = {};
      final usedEntryNames = <String>{};
      for (var index = 0; index < allRemotePaths.length; index++) {
        final remote = allRemotePaths[index];
        String name = remote.split('/').last;
        if (name.isEmpty || !name.toLowerCase().endsWith('.apk')) {
          name = 'split_$index.apk';
        }
        if (!usedEntryNames.add(name)) {
          name = 'split_$index.apk';
          usedEntryNames.add(name);
        }
        String localTempPath = p.join(tempDir.path, 'apk_$index.apk');
        await pullFile(remote, localTempPath, serial: deviceSerial);
        File f = File(localTempPath);
        if (!await f.exists() || await f.length() == 0) {
          throw "Pull failed or empty file: $remote";
        }
        filesToZip[localTempPath] = name;
      }
      if (filesToZip.isEmpty) throw "No files pulled.";
      await compute(
        _zipTask,
        {'files': filesToZip, 'dest': outputTemp.path},
      );
      if (!await outputTemp.exists() || await outputTemp.length() == 0) {
        throw const FormatException('Generated APKS archive is empty.');
      }
      await outputTemp.rename(finalPath);
    } finally {
      await _safeDeleteDir(tempDir);
      try {
        if (await outputTemp.exists()) await outputTemp.delete();
      } catch (_) {}
    }
  }

  Future<void> _safeDeleteDir(Directory dir) async {
    int retry = 0;
    while (retry < 3) {
      try {
        if (await dir.exists()) await dir.delete(recursive: true);
        return;
      } catch (e) {
        retry++;
        await Future.delayed(const Duration(milliseconds: 500));
      }
    }
  }

  Future<void> installXapk(
    String xapkPath, {
    String? serial,
    void Function(double progress)? onProgress,
    OperationContext? operation,
  }) async {
    final deviceSerial = serial ?? _core.targetSerial;
    operation?.token.throwIfCancelled();
    final stagingDir = await createAdbSafeTempDirectory('adb_install_');
    try {
      final extractedFiles = await compute(
        _unzipTask,
        <String, String>{
          'zipPath': xapkPath,
          'tempPath': stagingDir.path,
        },
      );
      operation?.token.throwIfCancelled();
      if (extractedFiles.isEmpty) throw "No APKs found in archive";
      List<File> apkFiles = extractedFiles.map((path) => File(path)).toList();
      await _installSplitApksFromFiles(
        apkFiles,
        serial: deviceSerial,
        onProgress: onProgress,
        operation: operation,
      );
    } finally {
      await _safeDeleteDir(stagingDir);
    }
  }

  Future<void> _installSplitApksFromFiles(
    List<File> apks, {
    String? serial,
    void Function(double progress)? onProgress,
    OperationContext? operation,
  }) async {
    final deviceSerial = serial ?? _core.targetSerial;
    operation?.token.throwIfCancelled();
    final createResult = await _core.runRaw(
      ['shell', 'pm', 'install-create', '-r'],
      serial: deviceSerial,
      operation: operation,
    );
    if (createResult.exitCode != 0) {
      throw AdbCommandException(
        'Create install session failed: ${createResult.stderr}',
        exitCode: createResult.exitCode,
      );
    }
    final createOutput =
        '${createResult.stdout}\n${createResult.stderr}'.trim();
    final sessionIdMatch = RegExp(r'\[(\d+)\]').firstMatch(createOutput);
    if (sessionIdMatch == null) throw "Create Session Failed: $createOutput";
    final sessionId = sessionIdMatch.group(1)!;
    try {
      for (int i = 0; i < apks.length; i++) {
        operation?.token.throwIfCancelled();
        final file = apks[i];
        final size = await file.length();
        final remoteName = i == 0 ? 'base' : 'split_$i';
        final remoteTempPath =
            "/data/local/tmp/shirabox_${sessionId}_$remoteName.apk";
        try {
          await _core.runSafe(
            ['push', file.path, remoteTempPath],
            serial: deviceSerial,
            timeout: const Duration(minutes: 30),
            onProgress: (value) {
              onProgress?.call(
                ((i + value * 0.9) / apks.length) * 0.95,
              );
            },
            operation: operation,
          );
          await _core.runSafe([
            'shell',
            'pm',
            'install-write',
            '-S',
            size.toString(),
            sessionId,
            remoteName,
            remoteTempPath
          ],
              serial: deviceSerial,
              timeout: const Duration(minutes: 5),
              operation: operation);
          onProgress?.call(((i + 1) / apks.length) * 0.95);
        } finally {
          try {
            await _deleteRemotePath(remoteTempPath, serial: deviceSerial);
          } catch (_) {}
        }
      }
      final commitResult = await _core.runRaw(
        ['shell', 'pm', 'install-commit', sessionId],
        serial: deviceSerial,
        timeout: const Duration(minutes: 5),
        operation: operation,
      );
      final commitOutput =
          '${commitResult.stdout}\n${commitResult.stderr}'.trim();
      if (commitResult.exitCode != 0 ||
          !commitOutput.toLowerCase().contains('success')) {
        throw "Install Failed: $commitOutput";
      }
      onProgress?.call(1);
    } catch (e) {
      try {
        await _core.runSafe(
          ['shell', 'pm', 'install-abandon', sessionId],
          serial: deviceSerial,
        );
      } catch (_) {}
      rethrow;
    }
  }
}

class _PlannedRemoteFile {
  const _PlannedRemoteFile(this.entry, this.localPath);

  final RecursiveTransferEntry entry;
  final String localPath;
}

class _PreparedTransferFile {
  const _PreparedTransferFile({
    required this.entry,
    required this.remoteDirectory,
  });

  final RecursiveTransferEntry entry;
  final String remoteDirectory;

  String get remotePath =>
      p.posix.join(remoteDirectory, entry.relativeComponents.last);
}

class _TransferPushBatch {
  _TransferPushBatch(this.remoteDirectory);

  final String remoteDirectory;
  final List<_PreparedTransferFile> items = <_PreparedTransferFile>[];
  int totalBytes = 0;
  int argumentBytes = 0;

  bool canAdd(_PreparedTransferFile item) {
    if (items.isEmpty) return true;
    if (!_isBatchSafe(item.entry) ||
        items.any((existing) => !_isBatchSafe(existing.entry))) {
      return false;
    }
    if (items.length >= _smallTransferBatchFiles) return false;
    if (totalBytes + item.entry.size > _smallTransferBatchBytes) {
      return false;
    }
    final nextArgumentBytes = argumentBytes + item.entry.path.length + 1;
    return nextArgumentBytes <= _smallTransferBatchArgumentBytes;
  }

  void add(_PreparedTransferFile item) {
    items.add(item);
    totalBytes += item.entry.size;
    argumentBytes += item.entry.path.length + 1;
  }
}

bool _isBatchSafe(RecursiveTransferEntry entry) {
  // Some platform-tools builds mishandle non-ASCII names when multiple local
  // sources are passed to one push command. Keep those names on the stable
  // single-file path; ASCII batches still remove most process startups.
  return entry.path.codeUnits.every((unit) => unit < 0x80) &&
      entry.relativeComponents
          .expand((component) => component.codeUnits)
          .every((unit) => unit < 0x80);
}

List<_TransferPushBatch> _batchSmallTransfers(
  List<_PreparedTransferFile> files,
) {
  final grouped = <String, List<_PreparedTransferFile>>{};
  for (final file in files) {
    grouped
        .putIfAbsent(file.remoteDirectory, () => <_PreparedTransferFile>[])
        .add(file);
  }

  final batches = <_TransferPushBatch>[];
  for (final group in grouped.values) {
    _TransferPushBatch? current;
    for (final item in group) {
      if (current == null || !current.canAdd(item)) {
        current = _TransferPushBatch(item.remoteDirectory);
        batches.add(current);
      }
      current.add(item);
    }
  }
  return batches;
}

void _throwIfTransferCancelled(bool Function()? isCancelled) {
  if (isCancelled?.call() == true) {
    throw const TransferCancelledException();
  }
}

class AdbFile {
  final String name;
  final String path;
  final AdbFileType type;
  final int? size;
  final int? modifiedEpochSeconds;

  bool get isDir => type == AdbFileType.directory;
  bool get isSymlink => type == AdbFileType.symlink;

  AdbFile({
    required this.name,
    required this.path,
    required bool isDir,
    this.size,
    this.modifiedEpochSeconds,
  }) : type = isDir ? AdbFileType.directory : AdbFileType.file;

  const AdbFile.typed({
    required this.name,
    required this.path,
    required this.type,
    this.size,
    this.modifiedEpochSeconds,
  });
}

int _compareAdbFiles(AdbFile a, AdbFile b) {
  if (a.isDir && !b.isDir) return -1;
  if (!a.isDir && b.isDir) return 1;
  final insensitive = a.name.toLowerCase().compareTo(b.name.toLowerCase());
  return insensitive != 0 ? insensitive : a.name.compareTo(b.name);
}

Future<String> _captureBoundedText(
  Stream<List<int>> stream, {
  int maxBytes = 64 * 1024,
}) async {
  final output = BytesBuilder(copy: false);
  var remaining = maxBytes;
  await for (final chunk in stream) {
    if (remaining <= 0) continue;
    final count = min(remaining, chunk.length);
    output.add(chunk.sublist(0, count));
    remaining -= count;
  }
  return utf8.decode(output.takeBytes(), allowMalformed: true);
}

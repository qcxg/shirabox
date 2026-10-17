import 'dart:io';

import 'package:flutter/services.dart';

const MethodChannel _nativeStagingChannel = MethodChannel(
  'shirabox/native_staging',
);

final RegExp _safePrefixPattern = RegExp(r'^[A-Za-z0-9_-]{1,48}$');

/// Creates a private random temporary directory whose full path is ASCII on
/// Windows. Older ADB builds can misdecode otherwise valid Unicode host paths.
///
/// Windows creation is performed inside the native runner. It uses the Windows
/// cryptographic RNG and passes a complete protected DACL to CreateDirectoryW,
/// so the directory is never briefly exposed through inherited permissions.
/// The runner also verifies the ProgramData parent, owner, DACL, and reparse
/// state before returning the path. No command shell or Windows utility is
/// launched.
Future<Directory> createAdbSafeTempDirectory(String prefix) async {
  if (!_safePrefixPattern.hasMatch(prefix)) {
    throw const FormatException(
      'Temporary directory prefix must be 1-48 ASCII characters.',
    );
  }
  if (!Platform.isWindows) {
    return Directory.systemTemp.createTemp(prefix);
  }

  final path = await _nativeStagingChannel.invokeMethod<String>(
    'createAdbStagingDirectory',
    <String, Object>{'prefix': prefix},
  );
  if (path == null ||
      !_isAsciiWindowsAbsolutePath(path) ||
      !_windowsBaseName(path).startsWith(prefix)) {
    throw const FileSystemException(
      'The Windows runner returned an invalid ADB staging path.',
    );
  }
  return _NativeAdbStagingDirectory(path);
}

bool _isAsciiWindowsAbsolutePath(String path) {
  if (path.length < 3 ||
      !_isAsciiLetter(path.codeUnitAt(0)) ||
      path.codeUnitAt(1) != 0x3a ||
      (path.codeUnitAt(2) != 0x5c && path.codeUnitAt(2) != 0x2f)) {
    return false;
  }
  return path.codeUnits.every((value) => value <= 0x7f);
}

bool _isAsciiLetter(int value) =>
    (value >= 0x41 && value <= 0x5a) || (value >= 0x61 && value <= 0x7a);

String _windowsBaseName(String path) {
  final slash = path.lastIndexOf('/');
  final backslash = path.lastIndexOf(r'\');
  return path.substring((slash > backslash ? slash : backslash) + 1);
}

/// A Directory facade that keeps deletion inside the native ownership
/// boundary. Existing callers can continue to call `delete(recursive: true)`;
/// the runner will refuse paths it did not create and will never traverse a
/// reparse point.
final class _NativeAdbStagingDirectory implements Directory {
  _NativeAdbStagingDirectory(String path) : _delegate = Directory(path);

  final Directory _delegate;

  @override
  String get path => _delegate.path;

  @override
  Uri get uri => _delegate.uri;

  @override
  bool get isAbsolute => true;

  @override
  Directory get absolute => this;

  @override
  Directory get parent => _delegate.parent;

  @override
  Future<bool> exists() => _delegate.exists();

  @override
  bool existsSync() => _delegate.existsSync();

  @override
  Future<Directory> create({bool recursive = false}) => throw UnsupportedError(
      'A native ADB staging directory cannot be recreated.');

  @override
  void createSync({bool recursive = false}) => throw UnsupportedError(
      'A native ADB staging directory cannot be recreated.');

  @override
  Future<Directory> createTemp([String? prefix]) =>
      _delegate.createTemp(prefix);

  @override
  Directory createTempSync([String? prefix]) =>
      _delegate.createTempSync(prefix);

  @override
  Future<FileSystemEntity> delete({bool recursive = false}) async {
    await _nativeStagingChannel.invokeMethod<void>(
      'deleteAdbStagingDirectory',
      <String, Object>{'path': path, 'recursive': recursive},
    );
    return this;
  }

  @override
  void deleteSync({bool recursive = false}) => throw UnsupportedError(
        'Native ADB staging cleanup is asynchronous.',
      );

  @override
  Stream<FileSystemEntity> list({
    bool recursive = false,
    bool followLinks = true,
  }) =>
      _delegate.list(recursive: recursive, followLinks: followLinks);

  @override
  List<FileSystemEntity> listSync({
    bool recursive = false,
    bool followLinks = true,
  }) =>
      _delegate.listSync(recursive: recursive, followLinks: followLinks);

  @override
  Future<Directory> rename(String newPath) => throw UnsupportedError(
        'A native ADB staging directory cannot be renamed.',
      );

  @override
  Directory renameSync(String newPath) => throw UnsupportedError(
        'A native ADB staging directory cannot be renamed.',
      );

  @override
  Future<String> resolveSymbolicLinks() => _delegate.resolveSymbolicLinks();

  @override
  String resolveSymbolicLinksSync() => _delegate.resolveSymbolicLinksSync();

  @override
  Future<FileStat> stat() => _delegate.stat();

  @override
  FileStat statSync() => _delegate.statSync();

  @override
  Stream<FileSystemEvent> watch({
    int events = FileSystemEvent.all,
    bool recursive = false,
  }) =>
      _delegate.watch(events: events, recursive: recursive);

  @override
  String toString() => "Directory: '$path'";
}

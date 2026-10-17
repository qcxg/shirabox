import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

const int _maxEncodedNameLength = 180;
final RegExp _windowsReservedName = RegExp(
  r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:[ .]|$)',
  caseSensitive: false,
);

/// Maps one Android path component to a safe local filename.
///
/// Invalid Windows characters are UTF-8 percent encoded. The mapping is
/// deterministic and keeps ordinary Unicode names readable. Extremely long
/// encoded names receive a stable hash suffix so the resulting component fits
/// comfortably below common filesystem limits.
String encodeRemoteNameForLocal(String remoteName, {bool? windows}) {
  final useWindowsRules = windows ?? Platform.isWindows;
  if (remoteName.isEmpty) return '%00';

  final runes = remoteName.runes.toList(growable: false);
  final tokens = <String>[];
  for (var i = 0; i < runes.length; i++) {
    final rune = runes[i];
    final char = String.fromCharCode(rune);
    final isLast = i == runes.length - 1;
    final invalidOnWindows = useWindowsRules &&
        (rune < 0x20 ||
            const {'<', '>', ':', '"', '/', r'\', '|', '?', '*'}
                .contains(char) ||
            (isLast && (char == '.' || char == ' ')));
    final mustEscape = char == '%' || char == '\u0000' || invalidOnWindows;
    tokens.add(mustEscape ? _percentEncode(char) : char);
  }

  var encoded = tokens.join();
  if (useWindowsRules &&
      (encoded == '.' ||
          encoded == '..' ||
          _windowsReservedName.hasMatch(encoded))) {
    tokens[0] = _percentEncode(String.fromCharCode(runes.first));
    encoded = tokens.join();
  }

  if (encoded.length <= _maxEncodedNameLength) return encoded;

  final suffix = '~${_fnv1a32(remoteName).toRadixString(16).padLeft(8, '0')}';
  final limit = _maxEncodedNameLength - suffix.length;
  final shortened = StringBuffer();
  for (final token in tokens) {
    if (shortened.length + token.length > limit) break;
    shortened.write(token);
  }
  return '${shortened.toString()}$suffix';
}

/// Returns a collision-free destination that is guaranteed to stay under
/// [outputDirectory]. Existing files and case-insensitive duplicates receive
/// a numeric suffix rather than being overwritten.
Future<String> chooseLocalDownloadPath(
  String outputDirectory,
  String remoteName, {
  Set<String>? reservedPaths,
  bool? windows,
}) async {
  final root = p.normalize(p.absolute(outputDirectory));
  final encodedName = encodeRemoteNameForLocal(remoteName, windows: windows);
  final extension = p.extension(encodedName);
  final stem = extension.isEmpty
      ? encodedName
      : encodedName.substring(0, encodedName.length - extension.length);

  var counter = 0;
  while (true) {
    final candidateName =
        counter == 0 ? encodedName : '$stem ($counter)$extension';
    final candidate = p.normalize(p.join(root, candidateName));
    if (!p.isWithin(root, candidate)) {
      throw FileSystemException(
        'Refusing a download path outside the selected directory.',
        candidate,
      );
    }

    final collisionKey = Platform.isWindows || windows == true
        ? candidate.toLowerCase()
        : candidate;
    final reserved = reservedPaths?.contains(collisionKey) ?? false;
    final exists =
        await FileSystemEntity.type(candidate) != FileSystemEntityType.notFound;
    if (!reserved && !exists) {
      reservedPaths?.add(collisionKey);
      return candidate;
    }
    counter++;
  }
}

String _percentEncode(String value) {
  return utf8
      .encode(value)
      .map((byte) => '%${byte.toRadixString(16).padLeft(2, '0').toUpperCase()}')
      .join();
}

int _fnv1a32(String value) {
  var hash = 0x811c9dc5;
  for (final byte in utf8.encode(value)) {
    hash ^= byte;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash;
}

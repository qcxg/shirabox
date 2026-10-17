import 'dart:convert';

class AdbDeviceSnapshot {
  AdbDeviceSnapshot(String payload) {
    for (final line in const LineSplitter().convert(payload)) {
      final fields = line.trim().split(RegExp(r'\s+'));
      if (fields.length >= 2 && fields.first != 'List') {
        states[fields[0]] = fields[1];
      }
    }
  }

  final Map<String, String> states = {};

  List<String> get connected => [
        for (final entry in states.entries)
          if (entry.value == 'device') entry.key,
      ];

  String? get diagnostic {
    final unavailable = [
      for (final entry in states.entries)
        if (entry.value == 'unauthorized')
          '${entry.key}: allow USB debugging on the device.'
        else if (entry.value == 'offline')
          '${entry.key}: device is offline.',
    ];
    return unavailable.isEmpty ? null : unavailable.join('\n');
  }
}

/// The smart socket sends OKAY followed by hexadecimal length-prefixed lists.
/// TCP chunks can split the status, length, or payload at any byte boundary.
class AdbDeviceTrackerDecoder {
  final List<int> _pending = [];
  bool _accepted = false;
  bool _failed = false;

  List<AdbDeviceSnapshot> add(List<int> bytes) {
    _pending.addAll(bytes);
    final snapshots = <AdbDeviceSnapshot>[];
    var offset = 0;
    if (!_accepted) {
      if (_pending.length < 4) return snapshots;
      final status = ascii.decode(_pending.sublist(0, 4));
      if (status != 'OKAY' && status != 'FAIL') {
        throw const FormatException('Invalid ADB device-tracker response.');
      }
      _accepted = true;
      _failed = status == 'FAIL';
      offset = 4;
    }
    while (_pending.length - offset >= 4) {
      final header = ascii.decode(_pending.sublist(offset, offset + 4));
      final length = int.tryParse(header, radix: 16);
      if (length == null || length < 0) {
        throw const FormatException('Invalid ADB device-list frame length.');
      }
      if (_pending.length - offset - 4 < length) break;
      offset += 4;
      final payload = utf8.decode(
        _pending.sublist(offset, offset + length),
        allowMalformed: true,
      );
      offset += length;
      if (_failed) throw FormatException('ADB device tracker: $payload');
      snapshots.add(AdbDeviceSnapshot(payload));
    }
    if (offset > 0) _pending.removeRange(0, offset);
    return snapshots;
  }
}

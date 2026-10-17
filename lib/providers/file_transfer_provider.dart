import 'dart:async';

import 'package:flutter/foundation.dart';

/// Owns file-transfer UI state independently from the Files page lifecycle.
///
/// A page can be disposed while an ADB command is still completing. Keeping
/// the job gate here prevents a newly opened page from starting a second batch
/// and lets it redisplay the active job. The active command exposes one cancel
/// callback so Stop can interrupt it instead of only stopping between items.
class FileTransferProvider extends ChangeNotifier {
  bool isBusy = false;
  bool stopRequested = false;
  String action = '';
  String currentName = '';
  String? serial;
  int completed = 0;
  int total = 0;
  int failures = 0;
  int cancelled = 0;
  double currentItemProgress = 0;

  int _generation = 0;
  Future<void> Function()? _cancelActive;
  DateTime _lastProgressNotification = DateTime.fromMillisecondsSinceEpoch(0);

  int? begin({
    required String action,
    required int total,
    required String serial,
  }) {
    if (isBusy || total <= 0) return null;
    final jobId = ++_generation;
    isBusy = true;
    stopRequested = false;
    this.action = action;
    currentName = '';
    this.serial = serial;
    completed = 0;
    this.total = total;
    failures = 0;
    cancelled = 0;
    currentItemProgress = 0;
    _lastProgressNotification = DateTime.fromMillisecondsSinceEpoch(0);
    notifyListeners();
    return jobId;
  }

  bool owns(int jobId) => isBusy && jobId == _generation;

  void beginItem(int jobId, String name) {
    if (!owns(jobId)) return;
    currentName = name;
    currentItemProgress = 0;
    notifyListeners();
  }

  void updateProgress(int jobId, double value) {
    if (!owns(jobId)) return;
    final normalized = value.clamp(0.0, 1.0).toDouble();
    final now = DateTime.now();
    if (normalized < 1 &&
        now.difference(_lastProgressNotification) <
            const Duration(milliseconds: 100)) {
      return;
    }
    _lastProgressNotification = now;
    currentItemProgress = normalized;
    notifyListeners();
  }

  void completeItem(
    int jobId, {
    required bool success,
    bool wasCancelled = false,
  }) {
    if (!owns(jobId)) return;
    completed++;
    if (wasCancelled) {
      cancelled++;
    } else if (!success) {
      failures++;
    }
    currentItemProgress = 0;
    notifyListeners();
  }

  void requestStop() {
    if (!isBusy || stopRequested) return;
    stopRequested = true;
    notifyListeners();
    final cancel = _cancelActive;
    if (cancel != null) unawaited(cancel());
  }

  void attachCancellation(
    int jobId,
    Future<void> Function() cancel,
  ) {
    if (!owns(jobId)) return;
    _cancelActive = cancel;
    if (stopRequested) unawaited(cancel());
  }

  bool shouldStop(int jobId) => !owns(jobId) || stopRequested;

  void finish(int jobId) {
    if (!owns(jobId)) return;
    isBusy = false;
    stopRequested = false;
    _cancelActive = null;
    currentItemProgress = 0;
    serial = null;
    notifyListeners();
  }
}

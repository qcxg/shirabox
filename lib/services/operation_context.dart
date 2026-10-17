import 'dart:async';
import 'dart:collection';

enum OperationCancelReason {
  requested,
  deviceTargetChanged,
  adbExecutableChanged,
  deadlineExceeded,
  runtimeShutdown,
}

class DeviceTarget {
  const DeviceTarget({
    required this.serial,
    required this.sessionEpoch,
    required this.adbExecutableGeneration,
    required this.adbExecutable,
    required this.deviceScoped,
  });

  final String? serial;
  final int sessionEpoch;
  final int adbExecutableGeneration;
  final String adbExecutable;
  final bool deviceScoped;

  bool isCurrentAgainst(DeviceTarget current) {
    if (adbExecutableGeneration != current.adbExecutableGeneration) {
      return false;
    }
    if (!deviceScoped) return true;
    return sessionEpoch == current.sessionEpoch && serial == current.serial;
  }

  @override
  bool operator ==(Object other) =>
      other is DeviceTarget &&
      other.serial == serial &&
      other.sessionEpoch == sessionEpoch &&
      other.adbExecutableGeneration == adbExecutableGeneration &&
      other.adbExecutable == adbExecutable &&
      other.deviceScoped == deviceScoped;

  @override
  int get hashCode => Object.hash(
        serial,
        sessionEpoch,
        adbExecutableGeneration,
        adbExecutable,
        deviceScoped,
      );

  @override
  String toString() => 'DeviceTarget('
      'serial: $serial, '
      'sessionEpoch: $sessionEpoch, '
      'adbExecutableGeneration: $adbExecutableGeneration, '
      'deviceScoped: $deviceScoped)';
}

class OperationCancelledException implements Exception {
  const OperationCancelledException({
    required this.operationId,
    required this.reason,
  });

  final int operationId;
  final OperationCancelReason reason;

  @override
  String toString() => 'Operation $operationId was cancelled (${reason.name}).';
}

class OperationCancellationToken {
  OperationCancellationToken._(this._context);

  final OperationContext _context;

  bool get isCancelled => _context.isCancelled;
  OperationCancelReason? get reason => _context.cancelReason;
  Future<OperationCancelReason> get whenCancelled => _context._cancelled.future;

  void throwIfCancelled() => _context.throwIfCancelled();
}

typedef OperationAction = FutureOr<void> Function();

class OperationResource {
  OperationResource._(this._owner, this._record);

  final OperationContext _owner;
  final _OperationResourceRecord _record;

  bool get isActive => _record.active;

  Future<void> release({bool runCleanup = false}) =>
      _owner._releaseResource(_record, runCleanup: runCleanup);
}

class OperationContext {
  OperationContext._({
    required this.id,
    required this.target,
    required this.startedAt,
    required this.deadline,
    required void Function(OperationContext context) onClosed,
  }) : _onClosed = onClosed {
    token = OperationCancellationToken._(this);
    final effectiveDeadline = deadline;
    if (effectiveDeadline != null) {
      final remaining = effectiveDeadline.difference(DateTime.now());
      if (remaining <= Duration.zero) {
        scheduleMicrotask(
          () => unawaited(cancel(OperationCancelReason.deadlineExceeded)),
        );
      } else {
        _deadlineTimer = Timer(
          remaining,
          () => unawaited(cancel(OperationCancelReason.deadlineExceeded)),
        );
      }
    }
  }

  final int id;
  final DeviceTarget target;
  final DateTime startedAt;
  final DateTime? deadline;
  final void Function(OperationContext context) _onClosed;
  final List<_OperationResourceRecord> _resources =
      <_OperationResourceRecord>[];
  final Completer<OperationCancelReason> _cancelled =
      Completer<OperationCancelReason>();
  final List<Object> _cleanupErrors = <Object>[];

  late final OperationCancellationToken token;
  Timer? _deadlineTimer;
  OperationCancelReason? _cancelReason;
  Future<void>? _closeFuture;
  bool _acceptingResources = true;
  bool _closed = false;

  bool get isCancelled => _cancelReason != null;
  bool get isClosed => _closed;
  OperationCancelReason? get cancelReason => _cancelReason;
  UnmodifiableListView<Object> get cleanupErrors =>
      UnmodifiableListView<Object>(_cleanupErrors);

  void throwIfCancelled() {
    final reason = _cancelReason;
    if (reason != null) {
      throw OperationCancelledException(operationId: id, reason: reason);
    }
  }

  OperationResource deferCleanup(OperationAction cleanup) {
    if (!_acceptingResources) {
      throw StateError('Operation $id no longer accepts cleanup resources.');
    }
    final record = _OperationResourceRecord(cleanup: cleanup);
    _resources.add(record);
    return OperationResource._(this, record);
  }

  Future<OperationResource> own({
    OperationAction? cancel,
    OperationAction? cleanup,
  }) async {
    if (_acceptingResources) {
      final record = _OperationResourceRecord(
        cancel: cancel,
        cleanup: cleanup,
      );
      _resources.add(record);
      return OperationResource._(this, record);
    }

    if (isCancelled) {
      await _recordAction(cancel);
      await _recordAction(cleanup);
      throw OperationCancelledException(
        operationId: id,
        reason: _cancelReason!,
      );
    }
    throw StateError('Operation $id is already complete.');
  }

  Future<void> cancel([
    OperationCancelReason reason = OperationCancelReason.requested,
  ]) {
    if (_closed && _cancelReason == null) return Future<void>.value();
    if (_cancelReason == null) {
      _cancelReason = reason;
      if (!_cancelled.isCompleted) _cancelled.complete(reason);
    }
    return _close(cancelResources: true);
  }

  Future<void> complete() => _close(cancelResources: isCancelled);

  Future<void> _close({required bool cancelResources}) {
    final existing = _closeFuture;
    if (existing != null) return existing;
    _acceptingResources = false;
    _deadlineTimer?.cancel();
    _deadlineTimer = null;
    final future = _drain(cancelResources: cancelResources);
    _closeFuture = future;
    return future;
  }

  Future<void> _drain({required bool cancelResources}) async {
    try {
      if (cancelResources) {
        for (final resource in _resources.reversed) {
          if (!resource.active || resource.cancelInvoked) continue;
          resource.cancelInvoked = true;
          await _recordAction(resource.cancel);
        }
      }
      for (final resource in _resources.reversed) {
        if (!resource.active) continue;
        resource.active = false;
        await _recordAction(resource.cleanup);
      }
    } finally {
      _closed = true;
      _onClosed(this);
    }
  }

  Future<void> _releaseResource(
    _OperationResourceRecord resource, {
    required bool runCleanup,
  }) async {
    if (!resource.active) return;
    resource.active = false;
    if (runCleanup) await _recordAction(resource.cleanup);
  }

  Future<void> _recordAction(OperationAction? action) async {
    try {
      await _runAction(action);
    } catch (error) {
      _cleanupErrors.add(error);
    }
  }

  Future<void> _runAction(OperationAction? action) async {
    if (action != null) await action();
  }
}

class OperationRegistry {
  final Map<int, OperationContext> _active = <int, OperationContext>{};
  int _nextId = 1;

  int get activeCount => _active.length;
  Iterable<OperationContext> get activeOperations =>
      List<OperationContext>.unmodifiable(_active.values);

  OperationContext begin({
    required DeviceTarget target,
    DateTime? deadline,
  }) {
    final id = _nextId++;
    final context = OperationContext._(
      id: id,
      target: target,
      startedAt: DateTime.now(),
      deadline: deadline,
      onClosed: (closed) {
        if (identical(_active[closed.id], closed)) {
          _active.remove(closed.id);
        }
      },
    );
    _active[id] = context;
    return context;
  }

  Future<void> cancelWhere(
    bool Function(OperationContext operation) test,
    OperationCancelReason reason,
  ) async {
    final selected = _active.values.where(test).toList(growable: false);
    await Future.wait<void>(
      selected.map((operation) => operation.cancel(reason)),
    );
  }

  Future<void> cancelAll([
    OperationCancelReason reason = OperationCancelReason.runtimeShutdown,
  ]) =>
      cancelWhere((_) => true, reason);
}

class _OperationResourceRecord {
  _OperationResourceRecord({this.cancel, this.cleanup});

  final OperationAction? cancel;
  final OperationAction? cleanup;
  bool active = true;
  bool cancelInvoked = false;
}

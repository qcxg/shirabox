import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:path/path.dart' as p;
import '../providers/app_state.dart';
import '../providers/file_transfer_provider.dart';
import '../services/adb_file.dart';
import '../services/local_path_codec.dart';
import '../services/operation_context.dart';
import '../l10n/app_localizations.dart';

class FilesPage extends StatefulWidget {
  const FilesPage({super.key});

  @override
  State<FilesPage> createState() => _FilesPageState();
}

class _FilesPageState extends State<FilesPage> {
  final TextEditingController _pathController =
      TextEditingController(text: "/sdcard");
  List<AdbFile> _files = [];
  bool _loading = false;
  bool _isSelectionMode = false;
  final Set<String> _selectedPaths = {};
  int _loadGeneration = 0;
  String? _displayedSerial;
  String? _displayedPath;
  int? _displayedEpoch;
  String? _listError;
  StreamSubscription<AdbDirectoryPage>? _listingSubscription;
  Completer<void>? _listingCompletion;

  OperationContext _attachTransferOperation(
    AppState appState,
    FileTransferProvider transfers,
    int jobId,
    String serial,
  ) {
    final operation = appState.adb.beginOperation(serial: serial);
    transfers.attachCancellation(jobId, operation.cancel);
    return operation;
  }

  bool _transferCancelled(
    FileTransferProvider transfers,
    int jobId,
    OperationContext operation,
  ) =>
      transfers.shouldStop(jobId) || operation.isCancelled;
  AppState? _appState;
  String? _observedSerial;
  int? _observedEpoch;
  bool _sessionReloadScheduled = false;

  bool _pickerActive = false;

  @override
  void initState() {
    super.initState();
    _loadFiles(_pathController.text);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final nextAppState = context.read<AppState>();
    if (identical(_appState, nextAppState)) return;
    _appState?.removeListener(_handleDeviceSessionChanged);
    _appState = nextAppState;
    _observedSerial = nextAppState.currentDevice;
    _observedEpoch = nextAppState.deviceSessionEpoch;
    nextAppState.addListener(_handleDeviceSessionChanged);
  }

  void _handleDeviceSessionChanged() {
    final appState = _appState;
    if (appState == null || !mounted) return;
    final serial = appState.currentDevice;
    final epoch = appState.deviceSessionEpoch;
    if (serial == _observedSerial && epoch == _observedEpoch) return;
    _observedSerial = serial;
    _observedEpoch = epoch;
    if (_sessionReloadScheduled) return;
    _sessionReloadScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _sessionReloadScheduled = false;
      if (!mounted) return;
      _pathController.text = '/sdcard';
      unawaited(_loadFiles('/sdcard'));
    });
  }

  @override
  void dispose() {
    _appState?.removeListener(_handleDeviceSessionChanged);
    _appState = null;
    _loadGeneration++;
    final completion = _listingCompletion;
    _listingCompletion = null;
    if (completion != null && !completion.isCompleted) completion.complete();
    unawaited(_listingSubscription?.cancel());
    _pathController.dispose();
    super.dispose();
  }

  Future<void> _loadFiles(String path) async {
    if (!mounted) return;
    final requestId = ++_loadGeneration;
    final previousFiles = List<AdbFile>.of(_files);
    final previousPath = _displayedPath;
    final previousSerial = _displayedSerial;
    final previousEpoch = _displayedEpoch;
    final oldSubscription = _listingSubscription;
    _listingSubscription = null;
    final oldCompletion = _listingCompletion;
    _listingCompletion = null;
    if (oldCompletion != null && !oldCompletion.isCompleted) {
      oldCompletion.complete();
    }
    if (oldSubscription != null) {
      await oldSubscription.cancel();
      if (!mounted || requestId != _loadGeneration) return;
    }
    setState(() {
      _isSelectionMode = false;
      _selectedPaths.clear();
      _files = <AdbFile>[];
      _displayedPath = null;
      _displayedSerial = null;
      _displayedEpoch = null;
      _listError = null;
      _loading = true;
    });
    String cleanPath = path.trim();
    if (cleanPath.isEmpty) cleanPath = "/";
    cleanPath = p.posix.normalize(cleanPath);
    if (!cleanPath.startsWith('/')) {
      cleanPath = '/$cleanPath';
    }
    cleanPath = p.posix.normalize(cleanPath);
    _pathController.text = cleanPath;
    final appState = context.read<AppState>();
    final serial = appState.currentDevice;
    final epoch = appState.deviceSessionEpoch;
    if (serial == null) {
      if (mounted && requestId == _loadGeneration) {
        setState(() {
          _loading = false;
          _listError = 'No target device selected.';
        });
      }
      return;
    }

    bool isCurrentRequest() =>
        mounted &&
        requestId == _loadGeneration &&
        appState.isDeviceSessionActive(serial, epoch);

    final completion = Completer<void>();
    _listingCompletion = completion;
    late final StreamSubscription<AdbDirectoryPage> subscription;
    subscription = appState.files
        .listFilePages(cleanPath, serial: serial, pageSize: 256)
        .listen((page) {
      if (!isCurrentRequest()) return;
      if (page.entries.isNotEmpty) {
        setState(() {
          _files.addAll(page.entries);
        });
      }
    }, onError: (Object error, StackTrace stackTrace) {
      if (isCurrentRequest()) {
        appState.addLog('List dir failed ($cleanPath): $error');
        setState(() {
          final canRestore = previousPath != null &&
              previousSerial == serial &&
              previousEpoch == epoch;
          _files = canRestore ? previousFiles : <AdbFile>[];
          _displayedPath = canRestore ? previousPath : null;
          _displayedSerial = canRestore ? previousSerial : null;
          _displayedEpoch = canRestore ? previousEpoch : null;
          _pathController.text = previousPath ?? cleanPath;
          _listError = error.toString();
          _loading = false;
        });
      }
      if (!completion.isCompleted) completion.complete();
    }, onDone: () {
      if (isCurrentRequest()) {
        setState(() {
          _displayedPath = cleanPath;
          _displayedSerial = serial;
          _displayedEpoch = epoch;
          _pathController.text = cleanPath;
          _loading = false;
        });
      }
      if (!completion.isCompleted) completion.complete();
    }, cancelOnError: true);
    _listingSubscription = subscription;
    await completion.future;
    if (identical(_listingSubscription, subscription)) {
      _listingSubscription = null;
    }
    if (identical(_listingCompletion, completion)) {
      _listingCompletion = null;
    }
  }

  bool _beginPicker() {
    if (!mounted ||
        _pickerActive ||
        _loading ||
        _displayedPath == null ||
        context.read<FileTransferProvider>().isBusy) {
      return false;
    }
    setState(() => _pickerActive = true);
    return true;
  }

  void _finishPicker() {
    if (mounted) setState(() => _pickerActive = false);
  }

  String? _operationSerial(AppState appState) {
    final serial = _displayedSerial;
    final epoch = _displayedEpoch;
    if (_loading ||
        _displayedPath == null ||
        serial == null ||
        epoch == null ||
        !appState.isDeviceSessionActive(serial, epoch)) {
      appState
          .addLog('Device changed; reload the file list before continuing.');
      if (mounted) _loadFiles(_pathController.text);
      return null;
    }
    return serial;
  }

  void _goUp() {
    String current = _displayedPath ?? _pathController.text.trim();
    if (current == '/' || current.isEmpty) return;
    int lastSlash = current.lastIndexOf('/');
    if (lastSlash <= 0) {
      _loadFiles("/");
    } else {
      _loadFiles(current.substring(0, lastSlash));
    }
  }

  void _toggleSelectionMode(bool val) {
    setState(() {
      _isSelectionMode = val;
      if (!val) _selectedPaths.clear();
    });
  }

  void _toggleItemSelection(AdbFile file) {
    setState(() {
      if (_selectedPaths.contains(file.path)) {
        _selectedPaths.remove(file.path);
      } else {
        _selectedPaths.add(file.path);
      }
    });
  }

  void _selectAll(bool select) {
    setState(() {
      if (select) {
        _selectedPaths.addAll(_files.map((e) => e.path));
      } else {
        _selectedPaths.clear();
      }
    });
  }

  Future<void> _batchDownload() async {
    final i18n = AppLocalizations.of(context)!;
    final appState = context.read<AppState>();
    if (_selectedPaths.isEmpty) return;

    final selectedItems = _files
        .where((file) =>
            _selectedPaths.contains(file.path) &&
            (file.type == AdbFileType.file ||
                file.type == AdbFileType.directory))
        .toList(growable: false);
    final skippedItems = _selectedPaths.length - selectedItems.length;
    if (skippedItems > 0) {
      appState.addLog(
        'Skipped $skippedItems symbolic-link or special-file item(s).',
      );
    }
    if (selectedItems.isEmpty) return;

    if (!_beginPicker()) return;
    String? outputDir;
    try {
      outputDir = await FilePicker.platform.getDirectoryPath();
    } finally {
      _finishPicker();
    }
    if (!mounted || outputDir == null) return;

    final serial = _operationSerial(appState);
    if (serial == null) return;
    final transfers = context.read<FileTransferProvider>();
    final jobId = transfers.begin(
      action: i18n.filesTransferDownloading,
      total: selectedItems.length,
      serial: serial,
    );
    if (jobId == null) return;
    final operation =
        _attachTransferOperation(appState, transfers, jobId, serial);

    int successCount = 0;
    final reservedDestinations = <String>{};
    appState.addLog('Batch export started: ${selectedItems.length} item(s)');

    try {
      for (var index = 0; index < selectedItems.length; index++) {
        if (_transferCancelled(transfers, jobId, operation)) break;
        final item = selectedItems[index];
        final remotePath = item.path;
        final fileName = item.name;
        transfers.beginItem(jobId, fileName);
        appState.addLog(
          'Exporting (${index + 1}/${selectedItems.length}): $fileName',
        );

        var succeeded = false;
        var wasCancelled = false;
        try {
          final localFullPath = await chooseLocalDownloadPath(
            outputDir,
            fileName,
            reservedPaths: reservedDestinations,
          );
          if (item.isDir) {
            await appState.files.pullDirectory(
              remotePath,
              localFullPath,
              serial: serial,
              onProgress: (value) => transfers.updateProgress(jobId, value),
              isCancelled: () => transfers.shouldStop(jobId),
              symlinkPolicy: RecursiveSymlinkPolicy.reject,
              operation: operation,
            );
          } else {
            await appState.files.pullFile(
              remotePath,
              localFullPath,
              serial: serial,
              onProgress: (value) => transfers.updateProgress(jobId, value),
              operation: operation,
            );
          }
          successCount++;
          succeeded = true;
        } on TransferCancelledException {
          wasCancelled = true;
          appState.addLog('Export cancelled ($fileName)');
        } catch (e) {
          if (_transferCancelled(transfers, jobId, operation)) {
            wasCancelled = true;
            appState.addLog('Export cancelled ($fileName)');
          } else {
            appState.addLog("Export Failed ($fileName): $e");
          }
        } finally {
          transfers.completeItem(
            jobId,
            success: succeeded,
            wasCancelled: wasCancelled,
          );
        }
      }
    } finally {
      await operation.complete();
      transfers.finish(jobId);
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              "${i18n.filesSnackDownloadDone} ($successCount/${selectedItems.length})")));
    }
  }

  Future<void> _batchDelete() async {
    final i18n = AppLocalizations.of(context)!;
    final appState = context.read<AppState>();
    if (_selectedPaths.isEmpty) return;

    // 【核心修復】複製路徑
    final List<String> pathsToDelete = _selectedPaths.toList();

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(i18n.filesDeleteDialogTitle),
        content: Text(i18n.filesDeleteConfirmBatch(pathsToDelete.length)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(i18n.btnCancel)),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(i18n.filesMenuDelete),
          ),
        ],
      ),
    );

    if (confirm == true && mounted) {
      final serial = _operationSerial(appState);
      if (serial == null) return;
      final transfers = context.read<FileTransferProvider>();
      final jobId = transfers.begin(
        action: i18n.filesTransferDeleting,
        total: pathsToDelete.length,
        serial: serial,
      );
      if (jobId == null) return;
      final operation =
          _attachTransferOperation(appState, transfers, jobId, serial);
      try {
        for (String remotePath in pathsToDelete) {
          if (_transferCancelled(transfers, jobId, operation)) break;
          final fileName = p.posix.basename(remotePath);
          transfers.beginItem(jobId, fileName);
          var succeeded = false;
          var wasCancelled = false;
          try {
            await appState.files.deleteFile(
              remotePath,
              serial: serial,
              operation: operation,
            );
            appState.addLog("Deleted: $remotePath");
            succeeded = true;
          } catch (e) {
            if (_transferCancelled(transfers, jobId, operation)) {
              wasCancelled = true;
              appState.addLog('Delete cancelled ($remotePath)');
            } else {
              appState.addLog("Delete Failed ($remotePath): $e");
            }
          } finally {
            transfers.completeItem(
              jobId,
              success: succeeded,
              wasCancelled: wasCancelled,
            );
          }
        }
      } finally {
        await operation.complete();
        transfers.finish(jobId);
      }
      if (mounted) _loadFiles(_pathController.text);
    }
  }

  Future<void> _handleUpload(List<dynamic> files) async {
    if (!mounted) return;
    final paths = files
        .map((file) => file.path.toString())
        .where((path) => path.isNotEmpty)
        .toList(growable: false);
    await _handleUploadPaths(paths);
  }

  Future<void> _pickUploadFiles() async {
    if (!_beginPicker()) return;
    FilePickerResult? result;
    try {
      result = await FilePicker.platform.pickFiles(allowMultiple: true);
    } finally {
      _finishPicker();
    }
    if (!mounted || result == null) return;
    final paths = result.paths.whereType<String>().toList(growable: false);
    await _handleUploadPaths(paths);
  }

  Future<void> _pickUploadFolder() async {
    if (!_beginPicker()) return;
    String? path;
    try {
      path = await FilePicker.platform.getDirectoryPath();
    } finally {
      _finishPicker();
    }
    if (!mounted || path == null || path.isEmpty) return;
    await _handleUploadPaths(<String>[path]);
  }

  Future<void> _handleUploadPaths(List<String> paths) async {
    if (paths.isEmpty) return;
    final i18n = AppLocalizations.of(context)!;
    final appState = context.read<AppState>();
    final serial = _operationSerial(appState);
    if (serial == null) return;
    final currentPath = _displayedPath;
    if (currentPath == null) return;
    final transfers = context.read<FileTransferProvider>();
    final jobId = transfers.begin(
      action: i18n.filesTransferUploading,
      total: paths.length,
      serial: serial,
    );
    if (jobId == null) return;
    final operation =
        _attachTransferOperation(appState, transfers, jobId, serial);

    var successCount = 0;
    appState.addLog('Upload batch received: ${paths.length} item(s)');
    try {
      for (final localPath in List<String>.from(paths)) {
        if (_transferCancelled(transfers, jobId, operation)) break;
        final fileName = p.basename(localPath);
        transfers.beginItem(jobId, fileName);
        appState.addLog("Uploading: $localPath");
        var succeeded = false;
        var wasCancelled = false;
        try {
          final type = await FileSystemEntity.type(
            localPath,
            followLinks: false,
          );
          if (type == FileSystemEntityType.directory) {
            await appState.files.pushDirectory(
              localPath,
              currentPath,
              serial: serial,
              onProgress: (value) => transfers.updateProgress(jobId, value),
              isCancelled: () => transfers.shouldStop(jobId),
              symlinkPolicy: RecursiveSymlinkPolicy.reject,
              operation: operation,
            );
          } else if (type == FileSystemEntityType.file) {
            await appState.files.pushFile(
              localPath,
              currentPath,
              serial: serial,
              onProgress: (value) => transfers.updateProgress(jobId, value),
              operation: operation,
            );
          } else if (type == FileSystemEntityType.link) {
            throw FileSystemException(
              'Symbolic-link upload roots are not supported.',
              localPath,
            );
          } else {
            throw FileSystemException(
              'Upload source is not a regular file or directory.',
              localPath,
            );
          }
          appState.addLog("Upload Success: $fileName");
          succeeded = true;
          successCount++;
        } on TransferCancelledException {
          wasCancelled = true;
          appState.addLog('Upload cancelled ($fileName)');
        } catch (e) {
          if (_transferCancelled(transfers, jobId, operation)) {
            wasCancelled = true;
            appState.addLog('Upload cancelled ($fileName)');
          } else {
            appState.addLog("Upload Failed ($fileName): $e");
          }
        } finally {
          transfers.completeItem(
            jobId,
            success: succeeded,
            wasCancelled: wasCancelled,
          );
        }
      }
    } finally {
      await operation.complete();
      transfers.finish(jobId);
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(i18n.filesUploadComplete(successCount, paths.length)),
      ));
      await _loadFiles(currentPath);
    }
  }

  Future<void> _downloadFile(AdbFile file) async {
    final i18n = AppLocalizations.of(context)!;
    if (file.type != AdbFileType.file && file.type != AdbFileType.directory) {
      return;
    }
    if (!_beginPicker()) return;
    String? outputDir;
    try {
      outputDir = await FilePicker.platform.getDirectoryPath();
    } finally {
      _finishPicker();
    }
    if (!mounted || outputDir == null) return;
    final appState = context.read<AppState>();
    final serial = _operationSerial(appState);
    if (serial == null) return;
    final transfers = context.read<FileTransferProvider>();
    final jobId = transfers.begin(
      action: i18n.filesTransferDownloading,
      total: 1,
      serial: serial,
    );
    if (jobId == null) return;
    final operation =
        _attachTransferOperation(appState, transfers, jobId, serial);
    appState.addLog("Downloading: ${file.name}");
    var succeeded = false;
    var wasCancelled = false;
    try {
      transfers.beginItem(jobId, file.name);
      final localFullPath = await chooseLocalDownloadPath(outputDir, file.name);
      if (file.isDir) {
        await appState.files.pullDirectory(
          file.path,
          localFullPath,
          serial: serial,
          onProgress: (value) => transfers.updateProgress(jobId, value),
          isCancelled: () => transfers.shouldStop(jobId),
          symlinkPolicy: RecursiveSymlinkPolicy.reject,
          operation: operation,
        );
      } else {
        await appState.files.pullFile(
          file.path,
          localFullPath,
          serial: serial,
          onProgress: (value) => transfers.updateProgress(jobId, value),
          operation: operation,
        );
      }
      succeeded = true;
      appState.addLog("Download Saved to: $outputDir");
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(i18n.filesSnackDownloadDone)));
      }
    } on TransferCancelledException {
      wasCancelled = true;
      appState.addLog('Download cancelled: ${file.name}');
    } catch (e) {
      if (_transferCancelled(transfers, jobId, operation)) {
        wasCancelled = true;
        appState.addLog('Download cancelled: ${file.name}');
      } else {
        appState.addLog("Download Failed: $e");
      }
    } finally {
      transfers.completeItem(
        jobId,
        success: succeeded,
        wasCancelled: wasCancelled,
      );
      await operation.complete();
      transfers.finish(jobId);
    }
  }

  Future<void> _deleteFile(AdbFile file) async {
    final i18n = AppLocalizations.of(context)!;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(i18n.filesDeleteDialogTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(i18n.filesDeleteDialogContent),
            const SizedBox(height: 8),
            Text(file.name,
                style: const TextStyle(
                    fontWeight: FontWeight.bold, color: Colors.red)),
            const SizedBox(height: 8),
            Text(i18n.filesDeleteDialogPath(file.path),
                style: const TextStyle(fontSize: 12, color: Colors.grey)),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(i18n.btnCancel)),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(i18n.filesMenuDelete),
          ),
        ],
      ),
    );
    if (confirm == true && mounted) {
      final appState = context.read<AppState>();
      final serial = _operationSerial(appState);
      if (serial == null) return;
      final transfers = context.read<FileTransferProvider>();
      final jobId = transfers.begin(
        action: i18n.filesTransferDeleting,
        total: 1,
        serial: serial,
      );
      if (jobId == null) return;
      final operation =
          _attachTransferOperation(appState, transfers, jobId, serial);
      transfers.beginItem(jobId, file.name);
      var succeeded = false;
      var wasCancelled = false;
      try {
        await appState.files.deleteFile(
          file.path,
          serial: serial,
          operation: operation,
        );
        appState.addLog("Deleted: ${file.name}");
        succeeded = true;
      } catch (e) {
        if (_transferCancelled(transfers, jobId, operation)) {
          wasCancelled = true;
          appState.addLog('Delete cancelled: ${file.name}');
        } else {
          appState.addLog("Delete Failed: $e");
        }
        if (mounted && !wasCancelled) {
          ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(i18n.filesSnackDeleteFail(e.toString()))));
        }
      } finally {
        transfers.completeItem(
          jobId,
          success: succeeded,
          wasCancelled: wasCancelled,
        );
        await operation.complete();
        transfers.finish(jobId);
      }
      if (mounted) _loadFiles(_pathController.text);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final outlineColor = theme.colorScheme.outlineVariant;
    final i18n = AppLocalizations.of(context)!;
    final transfersBusy = context.select<FileTransferProvider, bool>(
      (transfers) => transfers.isBusy,
    );
    final transferableSelectedCount = _files
        .where((file) =>
            _selectedPaths.contains(file.path) &&
            (file.type == AdbFileType.file ||
                file.type == AdbFileType.directory))
        .length;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: Row(
            children: [
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  decoration: BoxDecoration(
                    border: Border.all(color: outlineColor),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.arrow_upward),
                        onPressed: () => _goUp(),
                        tooltip: "Up",
                      ),
                      Expanded(
                        child: TextField(
                          controller: _pathController,
                          style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontFamily: 'Consolas'),
                          decoration: InputDecoration(
                            border: InputBorder.none,
                            contentPadding:
                                const EdgeInsets.symmetric(horizontal: 8),
                            hintText: i18n.filesPathHint,
                          ),
                          onSubmitted: (value) => _loadFiles(value),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.refresh),
                        onPressed: () => _loadFiles(_pathController.text),
                        tooltip: i18n.processBtnRefresh,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 12),
              FilterChip(
                label: Text(i18n.filesSelectMode),
                selected: _isSelectionMode,
                onSelected: _toggleSelectionMode,
              ),
            ],
          ),
        ),
        if (_loading) const LinearProgressIndicator(minHeight: 2),
        if (_loading || _files.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                i18n.filesLoadedCount(_files.length),
                style: theme.textTheme.bodySmall,
              ),
            ),
          ),
        if (_listError != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                i18n.filesListingFailed(_listError!),
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ),
          ),
        Consumer<FileTransferProvider>(
          builder: (context, transfers, child) {
            if (!transfers.isBusy) return const SizedBox.shrink();
            return Container(
              margin: const EdgeInsets.fromLTRB(8, 4, 8, 8),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${transfers.action} '
                          '${(transfers.completed + 1).clamp(1, transfers.total)}/'
                          '${transfers.total}: ${transfers.currentName}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 6),
                        LinearProgressIndicator(
                          value: transfers.total == 0
                              ? null
                              : (transfers.completed +
                                      transfers.currentItemProgress) /
                                  transfers.total,
                        ),
                      ],
                    ),
                  ),
                  if (transfers.failures > 0) ...[
                    const SizedBox(width: 12),
                    Text(
                      i18n.filesTransferFailed(transfers.failures),
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  ],
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed:
                        transfers.stopRequested ? null : transfers.requestStop,
                    child: Text(i18n.filesTransferStop),
                  ),
                ],
              ),
            );
          },
        ),
        Expanded(
          child: Row(
            children: [
              Expanded(
                flex: 3,
                child: ListView.builder(
                  itemCount: _files.length,
                  itemBuilder: (context, index) {
                    final file = _files[index];
                    final isSelected = _selectedPaths.contains(file.path);

                    return ListTile(
                      dense: true,
                      leading: _isSelectionMode
                          ? Checkbox(
                              value: isSelected,
                              onChanged: (v) => _toggleItemSelection(file),
                            )
                          : Icon(
                              file.isDir
                                  ? Icons.folder_outlined
                                  : file.isSymlink
                                      ? Icons.link
                                      : file.type == AdbFileType.file
                                          ? Icons.insert_drive_file_outlined
                                          : Icons.device_unknown_outlined,
                              color: file.isDir
                                  ? theme.colorScheme.primary
                                  : file.isSymlink
                                      ? theme.colorScheme.tertiary
                                      : null,
                            ),
                      title: Text(file.name),
                      tileColor: isSelected
                          ? theme.colorScheme.primaryContainer
                              .withValues(alpha: 0.3)
                          : null,
                      onTap: () {
                        if (_isSelectionMode) {
                          _toggleItemSelection(file);
                        } else {
                          if (!_loading && file.isDir) _loadFiles(file.path);
                        }
                      },
                      // 【核心修复】恢复右键菜单
                      trailing: _isSelectionMode
                          ? null
                          : PopupMenuButton<String>(
                              icon: const Icon(Icons.more_vert, size: 18),
                              itemBuilder: (context) => [
                                if (file.type == AdbFileType.file ||
                                    file.type == AdbFileType.directory)
                                  PopupMenuItem(
                                    value: 'dl',
                                    child: Row(children: [
                                      const Icon(Icons.download, size: 18),
                                      const SizedBox(width: 8),
                                      Text(i18n.filesMenuDownload)
                                    ]),
                                  ),
                                PopupMenuItem(
                                  value: 'del',
                                  child: Row(children: [
                                    const Icon(Icons.delete,
                                        size: 18, color: Colors.red),
                                    const SizedBox(width: 8),
                                    Text(i18n.filesMenuDelete,
                                        style:
                                            const TextStyle(color: Colors.red))
                                  ]),
                                ),
                              ],
                              onSelected: (value) {
                                if (context
                                        .read<FileTransferProvider>()
                                        .isBusy ||
                                    _pickerActive ||
                                    _loading) {
                                  return;
                                }
                                if (value == 'dl') _downloadFile(file);
                                if (value == 'del') _deleteFile(file);
                              },
                            ),
                    );
                  },
                ),
              ),
              const VerticalDivider(width: 1),
              Expanded(
                flex: 1,
                child: DropTarget(
                  onDragDone: (detail) {
                    if (!transfersBusy &&
                        !_pickerActive &&
                        !_loading &&
                        _displayedPath != null) {
                      _handleUpload(detail.files);
                    }
                  },
                  child: Container(
                    margin: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      border: Border.all(
                          color:
                              theme.colorScheme.primary.withValues(alpha: 0.5),
                          width: 2),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.cloud_upload_outlined,
                            size: 48, color: theme.colorScheme.primary),
                        const SizedBox(height: 16),
                        Text(i18n.filesUploadDrop, textAlign: TextAlign.center),
                        const SizedBox(height: 16),
                        Wrap(
                          alignment: WrapAlignment.center,
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            OutlinedButton.icon(
                              onPressed: transfersBusy ||
                                      _pickerActive ||
                                      _loading ||
                                      _displayedPath == null
                                  ? null
                                  : _pickUploadFiles,
                              icon: const Icon(Icons.file_open),
                              label: Text(i18n.filesChooseFiles),
                            ),
                            OutlinedButton.icon(
                              onPressed: transfersBusy ||
                                      _pickerActive ||
                                      _loading ||
                                      _displayedPath == null
                                  ? null
                                  : _pickUploadFolder,
                              icon: const Icon(Icons.folder_open),
                              label: Text(i18n.filesChooseFolder),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        if (_isSelectionMode)
          Container(
            padding: const EdgeInsets.all(12),
            color: theme.colorScheme.surfaceContainerHighest,
            child: Row(
              children: [
                Text(i18n.filesSelected(_selectedPaths.length)),
                const SizedBox(width: 16),
                TextButton(
                    onPressed: () => _selectAll(true),
                    child: Text(i18n.filesSelectAll)),
                TextButton(
                    onPressed: () => _selectAll(false),
                    child: Text(i18n.filesDeselect)),
                const Spacer(),
                FilledButton.tonalIcon(
                  onPressed: transferableSelectedCount == 0 ||
                          transfersBusy ||
                          _pickerActive ||
                          _loading
                      ? null
                      : _batchDownload,
                  icon: const Icon(Icons.download),
                  label: Text(
                    i18n.filesExportSelected(transferableSelectedCount),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: _selectedPaths.isEmpty ||
                          transfersBusy ||
                          _pickerActive ||
                          _loading
                      ? null
                      : _batchDelete,
                  style: FilledButton.styleFrom(
                      backgroundColor: theme.colorScheme.error),
                  icon: const Icon(Icons.delete),
                  label: Text(i18n.filesDeleteSelected),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

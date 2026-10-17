// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'Shirabox';

  @override
  String get navConnect => 'Connect';

  @override
  String get navWireless => 'Wireless';

  @override
  String get navApps => 'Apps';

  @override
  String get navFiles => 'Files';

  @override
  String get navLogs => 'Logcat';

  @override
  String get navTools => 'Tools';

  @override
  String get navMirror => 'Mirror';

  @override
  String get navSettings => 'Settings';

  @override
  String get homeWaitDevice => 'Waiting for device...';

  @override
  String get homeWaitHint => 'Ensure USB debugging is on.';

  @override
  String get homeManualCheck => 'Check Manually';

  @override
  String get homeNoAdbTitle => 'ADB Not Found';

  @override
  String get homeNoAdbContent =>
      'adb.exe not found in PATH.\nPlease install drivers or set path.';

  @override
  String get homeGoSettings => 'Set Path';

  @override
  String get homeRetryCheck => 'Retry';

  @override
  String get homeTabCpu => 'CPU';

  @override
  String get homeTabRam => 'RAM';

  @override
  String get homeTabStorage => 'Storage';

  @override
  String get homeItemKernel => 'Kernel';

  @override
  String get homeQuickBoot => 'Quick Boot';

  @override
  String get appsSystemApps => 'Show System Apps';

  @override
  String get appsSearchHint => 'Search apps...';

  @override
  String get appsMultiSelect => 'Multi-Select';

  @override
  String get appsRefresh => 'Refresh';

  @override
  String get appsEmpty => 'No Data';

  @override
  String get appsDropHint => 'Drop APK / XAPK / APKS\nto Install';

  @override
  String appsSelected(int count) {
    return 'Selected: $count';
  }

  @override
  String get appsSelectAll => 'Select All';

  @override
  String get appsDeselect => 'Cancel';

  @override
  String get appsBatchExtract => 'Batch Extract';

  @override
  String get appsExtractSuccess => 'Extracted Successfully';

  @override
  String appsExtractFail(String error) {
    return 'Extract Failed: $error';
  }

  @override
  String get appsBatchExtractFinish => 'Batch task finished, check logs';

  @override
  String get actionExtractApk => 'Extract APK';

  @override
  String get actionExtractAll => 'Extract All (APKS)';

  @override
  String get actionFreeze => 'Freeze App';

  @override
  String get actionUnfreeze => 'Unfreeze App';

  @override
  String get actionUninstall => 'Uninstall';

  @override
  String get actionOpen => 'Open App';

  @override
  String get appsLaunchWithMirror => 'Launch with Mirroring';

  @override
  String get installDialogTitleInstalling => 'Installing...';

  @override
  String get installDialogTitleDone => 'Installation Complete';

  @override
  String get installDialogClose => 'Close';

  @override
  String get installStopAfterCurrent => 'Stop';

  @override
  String installCompletedCount(int completed, int total) {
    return 'Completed $completed/$total';
  }

  @override
  String get installVerifyRefresh => 'Refreshing App List...';

  @override
  String get installSuccessToast => 'Install done, refreshing list...';

  @override
  String get appsChoosePackages => 'Choose packages';

  @override
  String get filesPathHint => 'Enter path...';

  @override
  String get filesUploadDrop => 'Drop files or folders here\nto upload';

  @override
  String get filesChooseFiles => 'Choose files';

  @override
  String get filesChooseFolder => 'Choose folder';

  @override
  String filesLoadedCount(int count) {
    return '$count items loaded';
  }

  @override
  String filesListingFailed(String error) {
    return 'Unable to list this folder: $error';
  }

  @override
  String get filesTransferStop => 'Stop';

  @override
  String get filesTransferUploading => 'Uploading';

  @override
  String get filesTransferDownloading => 'Downloading';

  @override
  String get filesTransferDeleting => 'Deleting';

  @override
  String filesTransferFailed(int count) {
    return '$count failed';
  }

  @override
  String filesUploadComplete(int success, int total) {
    return 'Upload complete ($success/$total)';
  }

  @override
  String get filesSelectMode => 'Multi-Select';

  @override
  String filesSelected(int count) {
    return 'Selected: $count';
  }

  @override
  String get filesSelectAll => 'Select All';

  @override
  String get filesDeselect => 'Cancel';

  @override
  String get filesDownloadSelected => 'Download Selected';

  @override
  String filesExportSelected(int count) {
    return 'Export Selected ($count)';
  }

  @override
  String get filesDeleteSelected => 'Delete Selected';

  @override
  String filesDeleteConfirmBatch(int count) {
    return 'Delete $count items?';
  }

  @override
  String get filesMenuDownload => 'Download';

  @override
  String get filesMenuDelete => 'Delete';

  @override
  String get filesDeleteDialogTitle => 'Confirm Delete';

  @override
  String get filesDeleteDialogContent => 'Permanently delete:';

  @override
  String filesDeleteDialogPath(String path) {
    return 'Path: $path';
  }

  @override
  String get filesSnackDownloadDone => 'Download Complete';

  @override
  String filesSnackDeleteFail(String error) {
    return 'Delete Failed: $error';
  }

  @override
  String get logcatHint => 'Filter logs...';

  @override
  String get logcatFilterHelp =>
      'Terms use AND. Try tag:ActivityManager, msg:\"not responding\", pid:1234, level:E,F, or -noise.';

  @override
  String get logcatRegex => 'Regex';

  @override
  String get logcatCaseSensitive => 'Match case';

  @override
  String get logcatResumeLive => 'Resume live tail';

  @override
  String logcatStats(int visible, int retained, int pending) {
    return '$visible visible / $retained retained / $pending pending';
  }

  @override
  String logcatDropped(int count) {
    return '$count input lines dropped';
  }

  @override
  String logcatFilterInvalid(String error) {
    return 'Invalid filter: $error';
  }

  @override
  String get logcatNoMatches => 'No matching log entries';

  @override
  String get logcatPid => 'PID';

  @override
  String get logcatTid => 'TID';

  @override
  String get logcatBtnStop => 'Stop';

  @override
  String get logcatBtnStart => 'Start';

  @override
  String get logcatClear => 'Clear';

  @override
  String get logcatExport => 'Export JSON';

  @override
  String get logcatExportTitle => 'Export Logcat JSON';

  @override
  String logcatExportSaved(String path) {
    return 'Saved: $path';
  }

  @override
  String get logcatBottom => 'Follow live tail';

  @override
  String get logcatDetailTitle => 'Log Details';

  @override
  String get logcatDetailTime => 'Time';

  @override
  String get logcatDetailLevel => 'Level';

  @override
  String get logcatDetailTag => 'Tag';

  @override
  String get logcatDetailContent => 'Message';

  @override
  String get logcatCopyAll => 'Copy All';

  @override
  String get logcatCopyContent => 'Copy Msg';

  @override
  String get toolsShell => 'Shell Terminal';

  @override
  String get toolsProcess => 'Process Manager';

  @override
  String get toolsProp => 'Prop Editor';

  @override
  String get toolsPropSearch => 'Search props...';

  @override
  String get toolsPropWarning =>
      'Caution: Props modified via ADB are usually reset after device reboot.';

  @override
  String get toolsPropEditTitle => 'Edit Property';

  @override
  String get toolsInspector => 'UI Inspector';

  @override
  String get toolsInspDump => 'Dump Layout';

  @override
  String get toolsInspNodeInfo => 'Node Properties';

  @override
  String get processShowSystem => 'Show System Processes';

  @override
  String get processAutoRefresh => 'Auto Refresh';

  @override
  String get processSearchHint => 'Search Name/PID...';

  @override
  String get processBtnRefresh => 'Refresh';

  @override
  String get processBtnKill => 'Kill';

  @override
  String processKillSuccess(String name) {
    return 'Killed: $name';
  }

  @override
  String processKillFail(String error) {
    return 'Failed: $error';
  }

  @override
  String get shellBtnRun => 'Run';

  @override
  String get scrcpyTitle => 'Scrcpy Mirror';

  @override
  String get scrcpyIntro =>
      'High-performance Android screen mirroring\nOpen Source: Genymobile/scrcpy';

  @override
  String get scrcpyBtnStart => 'Start';

  @override
  String get scrcpyParamPreview => 'Command Preview (Editable)';

  @override
  String get scrcpyGroupVideo => 'Video Settings';

  @override
  String get scrcpyGroupControl => 'Control Settings';

  @override
  String get scrcpyMaxSize => 'Max Size';

  @override
  String get scrcpyBitrate => 'Bitrate';

  @override
  String get scrcpyFps => 'Frame Rate (FPS)';

  @override
  String get scrcpyStayAwake => 'Stay Awake';

  @override
  String get scrcpyTurnOffScreen => 'Turn Screen Off';

  @override
  String get scrcpyShowTouches => 'Show Touches';

  @override
  String get scrcpyAlwaysOnTop => 'Always on Top';

  @override
  String get scrcpyNoAudio => 'No Audio';

  @override
  String get scrcpyKeyNav => 'HID Keyboard';

  @override
  String get qcVolUp => 'Vol+';

  @override
  String get qcVolDown => 'Vol-';

  @override
  String get qcBack => 'Back';

  @override
  String get qcHome => 'Home';

  @override
  String get qcRecent => 'Recent';

  @override
  String get qcShot => 'Shot';

  @override
  String get qcPaste => 'Paste';

  @override
  String get qcPower => 'Power';

  @override
  String get qcMenu => 'Menu';

  @override
  String get qcEnter => 'Enter';

  @override
  String get qcSpace => 'Space';

  @override
  String get settingsTitle => 'Settings';

  @override
  String get settingsLanguage => 'Language';

  @override
  String get settingsTheme => 'Appearance';

  @override
  String get settingsAdbPath => 'ADB Environment';

  @override
  String get settingsAdbManual => 'Manual ADB Path';

  @override
  String get settingsAdbFallback => 'Fallback: App Default';

  @override
  String get settingsAdbReset => 'Reset Default';

  @override
  String get settingsQuickBoot => 'Enhancements';

  @override
  String get settingsShowQuick => 'Show Quick Boot Buttons';

  @override
  String get colorPurple => 'Dream Purple';

  @override
  String get colorBlue => 'Deep Sea Blue';

  @override
  String get colorGreen => 'Forest Green';

  @override
  String get colorRed => 'Rose Red';

  @override
  String get colorOrange => 'Sunset Orange';

  @override
  String get colorPink => 'Sakura Pink';

  @override
  String get colorGrey => 'Minimalist Grey';

  @override
  String get colorTeal => 'Teal';

  @override
  String get colorIndigo => 'Indigo';

  @override
  String get colorBrown => 'Brown';

  @override
  String get dialogSwitchDevice => 'Switch Device';

  @override
  String get deviceCurrentTag => 'Current';

  @override
  String get btnAddCustom => 'Add Custom Command';

  @override
  String get dialogAddTitle => 'Add Shortcut';

  @override
  String get dialogName => 'Name';

  @override
  String get dialogCommand => 'Shell Command';

  @override
  String get btnCancel => 'Cancel';

  @override
  String get btnAdd => 'Add';

  @override
  String get tipPowerMenu => 'Power Menu';

  @override
  String get tipRestartSystem => 'Reboot System';

  @override
  String get tipRestartRecovery => 'Reboot to Recovery';

  @override
  String get tipRestartBootloader => 'Reboot to Bootloader';

  @override
  String get tipShutdown => 'Shutdown';

  @override
  String get tipKillServer => 'Stop Server & Exit';

  @override
  String get tipRefresh => 'Refresh Connection';

  @override
  String get wirelessHistory => 'History';

  @override
  String get wirelessEnterIp => 'Enter IP:Port';

  @override
  String get wirelessConnect => 'Connect';

  @override
  String get wirelessDisconnect => 'Disconnect';

  @override
  String get wirelessRemoveHistory => 'Remove';

  @override
  String get wirelessIp => 'IP Address';

  @override
  String get wirelessPort => 'Port';

  @override
  String get wirelessWarning =>
      'This device is connected via wireless, which may cause slow performance or some features to be unavailable';
}

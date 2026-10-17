import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_ja.dart';
import 'app_localizations_zh.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
      : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations? of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations);
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
    delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
  ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('ja'),
    Locale('zh'),
    Locale('zh', 'TW')
  ];

  /// No description provided for @appTitle.
  ///
  /// In zh, this message translates to:
  /// **'Shirabox'**
  String get appTitle;

  /// No description provided for @navConnect.
  ///
  /// In zh, this message translates to:
  /// **'连线'**
  String get navConnect;

  /// No description provided for @navWireless.
  ///
  /// In zh, this message translates to:
  /// **'无线连接'**
  String get navWireless;

  /// No description provided for @navApps.
  ///
  /// In zh, this message translates to:
  /// **'应用'**
  String get navApps;

  /// No description provided for @navFiles.
  ///
  /// In zh, this message translates to:
  /// **'文件'**
  String get navFiles;

  /// No description provided for @navLogs.
  ///
  /// In zh, this message translates to:
  /// **'Logcat'**
  String get navLogs;

  /// No description provided for @navTools.
  ///
  /// In zh, this message translates to:
  /// **'工具'**
  String get navTools;

  /// No description provided for @navMirror.
  ///
  /// In zh, this message translates to:
  /// **'投屏'**
  String get navMirror;

  /// No description provided for @navSettings.
  ///
  /// In zh, this message translates to:
  /// **'设置'**
  String get navSettings;

  /// No description provided for @homeWaitDevice.
  ///
  /// In zh, this message translates to:
  /// **'等待设备接入...'**
  String get homeWaitDevice;

  /// No description provided for @homeWaitHint.
  ///
  /// In zh, this message translates to:
  /// **'请确保开启 USB 调试并授予电脑权限'**
  String get homeWaitHint;

  /// No description provided for @homeManualCheck.
  ///
  /// In zh, this message translates to:
  /// **'手动检测'**
  String get homeManualCheck;

  /// No description provided for @homeNoAdbTitle.
  ///
  /// In zh, this message translates to:
  /// **'未检测到 ADB 环境'**
  String get homeNoAdbTitle;

  /// No description provided for @homeNoAdbContent.
  ///
  /// In zh, this message translates to:
  /// **'系统环境变量中未找到 adb.exe，\n请安装 ADB 驱动或在设置中手动指定路径。'**
  String get homeNoAdbContent;

  /// No description provided for @homeGoSettings.
  ///
  /// In zh, this message translates to:
  /// **'去配置路径'**
  String get homeGoSettings;

  /// No description provided for @homeRetryCheck.
  ///
  /// In zh, this message translates to:
  /// **'已安装？点击重试'**
  String get homeRetryCheck;

  /// No description provided for @homeTabCpu.
  ///
  /// In zh, this message translates to:
  /// **'CPU'**
  String get homeTabCpu;

  /// No description provided for @homeTabRam.
  ///
  /// In zh, this message translates to:
  /// **'内存'**
  String get homeTabRam;

  /// No description provided for @homeTabStorage.
  ///
  /// In zh, this message translates to:
  /// **'存储'**
  String get homeTabStorage;

  /// No description provided for @homeItemKernel.
  ///
  /// In zh, this message translates to:
  /// **'内核'**
  String get homeItemKernel;

  /// No description provided for @homeQuickBoot.
  ///
  /// In zh, this message translates to:
  /// **'快捷启动'**
  String get homeQuickBoot;

  /// No description provided for @appsSystemApps.
  ///
  /// In zh, this message translates to:
  /// **'显示系统应用'**
  String get appsSystemApps;

  /// No description provided for @appsSearchHint.
  ///
  /// In zh, this message translates to:
  /// **'搜索应用...'**
  String get appsSearchHint;

  /// No description provided for @appsMultiSelect.
  ///
  /// In zh, this message translates to:
  /// **'多选模式'**
  String get appsMultiSelect;

  /// No description provided for @appsRefresh.
  ///
  /// In zh, this message translates to:
  /// **'刷新列表'**
  String get appsRefresh;

  /// No description provided for @appsEmpty.
  ///
  /// In zh, this message translates to:
  /// **'暂无数据'**
  String get appsEmpty;

  /// No description provided for @appsDropHint.
  ///
  /// In zh, this message translates to:
  /// **'拖入 APK / XAPK / APKS\n自动识别安装'**
  String get appsDropHint;

  /// No description provided for @appsSelected.
  ///
  /// In zh, this message translates to:
  /// **'已选: {count}'**
  String appsSelected(int count);

  /// No description provided for @appsSelectAll.
  ///
  /// In zh, this message translates to:
  /// **'全选'**
  String get appsSelectAll;

  /// No description provided for @appsDeselect.
  ///
  /// In zh, this message translates to:
  /// **'取消'**
  String get appsDeselect;

  /// No description provided for @appsBatchExtract.
  ///
  /// In zh, this message translates to:
  /// **'批量提取'**
  String get appsBatchExtract;

  /// No description provided for @appsExtractSuccess.
  ///
  /// In zh, this message translates to:
  /// **'提取成功'**
  String get appsExtractSuccess;

  /// No description provided for @appsExtractFail.
  ///
  /// In zh, this message translates to:
  /// **'提取失败: {error}'**
  String appsExtractFail(String error);

  /// No description provided for @appsBatchExtractFinish.
  ///
  /// In zh, this message translates to:
  /// **'批量提取任务结束，请查看日志'**
  String get appsBatchExtractFinish;

  /// No description provided for @actionExtractApk.
  ///
  /// In zh, this message translates to:
  /// **'提取 APK'**
  String get actionExtractApk;

  /// No description provided for @actionExtractAll.
  ///
  /// In zh, this message translates to:
  /// **'提取完整包 (APKS)'**
  String get actionExtractAll;

  /// No description provided for @actionFreeze.
  ///
  /// In zh, this message translates to:
  /// **'冻结应用'**
  String get actionFreeze;

  /// No description provided for @actionUnfreeze.
  ///
  /// In zh, this message translates to:
  /// **'解冻应用'**
  String get actionUnfreeze;

  /// No description provided for @actionUninstall.
  ///
  /// In zh, this message translates to:
  /// **'卸载'**
  String get actionUninstall;

  /// No description provided for @actionOpen.
  ///
  /// In zh, this message translates to:
  /// **'打开应用'**
  String get actionOpen;

  /// No description provided for @appsLaunchWithMirror.
  ///
  /// In zh, this message translates to:
  /// **'启动时开启投屏'**
  String get appsLaunchWithMirror;

  /// No description provided for @installDialogTitleInstalling.
  ///
  /// In zh, this message translates to:
  /// **'正在安装...'**
  String get installDialogTitleInstalling;

  /// No description provided for @installDialogTitleDone.
  ///
  /// In zh, this message translates to:
  /// **'批量安装完成'**
  String get installDialogTitleDone;

  /// No description provided for @installDialogClose.
  ///
  /// In zh, this message translates to:
  /// **'关闭'**
  String get installDialogClose;

  /// No description provided for @installStopAfterCurrent.
  ///
  /// In zh, this message translates to:
  /// **'停止'**
  String get installStopAfterCurrent;

  /// No description provided for @installCompletedCount.
  ///
  /// In zh, this message translates to:
  /// **'已完成 {completed}/{total}'**
  String installCompletedCount(int completed, int total);

  /// No description provided for @installVerifyRefresh.
  ///
  /// In zh, this message translates to:
  /// **'正在刷新应用列表...'**
  String get installVerifyRefresh;

  /// No description provided for @installSuccessToast.
  ///
  /// In zh, this message translates to:
  /// **'安装已完成，正在刷新列表...'**
  String get installSuccessToast;

  /// No description provided for @appsChoosePackages.
  ///
  /// In zh, this message translates to:
  /// **'选择安装包'**
  String get appsChoosePackages;

  /// No description provided for @filesPathHint.
  ///
  /// In zh, this message translates to:
  /// **'输入路径...'**
  String get filesPathHint;

  /// No description provided for @filesUploadDrop.
  ///
  /// In zh, this message translates to:
  /// **'拖拽文件或文件夹到这里\n上传到当前目录'**
  String get filesUploadDrop;

  /// No description provided for @filesChooseFiles.
  ///
  /// In zh, this message translates to:
  /// **'选择文件'**
  String get filesChooseFiles;

  /// No description provided for @filesChooseFolder.
  ///
  /// In zh, this message translates to:
  /// **'选择文件夹'**
  String get filesChooseFolder;

  /// No description provided for @filesLoadedCount.
  ///
  /// In zh, this message translates to:
  /// **'已加载 {count} 个项目'**
  String filesLoadedCount(int count);

  /// No description provided for @filesListingFailed.
  ///
  /// In zh, this message translates to:
  /// **'无法读取此文件夹：{error}'**
  String filesListingFailed(String error);

  /// No description provided for @filesTransferStop.
  ///
  /// In zh, this message translates to:
  /// **'停止'**
  String get filesTransferStop;

  /// No description provided for @filesTransferUploading.
  ///
  /// In zh, this message translates to:
  /// **'正在上传'**
  String get filesTransferUploading;

  /// No description provided for @filesTransferDownloading.
  ///
  /// In zh, this message translates to:
  /// **'正在下载'**
  String get filesTransferDownloading;

  /// No description provided for @filesTransferDeleting.
  ///
  /// In zh, this message translates to:
  /// **'正在删除'**
  String get filesTransferDeleting;

  /// No description provided for @filesTransferFailed.
  ///
  /// In zh, this message translates to:
  /// **'{count} 个失败'**
  String filesTransferFailed(int count);

  /// No description provided for @filesUploadComplete.
  ///
  /// In zh, this message translates to:
  /// **'上传完成 ({success}/{total})'**
  String filesUploadComplete(int success, int total);

  /// No description provided for @filesSelectMode.
  ///
  /// In zh, this message translates to:
  /// **'多选模式'**
  String get filesSelectMode;

  /// No description provided for @filesSelected.
  ///
  /// In zh, this message translates to:
  /// **'已选: {count}'**
  String filesSelected(int count);

  /// No description provided for @filesSelectAll.
  ///
  /// In zh, this message translates to:
  /// **'全选'**
  String get filesSelectAll;

  /// No description provided for @filesDeselect.
  ///
  /// In zh, this message translates to:
  /// **'取消'**
  String get filesDeselect;

  /// No description provided for @filesDownloadSelected.
  ///
  /// In zh, this message translates to:
  /// **'下载选中项'**
  String get filesDownloadSelected;

  /// No description provided for @filesExportSelected.
  ///
  /// In zh, this message translates to:
  /// **'导出选中项 ({count})'**
  String filesExportSelected(int count);

  /// No description provided for @filesDeleteSelected.
  ///
  /// In zh, this message translates to:
  /// **'删除选中项'**
  String get filesDeleteSelected;

  /// No description provided for @filesDeleteConfirmBatch.
  ///
  /// In zh, this message translates to:
  /// **'确定删除选中的 {count} 个文件吗？'**
  String filesDeleteConfirmBatch(int count);

  /// No description provided for @filesMenuDownload.
  ///
  /// In zh, this message translates to:
  /// **'下载'**
  String get filesMenuDownload;

  /// No description provided for @filesMenuDelete.
  ///
  /// In zh, this message translates to:
  /// **'删除'**
  String get filesMenuDelete;

  /// No description provided for @filesDeleteDialogTitle.
  ///
  /// In zh, this message translates to:
  /// **'确认删除'**
  String get filesDeleteDialogTitle;

  /// No description provided for @filesDeleteDialogContent.
  ///
  /// In zh, this message translates to:
  /// **'确定要永久删除:'**
  String get filesDeleteDialogContent;

  /// No description provided for @filesDeleteDialogPath.
  ///
  /// In zh, this message translates to:
  /// **'路径: {path}'**
  String filesDeleteDialogPath(String path);

  /// No description provided for @filesSnackDownloadDone.
  ///
  /// In zh, this message translates to:
  /// **'下载完成'**
  String get filesSnackDownloadDone;

  /// No description provided for @filesSnackDeleteFail.
  ///
  /// In zh, this message translates to:
  /// **'删除失败: {error}'**
  String filesSnackDeleteFail(String error);

  /// No description provided for @logcatHint.
  ///
  /// In zh, this message translates to:
  /// **'筛选日志...'**
  String get logcatHint;

  /// No description provided for @logcatFilterHelp.
  ///
  /// In zh, this message translates to:
  /// **'多个条件使用 AND。可输入 tag:ActivityManager、msg:\"not responding\"、pid:1234、level:E,F 或 -noise。'**
  String get logcatFilterHelp;

  /// No description provided for @logcatRegex.
  ///
  /// In zh, this message translates to:
  /// **'正则表达式'**
  String get logcatRegex;

  /// No description provided for @logcatCaseSensitive.
  ///
  /// In zh, this message translates to:
  /// **'区分大小写'**
  String get logcatCaseSensitive;

  /// No description provided for @logcatResumeLive.
  ///
  /// In zh, this message translates to:
  /// **'回到实时末尾'**
  String get logcatResumeLive;

  /// No description provided for @logcatStats.
  ///
  /// In zh, this message translates to:
  /// **'显示 {visible} / 保留 {retained} / 待处理 {pending}'**
  String logcatStats(int visible, int retained, int pending);

  /// No description provided for @logcatDropped.
  ///
  /// In zh, this message translates to:
  /// **'已丢弃 {count} 行输入'**
  String logcatDropped(int count);

  /// No description provided for @logcatFilterInvalid.
  ///
  /// In zh, this message translates to:
  /// **'筛选条件无效：{error}'**
  String logcatFilterInvalid(String error);

  /// No description provided for @logcatNoMatches.
  ///
  /// In zh, this message translates to:
  /// **'没有符合条件的日志'**
  String get logcatNoMatches;

  /// No description provided for @logcatPid.
  ///
  /// In zh, this message translates to:
  /// **'PID'**
  String get logcatPid;

  /// No description provided for @logcatTid.
  ///
  /// In zh, this message translates to:
  /// **'TID'**
  String get logcatTid;

  /// No description provided for @logcatBtnStop.
  ///
  /// In zh, this message translates to:
  /// **'停止'**
  String get logcatBtnStop;

  /// No description provided for @logcatBtnStart.
  ///
  /// In zh, this message translates to:
  /// **'开始'**
  String get logcatBtnStart;

  /// No description provided for @logcatClear.
  ///
  /// In zh, this message translates to:
  /// **'清空日志'**
  String get logcatClear;

  /// No description provided for @logcatExport.
  ///
  /// In zh, this message translates to:
  /// **'导出 JSON'**
  String get logcatExport;

  /// No description provided for @logcatExportTitle.
  ///
  /// In zh, this message translates to:
  /// **'导出 Logcat JSON'**
  String get logcatExportTitle;

  /// No description provided for @logcatExportSaved.
  ///
  /// In zh, this message translates to:
  /// **'已保存：{path}'**
  String logcatExportSaved(String path);

  /// No description provided for @logcatBottom.
  ///
  /// In zh, this message translates to:
  /// **'跟随实时末尾'**
  String get logcatBottom;

  /// No description provided for @logcatDetailTitle.
  ///
  /// In zh, this message translates to:
  /// **'日志详情'**
  String get logcatDetailTitle;

  /// No description provided for @logcatDetailTime.
  ///
  /// In zh, this message translates to:
  /// **'时间'**
  String get logcatDetailTime;

  /// No description provided for @logcatDetailLevel.
  ///
  /// In zh, this message translates to:
  /// **'级别'**
  String get logcatDetailLevel;

  /// No description provided for @logcatDetailTag.
  ///
  /// In zh, this message translates to:
  /// **'标签'**
  String get logcatDetailTag;

  /// No description provided for @logcatDetailContent.
  ///
  /// In zh, this message translates to:
  /// **'正文内容'**
  String get logcatDetailContent;

  /// No description provided for @logcatCopyAll.
  ///
  /// In zh, this message translates to:
  /// **'复制全部'**
  String get logcatCopyAll;

  /// No description provided for @logcatCopyContent.
  ///
  /// In zh, this message translates to:
  /// **'复制正文'**
  String get logcatCopyContent;

  /// No description provided for @toolsShell.
  ///
  /// In zh, this message translates to:
  /// **'Shell 终端'**
  String get toolsShell;

  /// No description provided for @toolsProcess.
  ///
  /// In zh, this message translates to:
  /// **'进程管理'**
  String get toolsProcess;

  /// No description provided for @toolsProp.
  ///
  /// In zh, this message translates to:
  /// **'属性编辑 (Prop)'**
  String get toolsProp;

  /// No description provided for @toolsPropSearch.
  ///
  /// In zh, this message translates to:
  /// **'搜索属性...'**
  String get toolsPropSearch;

  /// No description provided for @toolsPropWarning.
  ///
  /// In zh, this message translates to:
  /// **'注意：通过 ADB 修改的属性通常在设备重启后会被重置。'**
  String get toolsPropWarning;

  /// No description provided for @toolsPropEditTitle.
  ///
  /// In zh, this message translates to:
  /// **'修改属性'**
  String get toolsPropEditTitle;

  /// No description provided for @toolsInspector.
  ///
  /// In zh, this message translates to:
  /// **'UI 检视器'**
  String get toolsInspector;

  /// No description provided for @toolsInspDump.
  ///
  /// In zh, this message translates to:
  /// **'抓取布局'**
  String get toolsInspDump;

  /// No description provided for @toolsInspNodeInfo.
  ///
  /// In zh, this message translates to:
  /// **'节点属性'**
  String get toolsInspNodeInfo;

  /// No description provided for @processShowSystem.
  ///
  /// In zh, this message translates to:
  /// **'显示系统进程'**
  String get processShowSystem;

  /// No description provided for @processAutoRefresh.
  ///
  /// In zh, this message translates to:
  /// **'自动刷新'**
  String get processAutoRefresh;

  /// No description provided for @processSearchHint.
  ///
  /// In zh, this message translates to:
  /// **'搜索进程名或PID...'**
  String get processSearchHint;

  /// No description provided for @processBtnRefresh.
  ///
  /// In zh, this message translates to:
  /// **'刷新'**
  String get processBtnRefresh;

  /// No description provided for @processBtnKill.
  ///
  /// In zh, this message translates to:
  /// **'结束进程'**
  String get processBtnKill;

  /// No description provided for @processKillSuccess.
  ///
  /// In zh, this message translates to:
  /// **'已结束: {name}'**
  String processKillSuccess(String name);

  /// No description provided for @processKillFail.
  ///
  /// In zh, this message translates to:
  /// **'结束失败: {error}'**
  String processKillFail(String error);

  /// No description provided for @shellBtnRun.
  ///
  /// In zh, this message translates to:
  /// **'执行'**
  String get shellBtnRun;

  /// No description provided for @scrcpyTitle.
  ///
  /// In zh, this message translates to:
  /// **'Scrcpy 投屏'**
  String get scrcpyTitle;

  /// No description provided for @scrcpyIntro.
  ///
  /// In zh, this message translates to:
  /// **'高性能 Android 屏幕镜像工具\n开源项目: Genymobile/scrcpy'**
  String get scrcpyIntro;

  /// No description provided for @scrcpyBtnStart.
  ///
  /// In zh, this message translates to:
  /// **'启动'**
  String get scrcpyBtnStart;

  /// No description provided for @scrcpyParamPreview.
  ///
  /// In zh, this message translates to:
  /// **'启动参数预览 (可手动修改)'**
  String get scrcpyParamPreview;

  /// No description provided for @scrcpyGroupVideo.
  ///
  /// In zh, this message translates to:
  /// **'画面设置'**
  String get scrcpyGroupVideo;

  /// No description provided for @scrcpyGroupControl.
  ///
  /// In zh, this message translates to:
  /// **'控制与操作'**
  String get scrcpyGroupControl;

  /// No description provided for @scrcpyMaxSize.
  ///
  /// In zh, this message translates to:
  /// **'分辨率限制 (Max Size)'**
  String get scrcpyMaxSize;

  /// No description provided for @scrcpyBitrate.
  ///
  /// In zh, this message translates to:
  /// **'比特率 (Bitrate)'**
  String get scrcpyBitrate;

  /// No description provided for @scrcpyFps.
  ///
  /// In zh, this message translates to:
  /// **'帧率 (FPS)'**
  String get scrcpyFps;

  /// No description provided for @scrcpyStayAwake.
  ///
  /// In zh, this message translates to:
  /// **'保持唤醒 (Stay Awake)'**
  String get scrcpyStayAwake;

  /// No description provided for @scrcpyTurnOffScreen.
  ///
  /// In zh, this message translates to:
  /// **'关闭手机屏幕'**
  String get scrcpyTurnOffScreen;

  /// No description provided for @scrcpyShowTouches.
  ///
  /// In zh, this message translates to:
  /// **'显示触摸点'**
  String get scrcpyShowTouches;

  /// No description provided for @scrcpyAlwaysOnTop.
  ///
  /// In zh, this message translates to:
  /// **'窗口置顶'**
  String get scrcpyAlwaysOnTop;

  /// No description provided for @scrcpyNoAudio.
  ///
  /// In zh, this message translates to:
  /// **'禁用音频转发'**
  String get scrcpyNoAudio;

  /// No description provided for @scrcpyKeyNav.
  ///
  /// In zh, this message translates to:
  /// **'HID 键盘模拟'**
  String get scrcpyKeyNav;

  /// No description provided for @qcVolUp.
  ///
  /// In zh, this message translates to:
  /// **'音量+'**
  String get qcVolUp;

  /// No description provided for @qcVolDown.
  ///
  /// In zh, this message translates to:
  /// **'音量-'**
  String get qcVolDown;

  /// No description provided for @qcBack.
  ///
  /// In zh, this message translates to:
  /// **'返回'**
  String get qcBack;

  /// No description provided for @qcHome.
  ///
  /// In zh, this message translates to:
  /// **'桌面'**
  String get qcHome;

  /// No description provided for @qcRecent.
  ///
  /// In zh, this message translates to:
  /// **'任务'**
  String get qcRecent;

  /// No description provided for @qcShot.
  ///
  /// In zh, this message translates to:
  /// **'截图'**
  String get qcShot;

  /// No description provided for @qcPaste.
  ///
  /// In zh, this message translates to:
  /// **'粘贴'**
  String get qcPaste;

  /// No description provided for @qcPower.
  ///
  /// In zh, this message translates to:
  /// **'电源'**
  String get qcPower;

  /// No description provided for @qcMenu.
  ///
  /// In zh, this message translates to:
  /// **'菜单'**
  String get qcMenu;

  /// No description provided for @qcEnter.
  ///
  /// In zh, this message translates to:
  /// **'回车'**
  String get qcEnter;

  /// No description provided for @qcSpace.
  ///
  /// In zh, this message translates to:
  /// **'空格'**
  String get qcSpace;

  /// No description provided for @settingsTitle.
  ///
  /// In zh, this message translates to:
  /// **'设置'**
  String get settingsTitle;

  /// No description provided for @settingsLanguage.
  ///
  /// In zh, this message translates to:
  /// **'语言 / Language'**
  String get settingsLanguage;

  /// No description provided for @settingsTheme.
  ///
  /// In zh, this message translates to:
  /// **'外观 / Appearance'**
  String get settingsTheme;

  /// No description provided for @settingsAdbPath.
  ///
  /// In zh, this message translates to:
  /// **'ADB 环境'**
  String get settingsAdbPath;

  /// No description provided for @settingsAdbManual.
  ///
  /// In zh, this message translates to:
  /// **'手动指定 ADB 路径'**
  String get settingsAdbManual;

  /// No description provided for @settingsAdbFallback.
  ///
  /// In zh, this message translates to:
  /// **'回路完成：应用程序默认'**
  String get settingsAdbFallback;

  /// No description provided for @settingsAdbReset.
  ///
  /// In zh, this message translates to:
  /// **'重置为默认'**
  String get settingsAdbReset;

  /// No description provided for @settingsQuickBoot.
  ///
  /// In zh, this message translates to:
  /// **'功能增强'**
  String get settingsQuickBoot;

  /// No description provided for @settingsShowQuick.
  ///
  /// In zh, this message translates to:
  /// **'主页显示快捷启动按钮'**
  String get settingsShowQuick;

  /// No description provided for @colorPurple.
  ///
  /// In zh, this message translates to:
  /// **'梦境紫'**
  String get colorPurple;

  /// No description provided for @colorBlue.
  ///
  /// In zh, this message translates to:
  /// **'深海蓝'**
  String get colorBlue;

  /// No description provided for @colorGreen.
  ///
  /// In zh, this message translates to:
  /// **'森林绿'**
  String get colorGreen;

  /// No description provided for @colorRed.
  ///
  /// In zh, this message translates to:
  /// **'玫瑰红'**
  String get colorRed;

  /// No description provided for @colorOrange.
  ///
  /// In zh, this message translates to:
  /// **'落日橙'**
  String get colorOrange;

  /// No description provided for @colorPink.
  ///
  /// In zh, this message translates to:
  /// **'樱花粉'**
  String get colorPink;

  /// No description provided for @colorGrey.
  ///
  /// In zh, this message translates to:
  /// **'极简灰'**
  String get colorGrey;

  /// No description provided for @colorTeal.
  ///
  /// In zh, this message translates to:
  /// **'青色'**
  String get colorTeal;

  /// No description provided for @colorIndigo.
  ///
  /// In zh, this message translates to:
  /// **'靛蓝'**
  String get colorIndigo;

  /// No description provided for @colorBrown.
  ///
  /// In zh, this message translates to:
  /// **'棕色'**
  String get colorBrown;

  /// No description provided for @dialogSwitchDevice.
  ///
  /// In zh, this message translates to:
  /// **'切换当前设备'**
  String get dialogSwitchDevice;

  /// No description provided for @deviceCurrentTag.
  ///
  /// In zh, this message translates to:
  /// **'当前'**
  String get deviceCurrentTag;

  /// No description provided for @btnAddCustom.
  ///
  /// In zh, this message translates to:
  /// **'添加自定义指令'**
  String get btnAddCustom;

  /// No description provided for @dialogAddTitle.
  ///
  /// In zh, this message translates to:
  /// **'添加快捷指令'**
  String get dialogAddTitle;

  /// No description provided for @dialogName.
  ///
  /// In zh, this message translates to:
  /// **'名称'**
  String get dialogName;

  /// No description provided for @dialogCommand.
  ///
  /// In zh, this message translates to:
  /// **'Shell 命令'**
  String get dialogCommand;

  /// No description provided for @btnCancel.
  ///
  /// In zh, this message translates to:
  /// **'取消'**
  String get btnCancel;

  /// No description provided for @btnAdd.
  ///
  /// In zh, this message translates to:
  /// **'添加'**
  String get btnAdd;

  /// No description provided for @tipPowerMenu.
  ///
  /// In zh, this message translates to:
  /// **'电源菜单'**
  String get tipPowerMenu;

  /// No description provided for @tipRestartSystem.
  ///
  /// In zh, this message translates to:
  /// **'重启系统'**
  String get tipRestartSystem;

  /// No description provided for @tipRestartRecovery.
  ///
  /// In zh, this message translates to:
  /// **'重启到 Recovery'**
  String get tipRestartRecovery;

  /// No description provided for @tipRestartBootloader.
  ///
  /// In zh, this message translates to:
  /// **'重启到 Bootloader'**
  String get tipRestartBootloader;

  /// No description provided for @tipShutdown.
  ///
  /// In zh, this message translates to:
  /// **'关机'**
  String get tipShutdown;

  /// No description provided for @tipKillServer.
  ///
  /// In zh, this message translates to:
  /// **'停止服务并退出'**
  String get tipKillServer;

  /// No description provided for @tipRefresh.
  ///
  /// In zh, this message translates to:
  /// **'刷新连接'**
  String get tipRefresh;

  /// No description provided for @wirelessHistory.
  ///
  /// In zh, this message translates to:
  /// **'历史记录'**
  String get wirelessHistory;

  /// No description provided for @wirelessEnterIp.
  ///
  /// In zh, this message translates to:
  /// **'输入 IP:Port'**
  String get wirelessEnterIp;

  /// No description provided for @wirelessConnect.
  ///
  /// In zh, this message translates to:
  /// **'连接'**
  String get wirelessConnect;

  /// No description provided for @wirelessDisconnect.
  ///
  /// In zh, this message translates to:
  /// **'断开'**
  String get wirelessDisconnect;

  /// No description provided for @wirelessRemoveHistory.
  ///
  /// In zh, this message translates to:
  /// **'移除记录'**
  String get wirelessRemoveHistory;

  /// No description provided for @wirelessIp.
  ///
  /// In zh, this message translates to:
  /// **'IP 地址'**
  String get wirelessIp;

  /// No description provided for @wirelessPort.
  ///
  /// In zh, this message translates to:
  /// **'端口'**
  String get wirelessPort;

  /// No description provided for @wirelessWarning.
  ///
  /// In zh, this message translates to:
  /// **'此装置正通过无线连接，可能造成操作延迟或部分功能受限'**
  String get wirelessWarning;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'ja', 'zh'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when language+country codes are specified.
  switch (locale.languageCode) {
    case 'zh':
      {
        switch (locale.countryCode) {
          case 'TW':
            return AppLocalizationsZhTw();
        }
        break;
      }
  }

  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'ja':
      return AppLocalizationsJa();
    case 'zh':
      return AppLocalizationsZh();
  }

  throw FlutterError(
      'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
      'an issue with the localizations generation tool. Please file an issue '
      'on GitHub with a reproducible sample app and the gen-l10n configuration '
      'that was used.');
}

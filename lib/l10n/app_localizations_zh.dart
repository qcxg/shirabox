// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class AppLocalizationsZh extends AppLocalizations {
  AppLocalizationsZh([String locale = 'zh']) : super(locale);

  @override
  String get appTitle => 'Shirabox';

  @override
  String get navConnect => '连线';

  @override
  String get navWireless => '无线连接';

  @override
  String get navApps => '应用';

  @override
  String get navFiles => '文件';

  @override
  String get navLogs => 'Logcat';

  @override
  String get navTools => '工具';

  @override
  String get navMirror => '投屏';

  @override
  String get navSettings => '设置';

  @override
  String get homeWaitDevice => '等待设备接入...';

  @override
  String get homeWaitHint => '请确保开启 USB 调试并授予电脑权限';

  @override
  String get homeManualCheck => '手动检测';

  @override
  String get homeNoAdbTitle => '未检测到 ADB 环境';

  @override
  String get homeNoAdbContent => '系统环境变量中未找到 adb.exe，\n请安装 ADB 驱动或在设置中手动指定路径。';

  @override
  String get homeGoSettings => '去配置路径';

  @override
  String get homeRetryCheck => '已安装？点击重试';

  @override
  String get homeTabCpu => 'CPU';

  @override
  String get homeTabRam => '内存';

  @override
  String get homeTabStorage => '存储';

  @override
  String get homeItemKernel => '内核';

  @override
  String get homeQuickBoot => '快捷启动';

  @override
  String get appsSystemApps => '显示系统应用';

  @override
  String get appsSearchHint => '搜索应用...';

  @override
  String get appsMultiSelect => '多选模式';

  @override
  String get appsRefresh => '刷新列表';

  @override
  String get appsEmpty => '暂无数据';

  @override
  String get appsDropHint => '拖入 APK / XAPK / APKS\n自动识别安装';

  @override
  String appsSelected(int count) {
    return '已选: $count';
  }

  @override
  String get appsSelectAll => '全选';

  @override
  String get appsDeselect => '取消';

  @override
  String get appsBatchExtract => '批量提取';

  @override
  String get appsExtractSuccess => '提取成功';

  @override
  String appsExtractFail(String error) {
    return '提取失败: $error';
  }

  @override
  String get appsBatchExtractFinish => '批量提取任务结束，请查看日志';

  @override
  String get actionExtractApk => '提取 APK';

  @override
  String get actionExtractAll => '提取完整包 (APKS)';

  @override
  String get actionFreeze => '冻结应用';

  @override
  String get actionUnfreeze => '解冻应用';

  @override
  String get actionUninstall => '卸载';

  @override
  String get actionOpen => '打开应用';

  @override
  String get appsLaunchWithMirror => '启动时开启投屏';

  @override
  String get installDialogTitleInstalling => '正在安装...';

  @override
  String get installDialogTitleDone => '批量安装完成';

  @override
  String get installDialogClose => '关闭';

  @override
  String get installStopAfterCurrent => '停止';

  @override
  String installCompletedCount(int completed, int total) {
    return '已完成 $completed/$total';
  }

  @override
  String get installVerifyRefresh => '正在刷新应用列表...';

  @override
  String get installSuccessToast => '安装已完成，正在刷新列表...';

  @override
  String get appsChoosePackages => '选择安装包';

  @override
  String get filesPathHint => '输入路径...';

  @override
  String get filesUploadDrop => '拖拽文件或文件夹到这里\n上传到当前目录';

  @override
  String get filesChooseFiles => '选择文件';

  @override
  String get filesChooseFolder => '选择文件夹';

  @override
  String filesLoadedCount(int count) {
    return '已加载 $count 个项目';
  }

  @override
  String filesListingFailed(String error) {
    return '无法读取此文件夹：$error';
  }

  @override
  String get filesTransferStop => '停止';

  @override
  String get filesTransferUploading => '正在上传';

  @override
  String get filesTransferDownloading => '正在下载';

  @override
  String get filesTransferDeleting => '正在删除';

  @override
  String filesTransferFailed(int count) {
    return '$count 个失败';
  }

  @override
  String filesUploadComplete(int success, int total) {
    return '上传完成 ($success/$total)';
  }

  @override
  String get filesSelectMode => '多选模式';

  @override
  String filesSelected(int count) {
    return '已选: $count';
  }

  @override
  String get filesSelectAll => '全选';

  @override
  String get filesDeselect => '取消';

  @override
  String get filesDownloadSelected => '下载选中项';

  @override
  String filesExportSelected(int count) {
    return '导出选中项 ($count)';
  }

  @override
  String get filesDeleteSelected => '删除选中项';

  @override
  String filesDeleteConfirmBatch(int count) {
    return '确定删除选中的 $count 个文件吗？';
  }

  @override
  String get filesMenuDownload => '下载';

  @override
  String get filesMenuDelete => '删除';

  @override
  String get filesDeleteDialogTitle => '确认删除';

  @override
  String get filesDeleteDialogContent => '确定要永久删除:';

  @override
  String filesDeleteDialogPath(String path) {
    return '路径: $path';
  }

  @override
  String get filesSnackDownloadDone => '下载完成';

  @override
  String filesSnackDeleteFail(String error) {
    return '删除失败: $error';
  }

  @override
  String get logcatHint => '筛选日志...';

  @override
  String get logcatFilterHelp =>
      '多个条件使用 AND。可输入 tag:ActivityManager、msg:\"not responding\"、pid:1234、level:E,F 或 -noise。';

  @override
  String get logcatRegex => '正则表达式';

  @override
  String get logcatCaseSensitive => '区分大小写';

  @override
  String get logcatResumeLive => '回到实时末尾';

  @override
  String logcatStats(int visible, int retained, int pending) {
    return '显示 $visible / 保留 $retained / 待处理 $pending';
  }

  @override
  String logcatDropped(int count) {
    return '已丢弃 $count 行输入';
  }

  @override
  String logcatFilterInvalid(String error) {
    return '筛选条件无效：$error';
  }

  @override
  String get logcatNoMatches => '没有符合条件的日志';

  @override
  String get logcatPid => 'PID';

  @override
  String get logcatTid => 'TID';

  @override
  String get logcatBtnStop => '停止';

  @override
  String get logcatBtnStart => '开始';

  @override
  String get logcatClear => '清空日志';

  @override
  String get logcatExport => '导出 JSON';

  @override
  String get logcatExportTitle => '导出 Logcat JSON';

  @override
  String logcatExportSaved(String path) {
    return '已保存：$path';
  }

  @override
  String get logcatBottom => '跟随实时末尾';

  @override
  String get logcatDetailTitle => '日志详情';

  @override
  String get logcatDetailTime => '时间';

  @override
  String get logcatDetailLevel => '级别';

  @override
  String get logcatDetailTag => '标签';

  @override
  String get logcatDetailContent => '正文内容';

  @override
  String get logcatCopyAll => '复制全部';

  @override
  String get logcatCopyContent => '复制正文';

  @override
  String get toolsShell => 'Shell 终端';

  @override
  String get toolsProcess => '进程管理';

  @override
  String get toolsProp => '属性编辑 (Prop)';

  @override
  String get toolsPropSearch => '搜索属性...';

  @override
  String get toolsPropWarning => '注意：通过 ADB 修改的属性通常在设备重启后会被重置。';

  @override
  String get toolsPropEditTitle => '修改属性';

  @override
  String get toolsInspector => 'UI 检视器';

  @override
  String get toolsInspDump => '抓取布局';

  @override
  String get toolsInspNodeInfo => '节点属性';

  @override
  String get processShowSystem => '显示系统进程';

  @override
  String get processAutoRefresh => '自动刷新';

  @override
  String get processSearchHint => '搜索进程名或PID...';

  @override
  String get processBtnRefresh => '刷新';

  @override
  String get processBtnKill => '结束进程';

  @override
  String processKillSuccess(String name) {
    return '已结束: $name';
  }

  @override
  String processKillFail(String error) {
    return '结束失败: $error';
  }

  @override
  String get shellBtnRun => '执行';

  @override
  String get scrcpyTitle => 'Scrcpy 投屏';

  @override
  String get scrcpyIntro => '高性能 Android 屏幕镜像工具\n开源项目: Genymobile/scrcpy';

  @override
  String get scrcpyBtnStart => '启动';

  @override
  String get scrcpyParamPreview => '启动参数预览 (可手动修改)';

  @override
  String get scrcpyGroupVideo => '画面设置';

  @override
  String get scrcpyGroupControl => '控制与操作';

  @override
  String get scrcpyMaxSize => '分辨率限制 (Max Size)';

  @override
  String get scrcpyBitrate => '比特率 (Bitrate)';

  @override
  String get scrcpyFps => '帧率 (FPS)';

  @override
  String get scrcpyStayAwake => '保持唤醒 (Stay Awake)';

  @override
  String get scrcpyTurnOffScreen => '关闭手机屏幕';

  @override
  String get scrcpyShowTouches => '显示触摸点';

  @override
  String get scrcpyAlwaysOnTop => '窗口置顶';

  @override
  String get scrcpyNoAudio => '禁用音频转发';

  @override
  String get scrcpyKeyNav => 'HID 键盘模拟';

  @override
  String get qcVolUp => '音量+';

  @override
  String get qcVolDown => '音量-';

  @override
  String get qcBack => '返回';

  @override
  String get qcHome => '桌面';

  @override
  String get qcRecent => '任务';

  @override
  String get qcShot => '截图';

  @override
  String get qcPaste => '粘贴';

  @override
  String get qcPower => '电源';

  @override
  String get qcMenu => '菜单';

  @override
  String get qcEnter => '回车';

  @override
  String get qcSpace => '空格';

  @override
  String get settingsTitle => '设置';

  @override
  String get settingsLanguage => '语言 / Language';

  @override
  String get settingsTheme => '外观 / Appearance';

  @override
  String get settingsAdbPath => 'ADB 环境';

  @override
  String get settingsAdbManual => '手动指定 ADB 路径';

  @override
  String get settingsAdbFallback => '回路完成：应用程序默认';

  @override
  String get settingsAdbReset => '重置为默认';

  @override
  String get settingsQuickBoot => '功能增强';

  @override
  String get settingsShowQuick => '主页显示快捷启动按钮';

  @override
  String get colorPurple => '梦境紫';

  @override
  String get colorBlue => '深海蓝';

  @override
  String get colorGreen => '森林绿';

  @override
  String get colorRed => '玫瑰红';

  @override
  String get colorOrange => '落日橙';

  @override
  String get colorPink => '樱花粉';

  @override
  String get colorGrey => '极简灰';

  @override
  String get colorTeal => '青色';

  @override
  String get colorIndigo => '靛蓝';

  @override
  String get colorBrown => '棕色';

  @override
  String get dialogSwitchDevice => '切换当前设备';

  @override
  String get deviceCurrentTag => '当前';

  @override
  String get btnAddCustom => '添加自定义指令';

  @override
  String get dialogAddTitle => '添加快捷指令';

  @override
  String get dialogName => '名称';

  @override
  String get dialogCommand => 'Shell 命令';

  @override
  String get btnCancel => '取消';

  @override
  String get btnAdd => '添加';

  @override
  String get tipPowerMenu => '电源菜单';

  @override
  String get tipRestartSystem => '重启系统';

  @override
  String get tipRestartRecovery => '重启到 Recovery';

  @override
  String get tipRestartBootloader => '重启到 Bootloader';

  @override
  String get tipShutdown => '关机';

  @override
  String get tipKillServer => '停止服务并退出';

  @override
  String get tipRefresh => '刷新连接';

  @override
  String get wirelessHistory => '历史记录';

  @override
  String get wirelessEnterIp => '输入 IP:Port';

  @override
  String get wirelessConnect => '连接';

  @override
  String get wirelessDisconnect => '断开';

  @override
  String get wirelessRemoveHistory => '移除记录';

  @override
  String get wirelessIp => 'IP 地址';

  @override
  String get wirelessPort => '端口';

  @override
  String get wirelessWarning => '此装置正通过无线连接，可能造成操作延迟或部分功能受限';
}

/// The translations for Chinese, as used in Taiwan (`zh_TW`).
class AppLocalizationsZhTw extends AppLocalizationsZh {
  AppLocalizationsZhTw() : super('zh_TW');

  @override
  String get appTitle => 'Shirabox';

  @override
  String get navConnect => '連線';

  @override
  String get navWireless => '無線連結';

  @override
  String get navApps => '應用';

  @override
  String get navFiles => '檔案';

  @override
  String get navLogs => 'Logcat';

  @override
  String get navTools => '工具';

  @override
  String get navMirror => '投屏';

  @override
  String get navSettings => '設定';

  @override
  String get homeWaitDevice => '等待裝置接入...';

  @override
  String get homeWaitHint => '請確保開啟 USB 偵錯並授予電腦權限';

  @override
  String get homeManualCheck => '手動檢測';

  @override
  String get homeNoAdbTitle => '未檢測到 ADB 環境';

  @override
  String get homeNoAdbContent => '系統環境變數中未找到 adb.exe，\n請安裝 ADB 驅動或在設定中手動指定路徑。';

  @override
  String get homeGoSettings => '前往設定';

  @override
  String get homeRetryCheck => '重試';

  @override
  String get homeTabCpu => 'CPU';

  @override
  String get homeTabRam => '記憶體';

  @override
  String get homeTabStorage => '儲存';

  @override
  String get homeItemKernel => '核心';

  @override
  String get homeQuickBoot => '快速啟動';

  @override
  String get appsSystemApps => '顯示系統應用';

  @override
  String get appsSearchHint => '搜尋應用...';

  @override
  String get appsMultiSelect => '多選模式';

  @override
  String get appsRefresh => '重新整理';

  @override
  String get appsEmpty => '暫無資料';

  @override
  String get appsDropHint => '拖入 APK / XAPK / APKS\n自動識別安裝';

  @override
  String appsSelected(int count) {
    return '已選: $count';
  }

  @override
  String get appsSelectAll => '全選';

  @override
  String get appsDeselect => '取消';

  @override
  String get appsBatchExtract => '批次提取';

  @override
  String get appsExtractSuccess => '提取成功';

  @override
  String appsExtractFail(String error) {
    return '提取失敗: $error';
  }

  @override
  String get appsBatchExtractFinish => '批次任務結束，請查看日誌';

  @override
  String get actionExtractApk => '提取 APK';

  @override
  String get actionExtractAll => '提取完整包 (APKS)';

  @override
  String get actionFreeze => '凍結應用';

  @override
  String get actionUnfreeze => '解凍應用';

  @override
  String get actionUninstall => '解除安裝';

  @override
  String get actionOpen => '開啟應用';

  @override
  String get appsLaunchWithMirror => '啟動時開啟投屏';

  @override
  String get installDialogTitleInstalling => '正在安裝...';

  @override
  String get installDialogTitleDone => '批次安裝完成';

  @override
  String get installDialogClose => '關閉';

  @override
  String get installStopAfterCurrent => '停止';

  @override
  String installCompletedCount(int completed, int total) {
    return '已完成 $completed/$total';
  }

  @override
  String get installVerifyRefresh => '正在重新整理應用列表...';

  @override
  String get installSuccessToast => '安裝已完成，正在重新整理列表...';

  @override
  String get appsChoosePackages => '選擇安裝包';

  @override
  String get filesPathHint => '輸入路徑...';

  @override
  String get filesUploadDrop => '拖曳檔案或資料夾到這裡\n上傳到目前目錄';

  @override
  String get filesChooseFiles => '選擇檔案';

  @override
  String get filesChooseFolder => '選擇資料夾';

  @override
  String filesLoadedCount(int count) {
    return '已載入 $count 個項目';
  }

  @override
  String filesListingFailed(String error) {
    return '無法讀取此資料夾：$error';
  }

  @override
  String get filesTransferStop => '停止';

  @override
  String get filesTransferUploading => '正在上傳';

  @override
  String get filesTransferDownloading => '正在下載';

  @override
  String get filesTransferDeleting => '正在刪除';

  @override
  String filesTransferFailed(int count) {
    return '$count 個失敗';
  }

  @override
  String filesUploadComplete(int success, int total) {
    return '上傳完成 ($success/$total)';
  }

  @override
  String get filesSelectMode => '多選模式';

  @override
  String filesSelected(int count) {
    return '已選: $count';
  }

  @override
  String get filesSelectAll => '全選';

  @override
  String get filesDeselect => '取消';

  @override
  String get filesDownloadSelected => '下載選取項目';

  @override
  String filesExportSelected(int count) {
    return '匯出選取項目 ($count)';
  }

  @override
  String get filesDeleteSelected => '刪除選取項目';

  @override
  String filesDeleteConfirmBatch(int count) {
    return '確定刪除選取的 $count 個檔案嗎？';
  }

  @override
  String get filesMenuDownload => '下載';

  @override
  String get filesMenuDelete => '刪除';

  @override
  String get filesDeleteDialogTitle => '確認刪除';

  @override
  String get filesDeleteDialogContent => '確定要永久刪除:';

  @override
  String filesDeleteDialogPath(String path) {
    return '路徑: $path';
  }

  @override
  String get filesSnackDownloadDone => '下載完成';

  @override
  String filesSnackDeleteFail(String error) {
    return '刪除失敗: $error';
  }

  @override
  String get logcatHint => '篩選日誌...';

  @override
  String get logcatFilterHelp =>
      '多個條件使用 AND。可輸入 tag:ActivityManager、msg:\"not responding\"、pid:1234、level:E,F 或 -noise。';

  @override
  String get logcatRegex => '正規表示式';

  @override
  String get logcatCaseSensitive => '區分大小寫';

  @override
  String get logcatResumeLive => '回到即時尾端';

  @override
  String logcatStats(int visible, int retained, int pending) {
    return '顯示 $visible / 保留 $retained / 待處理 $pending';
  }

  @override
  String logcatDropped(int count) {
    return '已丟棄 $count 行輸入';
  }

  @override
  String logcatFilterInvalid(String error) {
    return '篩選條件無效：$error';
  }

  @override
  String get logcatNoMatches => '沒有符合條件的日誌';

  @override
  String get logcatPid => 'PID';

  @override
  String get logcatTid => 'TID';

  @override
  String get logcatBtnStop => '停止';

  @override
  String get logcatBtnStart => '開始';

  @override
  String get logcatClear => '清空日誌';

  @override
  String get logcatExport => '匯出 JSON';

  @override
  String get logcatExportTitle => '匯出 Logcat JSON';

  @override
  String logcatExportSaved(String path) {
    return '已儲存：$path';
  }

  @override
  String get logcatBottom => '跟隨即時尾端';

  @override
  String get logcatDetailTitle => '日誌詳情';

  @override
  String get logcatDetailTime => '時間';

  @override
  String get logcatDetailLevel => '級別';

  @override
  String get logcatDetailTag => '標籤';

  @override
  String get logcatDetailContent => '正文內容';

  @override
  String get logcatCopyAll => '複製全部';

  @override
  String get logcatCopyContent => '複製正文';

  @override
  String get toolsShell => 'Shell 終端';

  @override
  String get toolsProcess => '行程管理';

  @override
  String get toolsProp => '屬性編輯 (Prop)';

  @override
  String get toolsPropSearch => '搜尋屬性...';

  @override
  String get toolsPropWarning => '注意：透過 ADB 修改的屬性通常在設備重啟後會被重設。';

  @override
  String get toolsPropEditTitle => '修改屬性';

  @override
  String get toolsInspector => 'UI 檢視器';

  @override
  String get toolsInspDump => '抓取佈局';

  @override
  String get toolsInspNodeInfo => '節點屬性';

  @override
  String get processShowSystem => '顯示系統行程';

  @override
  String get processAutoRefresh => '自動重新整理';

  @override
  String get processSearchHint => '搜尋行程名或 PID...';

  @override
  String get processBtnRefresh => '重新整理';

  @override
  String get processBtnKill => '結束行程';

  @override
  String processKillSuccess(String name) {
    return '已結束: $name';
  }

  @override
  String processKillFail(String error) {
    return '結束失敗: $error';
  }

  @override
  String get shellBtnRun => '執行';

  @override
  String get scrcpyTitle => 'Scrcpy 投屏';

  @override
  String get scrcpyIntro => '高效能 Android 螢幕鏡像工具\n開源專案: Genymobile/scrcpy';

  @override
  String get scrcpyBtnStart => '啟動';

  @override
  String get scrcpyParamPreview => '啟動參數預覽 (可手動修改)';

  @override
  String get scrcpyGroupVideo => '畫面設定';

  @override
  String get scrcpyGroupControl => '控制與操作';

  @override
  String get scrcpyMaxSize => '解析度限制 (Max Size)';

  @override
  String get scrcpyBitrate => '位元率 (Bitrate)';

  @override
  String get scrcpyFps => '幀率 (FPS)';

  @override
  String get scrcpyStayAwake => '保持喚醒 (Stay Awake)';

  @override
  String get scrcpyTurnOffScreen => '關閉手機螢幕';

  @override
  String get scrcpyShowTouches => '顯示觸控點';

  @override
  String get scrcpyAlwaysOnTop => '視窗置頂';

  @override
  String get scrcpyNoAudio => '停用音訊轉發';

  @override
  String get scrcpyKeyNav => 'HID 鍵盤模擬';

  @override
  String get qcVolUp => '音量+';

  @override
  String get qcVolDown => '音量-';

  @override
  String get qcBack => '返回';

  @override
  String get qcHome => '桌面';

  @override
  String get qcRecent => '任務';

  @override
  String get qcShot => '截圖';

  @override
  String get qcPaste => '貼上';

  @override
  String get qcPower => '電源';

  @override
  String get qcMenu => '選單';

  @override
  String get qcEnter => 'Enter';

  @override
  String get qcSpace => 'Space';

  @override
  String get settingsTitle => '設定';

  @override
  String get settingsLanguage => '語言 / Language';

  @override
  String get settingsTheme => '外觀 / Appearance';

  @override
  String get settingsAdbPath => 'ADB 環境';

  @override
  String get settingsAdbManual => '手動指定 ADB 路徑';

  @override
  String get settingsAdbFallback => '回路完成：應用程式預設';

  @override
  String get settingsAdbReset => '重設為預設';

  @override
  String get settingsQuickBoot => '功能增強';

  @override
  String get settingsShowQuick => '主頁顯示快速啟動';

  @override
  String get colorPurple => '夢境紫';

  @override
  String get colorBlue => '深海藍';

  @override
  String get colorGreen => '森林綠';

  @override
  String get colorRed => '玫瑰紅';

  @override
  String get colorOrange => '落日橙';

  @override
  String get colorPink => '櫻花粉';

  @override
  String get colorGrey => '極簡灰';

  @override
  String get colorTeal => '青色';

  @override
  String get colorIndigo => '靛藍';

  @override
  String get colorBrown => '棕色';

  @override
  String get dialogSwitchDevice => '切換當前裝置';

  @override
  String get deviceCurrentTag => '當前';

  @override
  String get btnAddCustom => '新增自訂指令';

  @override
  String get dialogAddTitle => '新增捷徑';

  @override
  String get dialogName => '名稱';

  @override
  String get dialogCommand => 'Shell 命令';

  @override
  String get btnCancel => '取消';

  @override
  String get btnAdd => '新增';

  @override
  String get tipPowerMenu => '電源選單';

  @override
  String get tipRestartSystem => '重新啟動系統';

  @override
  String get tipRestartRecovery => '重啟至 Recovery';

  @override
  String get tipRestartBootloader => '重啟至 Bootloader';

  @override
  String get tipShutdown => '關機';

  @override
  String get tipKillServer => '停止服務並退出';

  @override
  String get tipRefresh => '重新整理連線';

  @override
  String get wirelessHistory => '歷史記錄';

  @override
  String get wirelessEnterIp => '輸入 IP:Port';

  @override
  String get wirelessConnect => '連結';

  @override
  String get wirelessDisconnect => '斷開';

  @override
  String get wirelessRemoveHistory => '移除記錄';

  @override
  String get wirelessIp => 'IP 地址';

  @override
  String get wirelessPort => '端口';

  @override
  String get wirelessWarning => '此裝置正透過無線連結，可能造成操作延遲或部分功能受限';
}

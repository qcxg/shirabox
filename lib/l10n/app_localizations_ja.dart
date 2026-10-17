// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Japanese (`ja`).
class AppLocalizationsJa extends AppLocalizations {
  AppLocalizationsJa([String locale = 'ja']) : super(locale);

  @override
  String get appTitle => 'Shirabox';

  @override
  String get navConnect => '接続';

  @override
  String get navWireless => 'ワイヤレス接続';

  @override
  String get navApps => 'アプリ';

  @override
  String get navFiles => 'ファイル';

  @override
  String get navLogs => 'Logcat';

  @override
  String get navTools => 'ツール';

  @override
  String get navMirror => 'ミラーリング';

  @override
  String get navSettings => '設定';

  @override
  String get homeWaitDevice => 'デバイス接続待ち...';

  @override
  String get homeWaitHint => 'USBデバッグを有効にしてください。';

  @override
  String get homeManualCheck => '手動確認';

  @override
  String get homeNoAdbTitle => 'ADBなし';

  @override
  String get homeNoAdbContent => 'PATHにadb.exeがありません。\n設定でパスを指定してください。';

  @override
  String get homeGoSettings => 'パス設定';

  @override
  String get homeRetryCheck => '再試行';

  @override
  String get homeTabCpu => 'CPU';

  @override
  String get homeTabRam => 'メモリ';

  @override
  String get homeTabStorage => 'ストレージ';

  @override
  String get homeItemKernel => 'カーネル';

  @override
  String get homeQuickBoot => 'クイック起動';

  @override
  String get appsSystemApps => 'システムアプリを表示';

  @override
  String get appsSearchHint => 'アプリを検索...';

  @override
  String get appsMultiSelect => '複数選択';

  @override
  String get appsRefresh => '更新';

  @override
  String get appsEmpty => 'データなし';

  @override
  String get appsDropHint => 'APK / XAPK / APKS をドロップ\nしてインストール';

  @override
  String appsSelected(int count) {
    return '選択中: $count';
  }

  @override
  String get appsSelectAll => '全選択';

  @override
  String get appsDeselect => '取消';

  @override
  String get appsBatchExtract => '一括抽出';

  @override
  String get appsExtractSuccess => '抽出成功';

  @override
  String appsExtractFail(String error) {
    return '抽出失敗: $error';
  }

  @override
  String get appsBatchExtractFinish => '一括タスク完了、ログを確認してください';

  @override
  String get actionExtractApk => 'APKを抽出';

  @override
  String get actionExtractAll => '完全なパッケージを抽出 (APKS)';

  @override
  String get actionFreeze => 'アプリを無効化';

  @override
  String get actionUnfreeze => 'アプリを有効化';

  @override
  String get actionUninstall => 'アンインストール';

  @override
  String get actionOpen => 'アプリを開く';

  @override
  String get appsLaunchWithMirror => '起動時にミラーリングを開始';

  @override
  String get installDialogTitleInstalling => 'インストール中...';

  @override
  String get installDialogTitleDone => '一括インストール完了';

  @override
  String get installDialogClose => '閉じる';

  @override
  String get installStopAfterCurrent => '停止';

  @override
  String installCompletedCount(int completed, int total) {
    return '完了 $completed/$total';
  }

  @override
  String get installVerifyRefresh => 'アプリ一覧を更新中...';

  @override
  String get installSuccessToast => 'インストール完了、リスト更新中...';

  @override
  String get appsChoosePackages => 'パッケージを選択';

  @override
  String get filesPathHint => 'パスを入力...';

  @override
  String get filesUploadDrop => 'ファイルまたはフォルダーをドロップ\nしてアップロード';

  @override
  String get filesChooseFiles => 'ファイルを選択';

  @override
  String get filesChooseFolder => 'フォルダーを選択';

  @override
  String filesLoadedCount(int count) {
    return '$count 件を読み込み済み';
  }

  @override
  String filesListingFailed(String error) {
    return 'フォルダーを読み込めません: $error';
  }

  @override
  String get filesTransferStop => '停止';

  @override
  String get filesTransferUploading => 'アップロード中';

  @override
  String get filesTransferDownloading => 'ダウンロード中';

  @override
  String get filesTransferDeleting => '削除中';

  @override
  String filesTransferFailed(int count) {
    return '$count 件失敗';
  }

  @override
  String filesUploadComplete(int success, int total) {
    return 'アップロード完了 ($success/$total)';
  }

  @override
  String get filesSelectMode => '複数選択';

  @override
  String filesSelected(int count) {
    return '選択中: $count';
  }

  @override
  String get filesSelectAll => '全選択';

  @override
  String get filesDeselect => 'キャンセル';

  @override
  String get filesDownloadSelected => '選択項目をダウンロード';

  @override
  String filesExportSelected(int count) {
    return '選択項目をエクスポート ($count)';
  }

  @override
  String get filesDeleteSelected => '選択項目を削除';

  @override
  String filesDeleteConfirmBatch(int count) {
    return '選択した $count 個のファイルを削除しますか？';
  }

  @override
  String get filesMenuDownload => 'ダウンロード';

  @override
  String get filesMenuDelete => '削除';

  @override
  String get filesDeleteDialogTitle => '削除の確認';

  @override
  String get filesDeleteDialogContent => '完全に削除しますか:';

  @override
  String filesDeleteDialogPath(String path) {
    return 'パス: $path';
  }

  @override
  String get filesSnackDownloadDone => 'ダウンロード完了';

  @override
  String filesSnackDeleteFail(String error) {
    return '削除失敗: $error';
  }

  @override
  String get logcatHint => 'ログを絞り込む...';

  @override
  String get logcatFilterHelp =>
      '複数条件は AND です。tag:ActivityManager、msg:\"not responding\"、pid:1234、level:E,F、-noise が使えます。';

  @override
  String get logcatRegex => '正規表現';

  @override
  String get logcatCaseSensitive => '大文字小文字を区別';

  @override
  String get logcatResumeLive => 'ライブ末尾に戻る';

  @override
  String logcatStats(int visible, int retained, int pending) {
    return '表示 $visible / 保持 $retained / 保留 $pending';
  }

  @override
  String logcatDropped(int count) {
    return '入力 $count 行を破棄';
  }

  @override
  String logcatFilterInvalid(String error) {
    return 'フィルターが無効です: $error';
  }

  @override
  String get logcatNoMatches => '一致するログはありません';

  @override
  String get logcatPid => 'PID';

  @override
  String get logcatTid => 'TID';

  @override
  String get logcatBtnStop => '停止';

  @override
  String get logcatBtnStart => '開始';

  @override
  String get logcatClear => 'ログをクリア';

  @override
  String get logcatExport => 'JSONをエクスポート';

  @override
  String get logcatExportTitle => 'Logcat JSONをエクスポート';

  @override
  String logcatExportSaved(String path) {
    return '保存しました: $path';
  }

  @override
  String get logcatBottom => 'ライブ末尾を追跡';

  @override
  String get logcatDetailTitle => 'ログ詳細';

  @override
  String get logcatDetailTime => '時刻';

  @override
  String get logcatDetailLevel => 'レベル';

  @override
  String get logcatDetailTag => 'タグ';

  @override
  String get logcatDetailContent => '本文';

  @override
  String get logcatCopyAll => 'すべてコピー';

  @override
  String get logcatCopyContent => '本文をコピー';

  @override
  String get toolsShell => 'Shell ターミナル';

  @override
  String get toolsProcess => 'プロセス管理';

  @override
  String get toolsProp => '属性編集 (Prop)';

  @override
  String get toolsPropSearch => '属性を検索...';

  @override
  String get toolsPropWarning => '注意：ADB経由で変更された属性は通常、再起動後にリセットされます。';

  @override
  String get toolsPropEditTitle => '属性を編集';

  @override
  String get toolsInspector => 'UI インスペクター';

  @override
  String get toolsInspDump => 'レイアウト取得';

  @override
  String get toolsInspNodeInfo => 'ノードプロパティ';

  @override
  String get processShowSystem => 'システムプロセスを表示';

  @override
  String get processAutoRefresh => '自動更新';

  @override
  String get processSearchHint => 'プロセス名またはPIDを検索...';

  @override
  String get processBtnRefresh => '更新';

  @override
  String get processBtnKill => 'プロセス終了';

  @override
  String processKillSuccess(String name) {
    return '終了しました: $name';
  }

  @override
  String processKillFail(String error) {
    return '終了失敗: $error';
  }

  @override
  String get shellBtnRun => '実行';

  @override
  String get scrcpyTitle => 'Scrcpy ミラーリング';

  @override
  String get scrcpyIntro => '高性能Android画面ミラーリングツール\nオープンソース: Genymobile/scrcpy';

  @override
  String get scrcpyBtnStart => '起動';

  @override
  String get scrcpyParamPreview => 'コマンドプレビュー (編集可)';

  @override
  String get scrcpyGroupVideo => '画面設定';

  @override
  String get scrcpyGroupControl => '操作設定';

  @override
  String get scrcpyMaxSize => '解像度制限 (Max Size)';

  @override
  String get scrcpyBitrate => 'ビットレート (Bitrate)';

  @override
  String get scrcpyFps => 'フレームレート (FPS)';

  @override
  String get scrcpyStayAwake => 'スリープ無効化 (Stay Awake)';

  @override
  String get scrcpyTurnOffScreen => 'スマホ画面をオフ';

  @override
  String get scrcpyShowTouches => 'タッチを表示';

  @override
  String get scrcpyAlwaysOnTop => '常に手前に表示';

  @override
  String get scrcpyNoAudio => '音声を転送しない';

  @override
  String get scrcpyKeyNav => 'HIDキーボード';

  @override
  String get qcVolUp => '音量+';

  @override
  String get qcVolDown => '音量-';

  @override
  String get qcBack => '戻る';

  @override
  String get qcHome => 'ホーム';

  @override
  String get qcRecent => '履歴';

  @override
  String get qcShot => 'スクショ';

  @override
  String get qcPaste => '貼付';

  @override
  String get qcPower => '電源';

  @override
  String get qcMenu => 'メニュー';

  @override
  String get qcEnter => 'Enter';

  @override
  String get qcSpace => 'Space';

  @override
  String get settingsTitle => '設定';

  @override
  String get settingsLanguage => '言語 / Language';

  @override
  String get settingsTheme => '外観 / Appearance';

  @override
  String get settingsAdbPath => 'ADB環境';

  @override
  String get settingsAdbManual => 'ADBパス手動設定';

  @override
  String get settingsAdbFallback => 'フォールバック：アプリデフォルト';

  @override
  String get settingsAdbReset => 'デフォルトに戻す';

  @override
  String get settingsQuickBoot => '機能拡張';

  @override
  String get settingsShowQuick => 'クイック起動を表示';

  @override
  String get colorPurple => 'ドリームパープル';

  @override
  String get colorBlue => 'ディープブルー';

  @override
  String get colorGreen => 'フォレストグリーン';

  @override
  String get colorRed => 'ローズレッド';

  @override
  String get colorOrange => 'サンセットオレンジ';

  @override
  String get colorPink => 'サクラピンク';

  @override
  String get colorGrey => 'ミニマルグレー';

  @override
  String get colorTeal => 'ティール';

  @override
  String get colorIndigo => 'インディゴ';

  @override
  String get colorBrown => 'ブラウン';

  @override
  String get dialogSwitchDevice => 'デバイスを切り替える';

  @override
  String get deviceCurrentTag => '現在';

  @override
  String get btnAddCustom => 'カスタムコマンド追加';

  @override
  String get dialogAddTitle => 'ショートカット追加';

  @override
  String get dialogName => '名前';

  @override
  String get dialogCommand => 'Shell コマンド';

  @override
  String get btnCancel => 'キャンセル';

  @override
  String get btnAdd => '追加';

  @override
  String get tipPowerMenu => '電源メニュー';

  @override
  String get tipRestartSystem => 'システム再起動';

  @override
  String get tipRestartRecovery => 'Recoveryモード';

  @override
  String get tipRestartBootloader => 'Bootloaderモード';

  @override
  String get tipShutdown => '電源オフ';

  @override
  String get tipKillServer => 'サーバー停止＆終了';

  @override
  String get tipRefresh => '接続更新';

  @override
  String get wirelessHistory => '履歴';

  @override
  String get wirelessEnterIp => 'IP:Port を入力';

  @override
  String get wirelessConnect => '接続';

  @override
  String get wirelessDisconnect => '切断';

  @override
  String get wirelessRemoveHistory => '削除';

  @override
  String get wirelessIp => 'IP アドレス';

  @override
  String get wirelessPort => 'ポート';

  @override
  String get wirelessWarning => 'ワイヤレス接続中です。遅延や一部機能の制限が発生する可能性があります';
}

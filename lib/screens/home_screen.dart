import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/sync_progress.dart';
import '../models/sync_result_banner.dart';
import '../models/sync_summary.dart';
import '../services/onelap_client.dart';
import '../services/fit_coordinate_rewrite_service.dart';
import '../services/gcj_correction_settings.dart';
import '../services/settings_service.dart';
import '../services/sync_failure_formatter.dart';
import '../services/state_store.dart';
import '../services/strava_client.dart';
import '../services/strava_upload_client.dart';
import '../services/strava_web_client.dart';
import '../services/strava_web_sync_adapter.dart';
import '../services/xingzhe_client.dart';
import '../services/intervals_icu_client.dart';
import '../services/outbase_client.dart';
import '../services/sync_engine.dart';
import 'settings_screen.dart';
import 'sync_history_screen.dart';
import '../models/update_info.dart';
import '../services/update_checker.dart';

class _SyncProgressDialog extends StatelessWidget {
  final SyncProgress progress;

  const _SyncProgressDialog({required this.progress});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('正在同步'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (progress.totalActivities > 0) ...[
            const Text('同步活动', style: TextStyle(fontSize: 13)),
            const SizedBox(height: 4),
            LinearProgressIndicator(
              value: progress.totalActivities > 0
                  ? progress.processed / progress.totalActivities
                  : 0,
            ),
            const SizedBox(height: 2),
            Text(
              '${progress.processed}/${progress.totalActivities}',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 16),
          ],
          if (progress.stravaEnabled && progress.uploadTotal > 0) ...[
            const Text('上传至 Strava', style: TextStyle(fontSize: 13)),
            const SizedBox(height: 4),
            LinearProgressIndicator(
              value: progress.uploadTotal > 0
                  ? progress.stravaUploaded / progress.uploadTotal
                  : 0,
            ),
            const SizedBox(height: 2),
            Text(
              '${progress.stravaUploaded}/${progress.uploadTotal}',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 16),
          ],
          if (progress.xingzheEnabled && progress.uploadTotal > 0) ...[
            const Text('上传至行者', style: TextStyle(fontSize: 13)),
            const SizedBox(height: 4),
            LinearProgressIndicator(
              value: progress.uploadTotal > 0
                  ? progress.xingzheUploaded / progress.uploadTotal
                  : 0,
            ),
            const SizedBox(height: 2),
            Text(
              '${progress.xingzheUploaded}/${progress.uploadTotal}',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
          if (progress.intervalsIcuEnabled && progress.uploadTotal > 0) ...[
            const Text('上传至 Intervals.icu', style: TextStyle(fontSize: 13)),
            const SizedBox(height: 4),
            LinearProgressIndicator(
              value: progress.uploadTotal > 0
                  ? progress.intervalsIcuUploaded / progress.uploadTotal
                  : 0,
            ),
            const SizedBox(height: 2),
            Text(
              '${progress.intervalsIcuUploaded}/${progress.uploadTotal}',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
          if (progress.outbaseEnabled && progress.uploadTotal > 0) ...[
            const Text('上传至 Outbase', style: TextStyle(fontSize: 13)),
            const SizedBox(height: 4),
            LinearProgressIndicator(
              value: progress.uploadTotal > 0
                  ? progress.outbaseUploaded / progress.uploadTotal
                  : 0,
            ),
            const SizedBox(height: 2),
            Text(
              '${progress.outbaseUploaded}/${progress.uploadTotal}',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
          if (progress.totalActivities == 0)
            const Text('正在获取活动列表...', style: TextStyle(fontSize: 13)),
        ],
      ),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, this.settingsService});

  final SettingsService? settingsService;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _stateStore = StateStore();
  late final SettingsService _settingsService;

  bool _syncing = false;
  String? _error;
  String? _lastSyncTime;
  List<SyncResultBanner> _banners = [];

  static const _githubUrl = 'https://github.com/Tyan66666/Onelap-Strava-GoGoGo';
  static const _xiaohongshuUrl = 'https://xhslink.com/m/2SMVhuDAzdq';
  static const _prefKeyAboutShown = 'about_shown_once';

  @override
  void initState() {
    super.initState();
    _settingsService = widget.settingsService ?? SettingsService();
    _loadLastSyncTime();
    _loadBanners();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _showAboutIfFirstLaunch();
      _checkForUpdate();
    });
  }

  Future<void> _loadLastSyncTime() async {
    final t = await _stateStore.lastSuccessSyncTime();
    if (mounted) setState(() => _lastSyncTime = t);
  }

  Future<void> _loadBanners() async {
    final banners = await _stateStore.loadSyncResultBanners(limit: 7);
    if (mounted) setState(() => _banners = banners);
  }

  Future<void> _showAboutIfFirstLaunch() async {
    final prefs = await SharedPreferences.getInstance();
    final shown = prefs.getBool(_prefKeyAboutShown) ?? false;
    if (!shown) {
      await prefs.setBool(_prefKeyAboutShown, true);
      if (mounted) await _showAbout();
    }
  }

  Future<void> _checkForUpdate({bool showFeedback = false}) async {
    final updateInfo = await UpdateChecker.check();
    if (!mounted) return;
    if (!updateInfo.hasUpdate) {
      if (showFeedback) {
        showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('检查更新'),
            content: const Text('此为最新版本。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('好的'),
              ),
            ],
          ),
        );
      }
      return;
    }
    _showUpdateDialog(updateInfo);
  }

  void _showUpdateDialog(UpdateInfo info) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('发现新版本'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '最新版本: v${info.latestVersion}',
                style: const TextStyle(fontSize: 14),
              ),
              Text(
                '当前版本: v${info.currentVersion}',
                style: const TextStyle(fontSize: 13, color: Colors.grey),
              ),
              if (info.releaseNotes.isNotEmpty) ...[
                const SizedBox(height: 12),
                const Text(
                  '更新内容:',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                Text(
                  info.releaseNotes,
                  style: const TextStyle(fontSize: 13, height: 1.5),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              _launchUrl(info.downloadUrl);
            },
            child: const Text('下载更新'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('稍后再说'),
          ),
        ],
      ),
    );
  }

  Future<void> _launchUrl(String url) async {
    final uri = Uri.parse(url);
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('无法打开链接：$url')));
      }
    }
  }

  Future<void> _sync() async {
    setState(() {
      _syncing = true;
      _error = null;
    });

    try {
      final settings = await _settingsService.loadSettings();
      final username = settings[SettingsService.keyOneLapUsername] ?? '';
      final password = settings[SettingsService.keyOneLapPassword] ?? '';
      final stravaClientId = settings[SettingsService.keyStravaClientId] ?? '';
      final stravaClientSecret =
          settings[SettingsService.keyStravaClientSecret] ?? '';
      final stravaRefreshToken =
          settings[SettingsService.keyStravaRefreshToken] ?? '';
      final stravaAccessToken =
          settings[SettingsService.keyStravaAccessToken] ?? '';
      final stravaExpiresAt =
          int.tryParse(settings[SettingsService.keyStravaExpiresAt] ?? '0') ??
          0;
      final xingzheUsername =
          settings[SettingsService.keyXingzheUsername] ?? '';
      final xingzhePassword =
          settings[SettingsService.keyXingzhePassword] ?? '';
      final GcjCorrectionSettings gcjCorrection =
          GcjCorrectionSettings.fromSettings(settings);
      final bool uploadToStrava =
          settings[SettingsService.keyUploadToStrava] != 'false';
      final bool uploadToXingzhe =
          settings[SettingsService.keyUploadToXingzhe] == 'true';
      final bool uploadToIntervalsIcu =
          settings[SettingsService.keyUploadToIntervalsIcu] == 'true';
      final intervalsIcuAthleteId =
          settings[SettingsService.keyIntervalsIcuAthleteId] ?? '';
      final intervalsIcuApiKey =
          settings[SettingsService.keyIntervalsIcuApiKey] ?? '';
      final bool uploadToOutbase =
          settings[SettingsService.keyUploadToOutbase] == 'true';
      final outbaseSessionId =
          settings[SettingsService.keyOutbaseSessionId] ?? '';

      if (username.isEmpty || password.isEmpty) {
        if (!mounted) return;
        setState(() {
          _error = '请先在设置中填写 OneLap 凭证';
          _syncing = false;
        });
        return;
      }

      if (!uploadToStrava &&
          !uploadToXingzhe &&
          !uploadToIntervalsIcu &&
          !uploadToOutbase) {
        if (!mounted) return;
        setState(() {
          _error = '请至少选择一个上传平台';
          _syncing = false;
        });
        return;
      }

      final stravaUploadMode =
          settings[SettingsService.keyStravaUploadMode] ?? 'api';

      if (uploadToStrava &&
          stravaUploadMode == 'api' &&
          (stravaClientId.isEmpty ||
              stravaClientSecret.isEmpty ||
              stravaRefreshToken.isEmpty)) {
        if (!mounted) return;
        setState(() {
          _error = '请先在设置中填写 Strava 凭证';
          _syncing = false;
        });
        return;
      }

      if (uploadToXingzhe &&
          (xingzheUsername.isEmpty || xingzhePassword.isEmpty)) {
        if (!mounted) return;
        setState(() {
          _error = '请先在设置中填写 行者 凭证';
          _syncing = false;
        });
        return;
      }

      if (uploadToIntervalsIcu &&
          (intervalsIcuAthleteId.isEmpty || intervalsIcuApiKey.isEmpty)) {
        if (!mounted) return;
        setState(() {
          _error = '请先在设置中填写 Intervals.icu 凭证';
          _syncing = false;
        });
        return;
      }

      if (uploadToOutbase && outbaseSessionId.isEmpty) {
        if (!mounted) return;
        setState(() {
          _error = '请先在设置中登录 Outbase';
          _syncing = false;
        });
        return;
      }

      final oneLap = OneLapClient(
        baseUrl: 'https://www.onelap.cn',
        username: username,
        password: password,
      );
      StravaUploadClient? strava;
      if (uploadToStrava) {
        if (stravaUploadMode == 'web') {
          final webCookies =
              settings[SettingsService.keyStravaWebCookies] ?? '';
          if (webCookies.isEmpty) {
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('请先在设置中登录 Strava 网页版')),
            );
            setState(() => _syncing = false);
            return;
          }
          final webClient = StravaWebClient(cookies: webCookies);
          if (!await webClient.isSessionValid()) {
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Strava 网页登录已过期，请重新登录')),
            );
            setState(() => _syncing = false);
            return;
          }
          strava = StravaWebSyncAdapter(cookies: webCookies);
        } else {
          strava = StravaClient(
            clientId: stravaClientId,
            clientSecret: stravaClientSecret,
            refreshToken: stravaRefreshToken,
            accessToken: stravaAccessToken,
            expiresAt: stravaExpiresAt,
          );
        }
      }
      XingzheClient? xingzhe;
      if (uploadToXingzhe) {
        xingzhe = await XingzheClient.create(
          username: xingzheUsername,
          password: xingzhePassword,
        );
      }
      IntervalsIcuClient? intervalsIcu;
      if (uploadToIntervalsIcu) {
        intervalsIcu = IntervalsIcuClient(
          athleteId: intervalsIcuAthleteId,
          apiKey: intervalsIcuApiKey,
        );
      }
      OutbaseClient? outbase;
      if (uploadToOutbase) {
        debugPrint(
          'Outbase sync: sessionId=$outbaseSessionId (length=${outbaseSessionId.length})',
        );
        outbase = OutbaseClient(sessionId: outbaseSessionId);
      }
      final engine = SyncEngine(
        oneLapClient: oneLap,
        stravaClient: strava,
        xingzheClient: xingzhe,
        intervalsIcuClient: intervalsIcu,
        outbaseClient: outbase,
        stateStore: _stateStore,
        gcjCorrection: gcjCorrection,
        uploadToStrava: uploadToStrava,
        uploadToXingzhe: uploadToXingzhe,
        uploadToIntervalsIcu: uploadToIntervalsIcu,
        uploadToOutbase: uploadToOutbase,
        rewriteService: FitCoordinateRewriteService(),
      );

      final progressNotifier = ValueNotifier<SyncProgress>(
        SyncProgress(
          stravaEnabled: uploadToStrava,
          xingzheEnabled: uploadToXingzhe,
          intervalsIcuEnabled: uploadToIntervalsIcu,
          outbaseEnabled: uploadToOutbase,
        ),
      );

      if (!mounted) return;
      late BuildContext dialogContext;
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) {
          dialogContext = ctx;
          return ValueListenableBuilder<SyncProgress>(
            valueListenable: progressNotifier,
            builder: (ctx, progress, _) =>
                _SyncProgressDialog(progress: progress),
          );
        },
      );

      try {
        final summary = await engine.runOnce(
          lookbackDays:
              int.tryParse(settings[SettingsService.keyLookbackDays] ?? '') ??
              3,
          onProgress: (p) => progressNotifier.value = p,
        );

        await _loadLastSyncTime();

        final banner = SyncResultBanner.fromSyncSummary(summary);
        await _stateStore.saveSyncResultBanner(banner);
        await _loadBanners();

        if (!mounted) return;
        // ignore: use_build_context_synchronously
        Navigator.of(dialogContext).pop();
        setState(() => _syncing = false);
        _showSyncResult(summary);
      } catch (e) {
        if (!mounted) return;
        // ignore: use_build_context_synchronously
        Navigator.of(dialogContext).pop();
        setState(() {
          _error = e.toString();
          _syncing = false;
        });
      } finally {
        progressNotifier.dispose();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _syncing = false;
      });
    }
  }

  // ---- Banner 列表项 ----

  Future<void> _deleteBanner(String bannerId) async {
    await _stateStore.deleteSyncResultBanner(bannerId);
    await _loadBanners();
  }

  void _showBannerDetail(SyncResultBanner banner) {
    final hasXingzhe =
        banner.xingzheSuccess > 0 ||
        banner.xingzheFailed > 0 ||
        banner.xingzheDeduped > 0 ||
        banner.xingzheFailures.isNotEmpty;
    final hasStrava =
        banner.stravaSuccess > 0 ||
        banner.stravaFailed > 0 ||
        banner.stravaDeduped > 0 ||
        banner.stravaFailures.isNotEmpty;
    final hasIntervalsIcu =
        banner.intervalsIcuSuccess > 0 ||
        banner.intervalsIcuFailed > 0 ||
        banner.intervalsIcuDeduped > 0 ||
        banner.intervalsIcuFailures.isNotEmpty;
    final hasOutbase =
        banner.outbaseSuccess > 0 ||
        banner.outbaseFailed > 0 ||
        banner.outbaseDeduped > 0 ||
        banner.outbaseFailures.isNotEmpty;

    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${banner.timeLabel} 同步详情'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // 概览
              Text(
                banner.summaryLine,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),

              // 行者
              if (hasXingzhe) ...[
                _sectionTitle('行者'),
                if (banner.xingzheSuccess > 0 ||
                    banner.xingzheFailed > 0 ||
                    banner.xingzheDeduped > 0)
                  Row(
                    children: [
                      if (banner.xingzheSuccess > 0)
                        _chip('成功 ${banner.xingzheSuccess}', Colors.green),
                      if (banner.xingzheSuccess > 0 &&
                          (banner.xingzheFailed > 0 ||
                              banner.xingzheDeduped > 0))
                        const SizedBox(width: 8),
                      if (banner.xingzheFailed > 0)
                        _chip('失败 ${banner.xingzheFailed}', Colors.red),
                      if (banner.xingzheFailed > 0 && banner.xingzheDeduped > 0)
                        const SizedBox(width: 8),
                      if (banner.xingzheDeduped > 0)
                        _chip('跳过 ${banner.xingzheDeduped}', Colors.white),
                    ],
                  ),
                if (banner.xingzheFailures.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  const Text(
                    '失败记录：',
                    style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                  ),
                  ...banner.xingzheFailures.map(
                    (f) => Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        '  【${f.displayText}】${f.error ?? ''}',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 12),
              ],

              // Strava
              if (hasStrava) ...[
                _sectionTitle('Strava'),
                if (banner.stravaSuccess > 0 ||
                    banner.stravaFailed > 0 ||
                    banner.stravaDeduped > 0)
                  Row(
                    children: [
                      if (banner.stravaSuccess > 0)
                        _chip('成功 ${banner.stravaSuccess}', Colors.green),
                      if (banner.stravaSuccess > 0 &&
                          (banner.stravaFailed > 0 || banner.stravaDeduped > 0))
                        const SizedBox(width: 8),
                      if (banner.stravaFailed > 0)
                        _chip('失败 ${banner.stravaFailed}', Colors.red),
                      if (banner.stravaFailed > 0 && banner.stravaDeduped > 0)
                        const SizedBox(width: 8),
                      if (banner.stravaDeduped > 0)
                        _chip('跳过 ${banner.stravaDeduped}', Colors.white),
                    ],
                  ),
                if (banner.stravaFailures.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  const Text(
                    '失败记录：',
                    style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                  ),
                  ...banner.stravaFailures.map(
                    (f) => Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        '  【${f.displayText}】${f.error ?? ''}',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ),
                ],
              ],

              // Intervals.icu
              if (hasIntervalsIcu) ...[
                _sectionTitle('Intervals.icu'),
                if (banner.intervalsIcuSuccess > 0 ||
                    banner.intervalsIcuFailed > 0 ||
                    banner.intervalsIcuDeduped > 0)
                  Row(
                    children: [
                      if (banner.intervalsIcuSuccess > 0)
                        _chip('成功 ${banner.intervalsIcuSuccess}', Colors.green),
                      if (banner.intervalsIcuSuccess > 0 &&
                          (banner.intervalsIcuFailed > 0 ||
                              banner.intervalsIcuDeduped > 0))
                        const SizedBox(width: 8),
                      if (banner.intervalsIcuFailed > 0)
                        _chip('失败 ${banner.intervalsIcuFailed}', Colors.red),
                      if (banner.intervalsIcuFailed > 0 &&
                          banner.intervalsIcuDeduped > 0)
                        const SizedBox(width: 8),
                      if (banner.intervalsIcuDeduped > 0)
                        _chip('跳过 ${banner.intervalsIcuDeduped}', Colors.white),
                    ],
                  ),
                if (banner.intervalsIcuFailures.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  const Text(
                    '失败记录：',
                    style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                  ),
                  ...banner.intervalsIcuFailures.map(
                    (f) => Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        '  【${f.displayText}】${f.error ?? ''}',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 12),
              ],

              // Outbase
              if (hasOutbase) ...[
                _sectionTitle('Outbase'),
                if (banner.outbaseSuccess > 0 ||
                    banner.outbaseFailed > 0 ||
                    banner.outbaseDeduped > 0)
                  Row(
                    children: [
                      if (banner.outbaseSuccess > 0)
                        _chip('成功 ${banner.outbaseSuccess}', Colors.green),
                      if (banner.outbaseSuccess > 0 &&
                          (banner.outbaseFailed > 0 ||
                              banner.outbaseDeduped > 0))
                        const SizedBox(width: 8),
                      if (banner.outbaseFailed > 0)
                        _chip('失败 ${banner.outbaseFailed}', Colors.red),
                      if (banner.outbaseFailed > 0 && banner.outbaseDeduped > 0)
                        const SizedBox(width: 8),
                      if (banner.outbaseDeduped > 0)
                        _chip('跳过 ${banner.outbaseDeduped}', Colors.white),
                    ],
                  ),
                if (banner.outbaseFailures.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  const Text(
                    '失败记录：',
                    style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                  ),
                  ...banner.outbaseFailures.map(
                    (f) => Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        '  【${f.displayText}】${f.error ?? ''}',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 12),
              ],

              if (!hasXingzhe && !hasStrava && !hasIntervalsIcu && !hasOutbase)
                const Text('暂无详细记录'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Widget _chip(String label, Color color) {
    final bool isWhiteChip = color == Colors.white;
    final Color textColor = isWhiteChip ? Colors.black87 : color;
    final Color borderColor = isWhiteChip
        ? Colors.grey.shade400
        : color.withValues(alpha: 0.4);
    final Color backgroundColor = isWhiteChip
        ? Colors.white
        : color.withValues(alpha: 0.12);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: borderColor),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: textColor,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _sectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text(
        title,
        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
      ),
    );
  }

  Widget _bannerItem(SyncResultBanner banner) {
    final bool hasFailure = banner.failed > 0;
    final Color accent = hasFailure ? Colors.orange : Colors.green;

    return Dismissible(
      key: Key(banner.id),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 16),
        color: Colors.red.shade400,
        child: const Icon(Icons.delete, color: Colors.white),
      ),
      onDismissed: (_) => _deleteBanner(banner.id),
      child: Card(
        margin: const EdgeInsets.only(bottom: 8),
        elevation: 1,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: accent.withValues(alpha: 0.4)),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => _showBannerDetail(banner),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 第一行：时间标签 + 概览
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: accent.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        banner.timeLabel,
                        style: TextStyle(
                          color: accent,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        banner.summaryLine,
                        style: const TextStyle(fontSize: 13),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Icon(
                      Icons.chevron_right,
                      color: Colors.grey.shade400,
                      size: 18,
                    ),
                  ],
                ),
                const SizedBox(height: 8),

                // 第二行：平台结果
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    if (banner.xingzheSuccess > 0 ||
                        banner.xingzheFailed > 0 ||
                        banner.xingzheDeduped > 0)
                      _platformChip(
                        '行者',
                        banner.xingzheSuccess,
                        banner.xingzheFailed,
                        banner.xingzheDeduped,
                      ),
                    if (banner.stravaSuccess > 0 ||
                        banner.stravaFailed > 0 ||
                        banner.stravaDeduped > 0)
                      _platformChip(
                        'Strava',
                        banner.stravaSuccess,
                        banner.stravaFailed,
                        banner.stravaDeduped,
                      ),
                    if (banner.intervalsIcuSuccess > 0 ||
                        banner.intervalsIcuFailed > 0 ||
                        banner.intervalsIcuDeduped > 0)
                      _platformChip(
                        'Intervals.icu',
                        banner.intervalsIcuSuccess,
                        banner.intervalsIcuFailed,
                        banner.intervalsIcuDeduped,
                      ),
                    if (banner.outbaseSuccess > 0 ||
                        banner.outbaseFailed > 0 ||
                        banner.outbaseDeduped > 0)
                      _platformChip(
                        'Outbase',
                        banner.outbaseSuccess,
                        banner.outbaseFailed,
                        banner.outbaseDeduped,
                      ),
                  ],
                ),

                // 失败记录展示（只显示前两条）
                if (banner.xingzheFailures.isNotEmpty ||
                    banner.stravaFailures.isNotEmpty ||
                    banner.intervalsIcuFailures.isNotEmpty ||
                    banner.outbaseFailures.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  ...banner.xingzheFailures
                      .take(2)
                      .map((f) => _failureLine('行者', f)),
                  ...banner.stravaFailures
                      .take(2)
                      .map((f) => _failureLine('Strava', f)),
                  ...banner.intervalsIcuFailures
                      .take(2)
                      .map((f) => _failureLine('Intervals.icu', f)),
                  ...banner.outbaseFailures
                      .take(2)
                      .map((f) => _failureLine('Outbase', f)),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _platformChip(String name, int ok, int fail, int deduped) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '$name:',
          style: const TextStyle(fontSize: 12, color: Colors.grey),
        ),
        const SizedBox(width: 4),
        if (ok > 0)
          Text(
            '$ok',
            style: const TextStyle(
              fontSize: 12,
              color: Colors.green,
              fontWeight: FontWeight.w600,
            ),
          ),
        if (ok > 0 && (fail > 0 || deduped > 0)) const SizedBox(width: 4),
        if (fail > 0)
          Text(
            '×$fail',
            style: const TextStyle(
              fontSize: 12,
              color: Colors.red,
              fontWeight: FontWeight.w600,
            ),
          ),
        if (fail > 0 && deduped > 0) const SizedBox(width: 4),
        if (deduped > 0)
          Text(
            '跳过$deduped',
            style: const TextStyle(
              fontSize: 12,
              color: Colors.black87,
              fontWeight: FontWeight.w600,
            ),
          ),
      ],
    );
  }

  Widget _failureLine(String platform, FailedActivitySummary f) {
    return Padding(
      padding: const EdgeInsets.only(top: 1),
      child: Text(
        '  $platform: 【${f.displayText}】${f.error ?? ''}',
        style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  // ---- 原有同步结果 dialog ----

  void _showSyncResult(SyncSummary summary) {
    if (summary.abortedReason == 'risk-control') {
      showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('同步中止'),
          content: const Text('OneLap 风控拦截，请稍后再试'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('关闭'),
            ),
          ],
        ),
      );
      return;
    }

    final bool hasFailures = summary.failed > 0;
    final bool hasSuccess = summary.success > 0;
    final bool nothingToSync = summary.success == 0 && summary.failed == 0;

    String title;
    if (hasFailures) {
      title = '同步完成';
    } else if (nothingToSync) {
      title = '没有要同步的啦🎉';
    } else {
      title = '成功同步 ${summary.success} 个🎉';
    }

    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (hasFailures) ...[
                if (hasSuccess)
                  Text(
                    '成功：${summary.success} 个',
                    style: const TextStyle(color: Colors.green),
                  ),
                Text(
                  '失败：${summary.failed} 个',
                  style: const TextStyle(color: Colors.red),
                ),
                const SizedBox(height: 8),
                const Text(
                  '失败原因：',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                ...summary.failureReasons.map(
                  (r) => Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      SyncFailureFormatter.toUserMessage(r),
                      style: const TextStyle(fontSize: 13, height: 1.4),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
              ],
              const Text('顺手给项目点个赞吧~'),
              const SizedBox(height: 8),
              InkWell(
                onTap: () => _launchUrl(_githubUrl),
                child: const Text(
                  'GitHub 开源地址',
                  style: TextStyle(
                    color: Colors.blue,
                    decoration: TextDecoration.underline,
                  ),
                ),
              ),
              const SizedBox(height: 6),
              InkWell(
                onTap: () => _launchUrl(_xiaohongshuUrl),
                child: const Text(
                  '小红书主页',
                  style: TextStyle(
                    color: Colors.red,
                    decoration: TextDecoration.underline,
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          if (hasFailures)
            TextButton(
              onPressed: () async {
                final info = await PackageInfo.fromPlatform();
                final detailText =
                    SyncFailureFormatter.buildClipboardTextWithMeta(
                      summary: summary,
                      appVersion: '${info.version}+${info.buildNumber}',
                    );
                await Clipboard.setData(ClipboardData(text: detailText));
                if (!mounted) return;
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(const SnackBar(content: Text('失败详细信息已复制到剪切板')));
              },
              child: const Text('复制失败详细信息'),
            ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Future<void> _showAbout() async {
    final info = await PackageInfo.fromPlatform();
    final version = info.version;

    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('关于 顽爪爪同步'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                '一款可以同步顽鹿 FIT 文件到 Strava 的小工具',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
              ),
              const SizedBox(height: 6),
              Text(
                '版本 $version',
                style: const TextStyle(fontSize: 13, color: Colors.grey),
              ),
              const SizedBox(height: 4),
              InkWell(
                onTap: () {
                  Navigator.of(ctx).pop();
                  _checkForUpdate(showFeedback: true);
                },
                child: const Text(
                  '检查更新',
                  style: TextStyle(
                    color: Colors.blue,
                    fontSize: 13,
                    decoration: TextDecoration.underline,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              const Text('免责声明', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              const Text(
                '本应用为个人开源项目，与 OneLap、Strava、行者、Intervals.icu、Outbase 官方无任何关联。'
                '使用本应用所产生的一切后果由用户自行承担，作者不承担任何责任。\n\n'
                '本应用不向任何第三方或作者服务器收集、传输用户数据。'
                '活动数据仅在你主动触发同步时上传至你所选择的平台（Strava、行者、Intervals.icu、Outbase）。所有凭证仅保存在你的设备本地。\n\n'
                '点击"立即同步"即视为你已阅读并同意本免责声明。',
                style: TextStyle(fontSize: 13, height: 1.5),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => _launchUrl(_githubUrl),
            child: const Text('GitHub 项目主页'),
          ),
          TextButton(
            onPressed: () => _launchUrl(_xiaohongshuUrl),
            child: const Text('作者小红书'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('顽爪爪同步'),
        actions: [
          IconButton(
            icon: const Icon(Icons.info_outline),
            tooltip: '关于',
            onPressed: _showAbout,
          ),
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: '同步记录',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SyncHistoryScreen()),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            ),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_lastSyncTime != null)
              Text(
                '上次同步: $_lastSyncTime',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: _syncing ? null : _sync,
              child: _syncing
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('立即同步'),
            ),
            const SizedBox(height: 6),
            if (_error != null)
              Text(
                _error!,
                style: const TextStyle(color: Colors.red, fontSize: 13),
              ),
            const SizedBox(height: 16),

            // 同步记录列表
            if (_banners.isNotEmpty) ...[
              const Row(
                children: [
                  Icon(Icons.list_alt, size: 16),
                  SizedBox(width: 4),
                  Text(
                    '同步记录',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                  ),
                  Spacer(),
                  Text(
                    '左滑删除',
                    style: TextStyle(fontSize: 11, color: Colors.grey),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              ..._banners.map((b) => _bannerItem(b)),
            ],
          ],
        ),
      ),
    );
  }
}

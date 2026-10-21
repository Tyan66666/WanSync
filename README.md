# 顽爪爪同步 / WanSync

<img src="android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png" width="96" alt="顽爪爪同步图标">

一款可以同步顽鹿 FIT 文件到 Strava、行者、Intervals.icu 和 Outbase 的小工具，也支持通过系统分享直接导入 FIT 文件上传。

*A lightweight app to sync OneLap (顽鹿) FIT activity files to Strava, Xingzhe, Intervals.icu, and Outbase, with support for importing FIT files directly from the system share sheet.*

---

## 功能 / Features

- 自动从 OneLap 下载 FIT 活动文件 / Auto-download FIT files from OneLap
- 支持从系统分享或“打开方式”接收 FIT 文件后上传到 Strava / Import FIT files from system share or open-in flows, then upload to Strava
- 支持上传到 Strava、行者、Intervals.icu 和 Outbase，可单独开启或同时开启 / Upload to Strava, Xingzhe, Intervals.icu, and Outbase, either individually or together
- 各平台独立去重，避免重复上传 / Per-platform deduplication to avoid duplicate uploads
- 可选在上传前将 GCJ-02 轨迹转换为 WGS84，四个平台可分别开启 / Optionally convert GCJ-02 tracks to WGS84 before upload, configurable per platform
- 设置同步天数（默认 3 天）/ Configurable lookback days (default 3)
- 内置 Strava OAuth 授权，无需手动填写 Token / Built-in Strava OAuth flow
- 首页展示最近同步结果 Banner，可展开查看详情 / Recent sync result banners on the home screen with expandable details
- 提供同步历史记录页面，查看每次同步到各平台的结果 / A sync history screen to inspect per-platform results for past runs
- 凭证仅保存在设备本地 / Credentials stored locally on device only

---

## 使用前提 / Prerequisites

1. OneLap（顽鹿）账号 / An OneLap account
2. Strava 账号 / A Strava account
3. （可选）Intervals.icu 账号 / (Optional) An Intervals.icu account
4. （可选）Outbase 账号 / (Optional) An Outbase account

> **上传方式：** 支持两种 Strava 上传方式，可在设置中切换：
> - **API 模式（推荐）：** 需要自己的 Strava API 应用（Client ID + Client Secret），最稳定。Strava 对个人开发者 API 有配额限制（每 15 分钟 200 次、每天 2000 次）。
> - **网页模式：** 通过 WebView 登录 Strava 账号即可，无需 API 凭证。2026 年 7 月 Strava API 将需要会员订阅，届时可切换到此模式。
>
> *Upload modes: switch in Settings.*
> - *API mode (recommended): requires your own Strava API app (Client ID + Client Subject). Strava enforces API rate limits (200 req/15 min, 2000 req/day).*
> - *Web mode: log in via WebView, no API credentials needed. Starting July 2026, Strava API will require a paid subscription — switch to this mode then.*

---

## 注册 Strava API（API 模式需要）/ Setting Up Strava API (API mode only)

> 如果使用网页模式，可跳过此节。/ Skip this section if using web mode.

1. 登录 https://www.strava.com/settings/api / Log in at https://www.strava.com/settings/api
2. 创建应用，Authorization Callback Domain 填 `localhost` / Create an app, set Authorization Callback Domain to `localhost`
3. 复制 Client ID 和 Client Secret 填入 App 设置 / Copy Client ID and Client Secret into the app settings
4. 点击「授权 Strava」完成 OAuth 授权，Access Token、Refresh Token 和 Expires At 将自动填入 / Tap "授权 Strava" to complete OAuth — Access Token, Refresh Token and Expires At will be filled in automatically

> 使用Google账户登录时，可能因谷歌限制无法正常完成OAuth授权，此时可在https://www.strava.com/account 中修改电子邮件地址，之后使用新的邮箱登录
>
> When logging in with a Google account, OAuth authorization may not be completed normally due to Google's restrictions. In this case, you can modify your email address at https://www.strava.com/account and then log in using the email address

---

## 设置 Intervals.icu（可选）/ Setting Up Intervals.icu (optional)

1. 登录 https://intervals.icu / Log in at https://intervals.icu
2. 进入 Settings > Developer，生成 API Key / Go to Settings > Developer and generate an API Key
3. 在 Intervals.icu 运动员页面 URL 中找到 Athlete ID（格式为 `i12345`）/ Find your Athlete ID from the athlete page URL (format: `i12345`)
4. 在 App 设置中打开 Intervals.icu，填入 Athlete ID 和 API Key / Enable Intervals.icu in app settings, fill in Athlete ID and API Key

---

## 设置 Outbase（可选）/ Setting Up Outbase (optional)

1. 打开 https://outbase.cn 并登录 / Open https://outbase.cn and log in
2. 在 App 设置中打开 Outbase 开关 / Enable Outbase in app settings
3. 点击 Outbase 设置卡片，通过 WebView 登录 / Tap the Outbase settings card, log in via WebView
4. 登录成功后 sessionId 会自动保存 / SessionId is saved automatically after login

> **注意：** Outbase 的 sessionId 有效期为 14 天，过期后需要重新登录。App 会在接近过期时显示警告。
>
> *Note: Outbase sessionId expires after 14 days. The app shows a warning when expiry is near.*

---

## 使用方式 / Usage

### 顽鹿内直接同步 / Sync from OneLap

在 App 中配置好顽鹿账号和目标平台后，点击同步即可按设置的回看天数自动下载并上传活动。

*After configuring OneLap and your destination platform(s) in the app, tap sync to download and upload activities within the configured lookback window.*

可以在设置中选择上传到 Strava、行者、Intervals.icu、Outbase，或同时上传到多个平台；每个平台都会独立判重并单独记录结果。

Strava 上传支持 API 和网页两种模式：API 模式需要配置 Client ID/Secret，网页模式只需登录 Strava 账号。Outbase 需要通过 WebView 登录获取 sessionId。

*In Settings, you can choose Strava, Xingzhe, Intervals.icu, Outbase, or any combination. Each platform is deduplicated independently and keeps its own sync result.*

*Strava upload supports API and Web modes: API mode requires Client ID/Secret, Web mode only needs a Strava account login. Outbase requires WebView login to obtain a sessionId.*

如果你的来源轨迹使用 GCJ-02，或者导入到目标平台后路线明显偏移，可以在设置中按平台开启坐标纠偏（「Strava / 行者 / Intervals.icu / Outbase 上传前将 GCJ-02 转为 WGS84」）。四个平台可分别开启：开启的平台上传转换后的文件，未开启的平台上传原始 FIT 文件。

*If your source track uses GCJ-02, or the uploaded route appears visibly offset on a destination platform, enable the per-platform coordinate correction in Settings (`Strava / Xingzhe / Intervals.icu / Outbase 上传前将 GCJ-02 转为 WGS84`). Each of the four platforms can be enabled independently: enabled platforms receive the converted file, while the others receive the original FIT file.*

### 通过系统分享导入 FIT / Import FIT via System Share

如果你已经拿到了 `.fit` 文件，也可以直接从系统分享菜单或“打开方式”把文件发给顽爪爪：

1. 在其他 App 中选中 `.fit` 文件并分享给顽爪爪 / In another app, share the `.fit` file to WanSync
2. 顽爪爪会打开确认页并显示文件名 / WanSync opens a confirmation screen and shows the file name
3. 点击「上传到 Strava」后开始上传 / Tap "上传到 Strava" to start upload

如果还没有完成 Strava 配置，App 会提示先去设置；这次分享不会被保留，需要配置完成后重新分享文件。

*If Strava is not configured yet, the app will ask you to finish setup first. The current shared file is not queued, so you need to share it again after setup.*

分享上传与自动同步共用同一套按平台坐标纠偏开关：开启了纠偏的目标平台收到转换后的文件，其余平台收到原始文件。

*Share uploads follow the same per-platform coordinate correction switches as automatic sync: targets with correction enabled receive the rewritten file, the others receive the original file.*

### 活动一直显示「已跳过」/ Activity Keeps Showing as Skipped

顽爪爪会在本地记录每个平台的「已同步」状态（按活动指纹 + 起始时间/距离判重）。只要某个平台已有成功记录，该平台就会显示「已跳过」，即使你后来打开了坐标纠偏也不会自动重传。如果确认线上确实没有这条活动，可以在设置 →「同步状态」点击「重置同步状态」：这会清空所有平台的已同步记录，下次同步会重新上传全部活动（同步历史不会删除）。

*WanSync stores a per-platform "already synced" marker locally (dedupe by activity fingerprint and start-time/distance). Once a platform has a success record it is skipped, even if coordinate correction was enabled later. If the activity is genuinely missing remotely, go to Settings → "同步状态" and tap "重置同步状态" to clear the synced state for all platforms; the next sync re-uploads everything (sync history is kept).*

### 顽鹿下载失败时的备用方式 / Fallback When OneLap Download Fails

如果某条活动在顽鹿侧下载失败，但顽鹿本身还能导出 FIT，也可以直接从顽鹿把 FIT 分享到顽爪爪，再手动上传到 Strava。

*If a specific activity fails to download through the OneLap sync path, but OneLap can still export the FIT file, you can share that FIT file directly to WanSync and upload it manually to Strava.*

---

## 界面预览 / Screenshots

### 最近同步结果详情 / Recent Sync Result Details

<img width="360" alt="最近同步结果详情" src="https://github.com/user-attachments/assets/3f0d7f22-111a-43a0-9398-6760480bfd73" />

### 同步历史记录 / Sync History

<img width="360" alt="同步历史记录" src="https://github.com/user-attachments/assets/4a1801be-d8d7-4c08-a9fe-e2876bdfcac6" />

---

## 构建 / Build

```bash
flutter pub get
flutter build apk --release --dart-define=FLUTTER_IMPELLER_ENABLED=false
```

---

## 免责声明 / Disclaimer

本应用为个人开源项目，与 OneLap、Strava、Intervals.icu 及 Outbase 官方无任何关联。使用本应用所产生的一切后果由用户自行承担，作者不承担任何责任。本应用不向任何第三方或作者服务器收集、传输用户数据。活动数据仅在你主动触发同步时上传至各目标平台。所有凭证仅保存在设备本地。

*This is a personal open-source project with no affiliation to OneLap, Strava, Intervals.icu, or Outbase. Use at your own risk. The author accepts no liability. No user data is collected or sent to any third-party or author-controlled server. Activity data is only uploaded to destination platforms when you explicitly trigger a sync. All credentials are stored locally on your device.*

---

## 许可证 / License

本项目基于 [GNU General Public License v3.0](LICENSE) 开源。

*This project is licensed under the [GNU General Public License v3.0](LICENSE).*

---

## 联系作者 / Contact

- GitHub: https://github.com/Tyan66666/Onelap-Strava-GoGoGo
- 小红书 / Xiaohongshu: https://xhslink.com/m/2SMVhuDAzdq

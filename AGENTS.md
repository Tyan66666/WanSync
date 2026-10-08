# AGENTS.md

Compact reference for OpenCode sessions working on this repo. Every line answers "would an agent miss this without help?"

## Project Snapshot

- App: `WanSync` / `onelap_strava_sync` — Flutter + Dart
- Purpose: sync OneLap FIT activity files to Strava and Xingzhe
- Entry: `lib/main.dart`
- Platform support: Android (primary), iOS, macOS, Linux, Windows, Web

## Source Layout

```
lib/
  main.dart              — app bootstrap, MaterialApp, share-intake wiring
  models/                — immutable data classes (OneLapActivity, SyncRecord, etc.)
  services/              — all business logic (network, sync, dedupe, settings, state)
  screens/               — UI screens (home, settings, share-confirm, OAuth, history)
test/
  models/                — model tests
  screens/               — screen tests
  services/              — service tests
```

Platform folders (`android/`, `ios/`, etc.) — only edit when the task requires platform-specific changes.

## Key Technical Facts

- **Two destination platforms**: Strava (upload + poll via REST API or web session) and Xingzhe (upload + poll via web session). Both can be enabled/disabled independently.
- **Strava upload modes**: API mode uses OAuth (`strava_client.dart`), web mode uses session cookies (`strava_web_client.dart`). Switchable in settings.
- **Deduplication**: two-layer — `fingerprint` (SHA256 of FIT bytes + recordKey + startTime) and `dedupeKey` (startTime + distance) as a stable fallback. See `dedupe_service.dart` and `state_store.dart`.
- **Coordinate conversion**: optional GCJ-02 → WGS84 rewrite before upload, using `fit_tool` package.
- **Strava OAuth**: done via `webview_flutter` in `strava_auth_screen.dart`. Tokens flow back into `SettingsService`.
- **OneLap login**: username/password-based, session via `dio_cookie_manager`.
- **State persistence**: `state.json` in app documents directory — contains synced fingerprints, dedupe keys, sync history (last 500 records), sync result banners (last 7).
- **Settings persistence**: all credentials via `flutter_secure_storage`, preferences via `shared_preferences`.
- **HTTP client**: `Dio` everywhere — with explicit timeouts (30s connect/receive) and cookie manager for OneLap.
- **Error types**:
  - `StravaRetriableError` / `StravaPermanentError` — for API 4xx vs 5xx distinction
  - `StravaWebSessionExpiredError` / `StravaWebUploadError` — web upload session expiry and upload failures
  - `OnelapRiskControlError` — risk-control triggered, sync aborted gracefully
  - `_isIdempotentSuccess()` in `sync_engine.dart` — catches "already uploaded" / duplicate responses as success

## Setup

```bash
flutter pub get
```

SDK: `^3.11.3` (pubspec.yaml).  
CI runs Flutter `3.41.5` stable (see `.github/workflows/ci.yml`).

## Build

```bash
# Release APK (primary target)
flutter build apk --release --dart-define=FLUTTER_IMPELLER_ENABLED=false

# Debug (signed with ~/.android/debug.keystore)
flutter build apk --debug
```

Debug builds use the default debug keystore at `~/.android/debug.keystore`. If it doesn't exist, create it with:
```bash
keytool -genkey -v -keystore ~/.android/debug.keystore -storepass android -alias androiddebugkey -keypass android -keyalg RSA -keysize 2048 -validity 10000 -dname "CN=Android Debug,O=Android,C=US"
```

## Verification Flow

```bash
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
```

Run in this order. CI enforces the same pipeline.

- **MUST pass all three before merging to main**: `dart format`, `flutter analyze`, `flutter test`. Don't rely on CI alone — run locally first.

### Targeted test commands

```bash
flutter test test/services/strava_client_test.dart          # single file
flutter test --plain-name "exact test name"                  # single test
flutter test -r expanded                                     # verbose output
```

When changing parsing, dedupe, sync, or persistence, add or update a test — coverage for these areas already exists in `test/services/`.

## Code Style

Follow existing repository patterns first. Standard Dart/Flutter conventions apply where the repo is silent.

- **Imports**: relative for local files (`../services/`), package imports for Flutter/external (`package:flutter/material.dart`). No mixed styles in the same file.
- **Naming**: `snake_case.dart` files; storage keys `UPPER_CASE` (`ONELAP_USERNAME` etc.).
- **Format**: `dart format` only — no hand-formatting. Respect trailing commas and multiline wrapping from the formatter.
- **Types**: prefer explicit types for fields and return values (matching existing code). Use nullable types only when `null` is a real state. Use `required` named parameters for mandatory inputs. Prefer `const` constructors and values.
- **i18n**: UI copy is Chinese, README is bilingual Chinese/English. Preserve both.
- **Theme**: Material 3, `Colors.deepOrange` seed.
- **UI pattern**: check `mounted` before using `context` after `await` in stateful widgets.
- **State/persistence**: keep persisted key names stable once released. `state.json` has backward-compat structure (`synced` → `platforms` per fingerprint, `dedupeKeys` → `fingerprint` + `platforms`). Prefer additive migrations over destructive resets.
- **Error handling**: use typed exceptions for retryable vs permanent distinction as the codebase does (`StravaRetriableError`, `StravaPermanentError`). Don't silently swallow errors. Surface recoverable issues through state or `SnackBar`/dialogs instead of crashing.
- **Networking**: handle 4xx and 5xx intentionally. Preserve auth-refresh behavior in `StravaClient`. Never log secrets, tokens, passwords, or client secrets.
- **Commit style**: imperative, concise — `Fix disclaimer...`, `Show About dialog...`. No amend, no force push. Check worktree state before committing.
- **README.md build command**: the exact release command is the canonical source.

## Release

To create a new release, check the latest version on [GitHub Releases](https://github.com/Tyan66666/WanSync/releases), increment the patch version by 1, then run the tag command. For example, if the latest release is `v1.0.26`, run:

```bash
git tag v1.0.27 && git push origin v1.0.27
```

## Instruction Files Checked

| Location | Exists |
|---|---|
| `.cursor/rules/` | No |
| `.cursorrules` | No |
| `.github/copilot-instructions.md` | No |
| `opencode.json` | No |

## What to Be Careful With

- **Credentials**: never log or commit tokens, passwords, or secrets. OAuth refresh and access tokens are stored via `flutter_secure_storage`.
- **Persisted keys**: don't rename them without backward-compat handling. `state.json` has a `dedupeKeys` → `platforms` → per-platform status structure that evolved over time.
- **Platform-specific code**: OneLap client emulates a mobile browser (user-agent, cookie flow). Changing headers can break login.
- **Worktrees**: `.worktrees/` is gitignored — manage them separately from repo edits.
- **Change hygiene**: make the smallest change that fully solves the task. Don't rewrite unrelated files for style preferences. Don't remove or rename persisted keys, public methods, or user-visible copy without a task-driven reason.

## Lessons Learned

- **Don't trust external input types.** API responses may be String, List, or Map depending on encoding. Verify types before casting; use `jsonDecode` or type checks.
- **New branches must walk the full path.** When adding a new `if` branch, trace from function entry to exit. Check every early return, every guard — the new branch may be blocked by a pre-existing check that doesn't apply to it.
- **Persist settings immediately.** If a user selects an option, save it on change. Don't rely on a separate "Save" button for settings that feel instant to the user.
- **Platform boundaries require native workarounds.** WebView's `document.cookie` can't read httpOnly cookies. Use platform-specific APIs (MethodChannel + native CookieManager) instead of fighting the platform.
- **Wrap exceptions at the boundary.** Catch HTTP/network exceptions in the method that makes the call and re-throw as business exceptions. Never let raw `DioException` or `IOException` leak to callers.
- **Timeout errors need context.** Include the last known state (e.g., last workflow value) in timeout messages. "Timeout" alone doesn't tell you if it's still processing or if the state is unrecognized.
- **Verify by testing, not guessing.** Don't assume API state values, cookie visibility, or response formats. Capture real traffic to confirm.
- **Get a second review.** Your code has blind spots. A reviewer (subagent or human) catches interface mismatches, missing edge cases, and logic ordering issues you'll miss.
- **Use agent-browser to capture real API requests.** When reverse-engineering an API, don't rely solely on spec docs or minified JS analysis. Use `agent-browser` to log in, intercept XHR/fetch, and trigger the actual browser flow — the real request often reveals subtle differences (e.g., URL parameter formats, missing date tags) that static analysis misses. Example: Outbase CDN `uri` parameter required `guid+dateTag` suffix, which was only discoverable by capturing the browser's actual upload request.

<!-- gitnexus:start -->
# GitNexus — Code Intelligence

This project is indexed by GitNexus as **Onelap-Strava-GoGoGo** (3439 symbols, 6734 relationships, 220 execution flows). Use the GitNexus MCP tools to understand code, assess impact, and navigate safely.

> If any GitNexus tool warns the index is stale, run `npx gitnexus analyze` in terminal first.

## Always Do

- **MUST run impact analysis before editing any symbol.** Before modifying a function, class, or method, run `gitnexus_impact({target: "symbolName", direction: "upstream"})` and report the blast radius (direct callers, affected processes, risk level) to the user.
- **MUST run `gitnexus_detect_changes()` before committing** to verify your changes only affect expected symbols and execution flows.
- **MUST warn the user** if impact analysis returns HIGH or CRITICAL risk before proceeding with edits.
- When exploring unfamiliar code, use `gitnexus_query({query: "concept"})` to find execution flows instead of grepping. It returns process-grouped results ranked by relevance.
- When you need full context on a specific symbol — callers, callees, which execution flows it participates in — use `gitnexus_context({name: "symbolName"})`.

## Never Do

- NEVER edit a function, class, or method without first running `gitnexus_impact` on it.
- NEVER ignore HIGH or CRITICAL risk warnings from impact analysis.
- NEVER rename symbols with find-and-replace — use `gitnexus_rename` which understands the call graph.
- NEVER commit changes without running `gitnexus_detect_changes()` to check affected scope.

## Resources

| Resource | Use for |
|----------|---------|
| `gitnexus://repo/Onelap-Strava-GoGoGo/context` | Codebase overview, check index freshness |
| `gitnexus://repo/Onelap-Strava-GoGoGo/clusters` | All functional areas |
| `gitnexus://repo/Onelap-Strava-GoGoGo/processes` | All execution flows |
| `gitnexus://repo/Onelap-Strava-GoGoGo/process/{name}` | Step-by-step execution trace |

## CLI

| Task | Read this skill file |
|------|---------------------|
| Understand architecture / "How does X work?" | `.claude/skills/gitnexus/gitnexus-exploring/SKILL.md` |
| Blast radius / "What breaks if I change X?" | `.claude/skills/gitnexus/gitnexus-impact-analysis/SKILL.md` |
| Trace bugs / "Why is X failing?" | `.claude/skills/gitnexus/gitnexus-debugging/SKILL.md` |
| Rename / extract / split / refactor | `.claude/skills/gitnexus/gitnexus-refactoring/SKILL.md` |
| Tools, resources, schema reference | `.claude/skills/gitnexus/gitnexus-guide/SKILL.md` |
| Index, status, clean, wiki CLI commands | `.claude/skills/gitnexus/gitnexus-cli/SKILL.md` |

<!-- gitnexus:end -->

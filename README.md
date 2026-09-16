# Sticker Manager

Sticker Manager is a local-first image and GIF library for Windows and Android.
The first release provides a Windows tray quick picker, an Android floating
panel and share import, groups, notes, usage ranking, and an encrypted portable
backup format.

## Current implementation

- Flutter UI and shared domain code in `lib/`.
- Media and migration services depend on `StickerRepository` and `ImportSource`
  boundaries, so SQLite and Windows directory discovery can be replaced by
  another local or synced implementation later.
- SQLite persistence with content-hash deduplication.
- Windows and Android platform bridges are defined behind `PlatformBridge`.
- Windows import only scans identified emotion folders and falls back to a file
  picker when no known folder is found. QQNT paths include
  `Tencent Files\<QQ号>\nt_qq\nt_data\Emoji\personal_emoji\Ori`,
  `marketface`, and `emoji-recv`; older QQ paths include `CustomFace` and
  `CustomFaceRecv`. QQNT custom installs such as
  `<盘符>:\QQ_NT\dialogue\Tencent Files\<QQ号>` are also checked. WeChat paths include
  `WeChat Files\<账号>\FileStorage\CustomEmotion` and the corresponding
  `xwechat_files` path.
- Automatic and folder imports show a source-and-count preview before writing;
  selecting a QQ account parent is restricted to known emotion subfolders so
  chat images are not imported accidentally. Directory scanning validates image
  signatures, so extensionless and unusually named image files are accepted.
- Android receives `ACTION_SEND` and `ACTION_SEND_MULTIPLE` image shares.
- Android share intents are persisted until an import is acknowledged, so a
  failed import or process restart can retry pending items; the `接收分享`
  button remains available for that retry. A stable fingerprint of the action,
  MIME type, data URI, and shared URI set prevents the same share from being
  copied into the cache twice across Activity recreation.
- Android can keep a compact floating panel above other apps. The first enable
  action opens the system overlay permission page; the panel shows the current
  top 100 ranked stickers and copies the selected file to the system clipboard.
  Successful selections are queued with their sticker IDs and merged into
  usage counts when the main UI starts or returns to the foreground.
  Starting it repeatedly is idempotent: only one foreground service owns the
  overlay, and a failed start releases its pending request.
- Any sticker can be assigned to multiple user-created groups from its folder
  action. The `全部` group is kept as the virtual catch-all group.
- Windows uses `Ctrl+Shift+E` as the default global quick-picker hotkey; it can
  be changed from the settings menu and is persisted locally. If Windows
  reports that the combination is already occupied, the app keeps running and
  prompts the user to choose another combination.
- Windows runs as a single instance. Closing the window hides it to the tray;
  launching the executable again waits for the first window to be ready,
  activates that existing instance, and exits without creating another window.
- Windows records the target executable, media type, and paste/send outcome for
  each hotkey-driven send; the latest 100 records are available in the settings
  menu for QQ/WeChat compatibility checks.
- Export files use a versioned manifest and authenticated encryption.
- Package import recalculates every media SHA-256 hash before creating a record.
  Media records and thumbnails are restored in batches to keep large packages
  responsive.
- Thumbnail generation is versioned; upgrading the generator rebuilds older
  thumbnails in the background while the original media remains available.
- Existing records can be removed individually from a sticker card or in bulk
  by source from `设置 -> 清理导入记录`; only app-managed copies are deleted.

## Run

Flutter 3.47.3 or a compatible Flutter SDK is required. Set `FLUTTER_ROOT`
to the SDK directory, or make `flutter.bat` available on `PATH`. From this
directory run:

```powershell
$env:FLUTTER_ROOT='/path/to/flutter'
& "$env:FLUTTER_ROOT/bin/flutter.bat" pub get
& "$env:FLUTTER_ROOT/bin/flutter.bat" run -d windows
& "$env:FLUTTER_ROOT/bin/flutter.bat" run -d <android-device>
```

For Android arm64 Debug builds, use:

```powershell
$env:JAVA_HOME='/path/to/jdk17-or-newer'
$env:ANDROID_SDK_ROOT='/path/to/android-sdk'
& "$env:FLUTTER_ROOT/bin/flutter.bat" build apk --debug --target-platform android-arm64
```

Android builds require a Gradle runtime JDK version supported by the wrapper:
Java 17 or newer. Java 21 is also a valid Gradle runtime when it is installed.
Java 11 is too old for the current Gradle/Android Gradle Plugin combination and
must not be selected through `JAVA_HOME` or the system `PATH`. Android Java and
Kotlin bytecode targets remain Java 17 for compatibility with the API 28
minimum; that target is independent from the JDK used to run Gradle.

To build both release artifacts and create a Windows zip package, run:

```powershell
powershell -ExecutionPolicy Bypass -File .\tool\build_release.ps1
```

The Windows zip includes `README_FIRST.txt` and `Start-StickerManager.cmd` at
the package root. After extracting it, double-click the command file or
`sticker_manager.exe`; no installer or administrator permission is required.

To install the Windows Release directory for the current user without
administrator access, run:

```powershell
powershell -ExecutionPolicy Bypass -File .\tool\install_windows.ps1 -Launch
```

The installer creates a Start menu shortcut and refuses to overwrite a running
instance. Uninstall with the copied `uninstall_windows.ps1` in the install
directory; it also refuses to remove files while the installed process is
running.

The script refuses to build while a project-local `sticker_manager.exe` is
running and never terminates it. Before packaging, verify the single-instance
guard with:

```powershell
powershell -ExecutionPolicy Bypass -File .\tool\verify_single_instance.ps1
```

Launching the executable repeatedly activates the first tray instance and
exits the duplicate process. If the first process exits during startup, the
named mutex is released and exactly one subsequent launch takes ownership.
When no signing variables are configured, the Android `release` variant uses
the debug signing key from `android/app/build.gradle.kts`; configure a private
release keystore before distributing the APK outside local testing. The Gradle file accepts these four
environment variables without storing credentials in the project:
`STICKER_RELEASE_STORE_FILE`, `STICKER_RELEASE_STORE_PASSWORD`,
`STICKER_RELEASE_KEY_ALIAS`, and `STICKER_RELEASE_KEY_PASSWORD`. They must be
provided together; otherwise the build fails rather than silently using a
partially configured keystore.

The Windows debug executable is written to
`build/windows/x64/runner/Debug/sticker_manager.exe`; the Android APK is written
to `build/app/outputs/flutter-apk/app-debug.apk`. Android builds require SDK
Platform 36 and NDK 28.2.13676358 with their licenses accepted. On Windows,
Flutter plugin discovery also requires Developer Mode (or equivalent symlink
support) to be enabled before running `pub get`.

## Privacy and import behavior

The app never edits QQ or WeChat source files and does not parse private
databases. Windows import scans only the named emotion folders above, validates
image signatures, treats a selected `Tencent Files` parent as an emotion root,
and caps automatic discovery at 1,000 files per folder (the
normal QQ limit is about 500 and SVIP about 1,000). Android uses the system
share sheet because another app's private storage is sandboxed. The optional
floating panel requires Android's `显示在其他应用上层` permission and can be
disabled from the settings menu at any time.

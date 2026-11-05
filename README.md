# IPTV Player

A simple IPTV player for **Windows, macOS and Fire TV** (and other Android TV / Android devices).
No subscriptions, no ads, no bundled channels. Sign in with your provider's details and watch.

- **Xtream Codes** login (server, username, password): Live TV, Movies and Series with seasons/episodes
- **M3U / M3U Plus** playlist links, with channel groups as categories. Pasting an Xtream
  `get.php?username=…&password=…` link automatically uses the faster Xtream API when available.
- Categories, search across a whole section, favorites, saved accounts with auto sign-in
- Plays nearly any stream format (MPEG-TS, HLS, MKV, MP4; H.264/HEVC; AAC/AC3/E-AC3) using
  [mpv](https://mpv.io) through [media_kit](https://github.com/media-kit/media-kit)
- Tries the next stream format automatically if one fails, and reconnects dropped live streams
- Works with a TV remote: every screen can be driven with the D-pad, OK and Back buttons

Your logins and favorites are stored only on the device. The app talks directly to your provider.

## Downloads

Every push builds the apps on GitHub Actions (see the **Actions** tab, open a run, then
**Artifacts**). Pushing a tag like `v0.1.0` also publishes them as a GitHub Release.

| Platform | File | Notes |
|---|---|---|
| Fire TV / Android | `IPTV-Player-android.apk` | Sideload with the *Downloader* app, or `adb install` |
| Windows | `IPTV-Player-windows.zip` | Unzip and run `iptv_player.exe` |
| macOS | `IPTV-Player-macos.zip` | Unsigned for now: right-click the app and choose **Open** the first time |

### Installing on Fire TV

1. On the Fire TV: **Settings → My Fire TV → Developer options** and enable installing
   unknown apps for *Downloader* (on newer models, first tap **About → Fire TV Stick** seven
   times to reveal Developer options).
2. Install **Downloader** from the Appstore and enter the APK's download link,
   or from a computer run `adb connect <fire-tv-ip>` then `adb install IPTV-Player-android.apk`.

Requires a Fire TV running Fire OS (Android-based). The newest Vega OS models can't run Android apps.

## Remote and keyboard controls

| In the player | Remote | Keyboard |
|---|---|---|
| Previous / next channel (live) | Up / Down, Channel +/- | Up / Down, Page Up/Down |
| Seek -10 s / +10 s (movies, episodes) | Left / Right, Rewind / Fast-forward | Left / Right |
| Play / pause (shows info on live TV) | OK, Play/Pause | Enter, Space |
| Add / remove favorite | Menu | S |
| Fullscreen | | F, or double-click |
| Back to list | Back | Esc |

Search: Ctrl/Cmd+F on desktop, or the search button.

## Building it yourself

Install [Flutter](https://docs.flutter.dev/get-started/install) (3.47 or newer), then:

```bash
flutter pub get
flutter run                     # on the current desktop
flutter build apk --release     # Fire TV / Android
flutter build windows --release # on Windows
flutter build macos --release   # on a Mac
```

Linux works too (`flutter build linux`) and needs `libmpv-dev` installed.

## Project layout

```
lib/
  main.dart              app start, theme, TV remote key mapping
  models.dart            Profile, Category, MediaItem, Catalog
  storage.dart           saved accounts and favorites
  sources/
    xtream.dart          Xtream Codes API client
    m3u.dart             M3U parser
    source.dart          common interface; picks Xtream or M3U
    net.dart             HTTP with a player-like User-Agent
  ui/
    login_screen.dart
    home_screen.dart     sections, categories, list, search
    series_screen.dart   seasons and episodes
    player_screen.dart   full-screen player and remote controls
test/                    parser tests
```

## Before publishing to an app store

- **Amazon Appstore / Google Play:** create your own signing key (the release build is
  currently signed with a debug key, which is fine for sideloading only), and replace the
  default app icon. The TV banner is in `android/app/src/main/res/drawable-xhdpi/banner.png`.
- **Mac App Store or a notarized Mac download:** requires an Apple Developer account.
- **Microsoft Store:** package the Windows build as MSIX.

## Not yet included

TV guide (EPG), catch-up, choosing audio/subtitle tracks, parental PIN, and iOS testing.
iOS should work with the same code (`flutter build ios`) but hasn't been tested.
Apple TV would need a separate native app.

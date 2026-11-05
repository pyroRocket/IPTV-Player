# IPTV Player

A simple IPTV player for **Windows, macOS and Fire TV** (and other Android TV / Android devices).
No subscriptions, no ads, no bundled channels. Sign in with your provider's details and watch.

- **Xtream Codes** login (server, username, password): Live TV, Movies and Series with seasons/episodes
- **M3U / M3U Plus** playlist links, with channel groups as categories. Pasting an Xtream
  `get.php?username=…&password=…` link automatically uses the faster Xtream API when available.
- Categories, search across a whole section, favorites, saved accounts with auto sign-in
- **TV guide (EPG):** uses your provider's guide automatically (Xtream `xmltv.php` or the M3U's
  `x-tvg-url`), or any XMLTV address you set. Shows what's on now in the channel list and player,
  plus a full guide grid with a live preview pane, programme search and refresh
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
| Windows | `IPTV-Player-windows-setup.exe` | Installer with Start menu entry and uninstaller. Unsigned for now: on the SmartScreen warning choose **More info → Run anyway** |
| Windows (portable) | `IPTV-Player-windows.zip` | Unzip and run `iptv_player.exe` |
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
| Playback stats | Info | I |
| Fullscreen | | F, or double-click |
| Back to list | Back | Esc |

Search: Ctrl/Cmd+F on desktop, or the search button. TV guide: the guide button next to search,
or Ctrl/Cmd+G.

| In the TV guide | Remote | Keyboard |
|---|---|---|
| Move between programmes | Arrows (Left/Right at the edge moves the time) | Arrows |
| Watch the channel / details of a later show | OK | Enter |
| Show or hide the preview pane | preview button | P |
| Search programmes | search button | / |
| Refresh the guide | refresh button | R |
| Jump back to now | Now button | N |

The preview pane plays the selected channel in a small window. If your account allows only one
connection at a time, the preview stops automatically when you open a channel full screen.

## Playback settings

Account menu → **Playback settings**:

- **Video decoding:** hardware (default), hardware compatibility mode, or software. Try
  compatibility mode if video is black or glitchy.
- **Deinterlacing:** automatic by default, which smooths interlaced channels (common for live
  sports and 1080i broadcasts).
- **Smooth playback:** on by default. Uses lighter video scaling so weaker graphics chips keep up.

If playback stutters, press **I** while watching. "Dropped frames" going up or "Decoder: Software"
point to what's wrong.

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
  storage.dart           saved accounts, favorites and settings
  playback.dart          mpv performance options and stats
  epg/
    epg.dart             programmes and channel matching
    xmltv.dart           streaming XMLTV parser
    epg_service.dart     download, 12-hour cache, refresh
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
    guide_view.dart      TV guide grid, preview pane, search
test/                    parser tests
windows/installer/       Inno Setup script for the Windows installer
```

## Before publishing to an app store

- **Amazon Appstore / Google Play:** create your own signing key (the release build is
  currently signed with a debug key, which is fine for sideloading only), and replace the
  default app icon. The TV banner is in `android/app/src/main/res/drawable-xhdpi/banner.png`.
- **Mac App Store or a notarized Mac download:** requires an Apple Developer account.
- **Microsoft Store:** package the Windows build as MSIX.

## Not yet included

Catch-up / timeshift, choosing audio/subtitle tracks, parental PIN, and iOS testing.
iOS should work with the same code (`flutter build ios`) but hasn't been tested.
Apple TV would need a separate native app.

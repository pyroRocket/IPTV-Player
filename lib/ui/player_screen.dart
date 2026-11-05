import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../models.dart';
import '../sources/net.dart';
import 'theme.dart';
import 'widgets.dart';

/// Full-screen player.
///
/// Remote / keyboard:
///   Up/Down, Channel +/-   previous / next channel (live)
///   Left/Right             seek -10s / +10s (movies, episodes)
///   OK / Enter / Space     play-pause (shows info on live)
///   Menu / S               add or remove favorite
///   F / double-click       fullscreen (desktop)
///   Back / Esc             return to list
class PlayerScreen extends StatefulWidget {
  const PlayerScreen({
    super.key,
    required this.items,
    required this.index,
    required this.isFavorite,
    required this.onToggleFavorite,
  });

  final List<MediaItem> items;
  final int index;
  final bool Function(MediaItem) isFavorite;
  final void Function(MediaItem) onToggleFavorite;

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  late final Player _player = Player(
    configuration: const PlayerConfiguration(
      title: 'IPTV Player',
      bufferSize: 64 * 1024 * 1024,
      logLevel: MPVLogLevel.warn, // so HTTP errors (403/404) reach us
    ),
  );
  late final VideoController _video = VideoController(_player);
  final _focus = FocusNode();
  final _retryFocus = FocusNode();
  final List<StreamSubscription> _subs = [];

  late int _index = widget.index;
  int _sourceIndex = 0;
  int _gen = 0; // bumps on every open, so stale events are ignored
  bool _started = false;
  DateTime? _startedAt;
  int _reconnects = 0;
  String? _error;
  String? _status;
  String? _httpError;
  String _currentSource = '';
  late Future<void> _configured;
  bool _overlay = true;
  bool _fullscreen = false;
  Timer? _hideTimer, _startTimer, _zapTimer;

  MediaItem get _item => widget.items[_index];
  bool get _live => _item.kind == ItemKind.live;
  bool get _desktop => Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  @override
  void initState() {
    super.initState();
    _subs.addAll([
      // mpv also reports harmless errors here (e.g. a hardware decoder that
      // isn't available), so only give up on errors that stop playback.
      _player.stream.error.listen((e) {
        final fatal = e.startsWith('Failed to open') || e.startsWith('Failed to recognize');
        // Ignore late errors from the previous channel after zapping.
        final stale = e.startsWith('Failed to open') && !e.contains(_currentSource);
        if (fatal && !stale) _failed(_httpError ?? e);
      }),
      _player.stream.log.listen((l) {
        if (l.text.contains('HTTP error')) _httpError = l.text;
      }),
      _player.stream.completed.listen((done) {
        if (!done) return;
        if (_live || !_started) {
          _failed('Stream ended');
        } else {
          _showOverlay(sticky: true);
        }
      }),
      _player.stream.position.listen((p) {
        if (!_started && p > Duration.zero) _markStarted();
      }),
      _player.stream.width.listen((w) {
        if (!_started && (w ?? 0) > 0) _markStarted();
      }),
    ]);
    if (!_desktop) defaultEnterNativeFullscreen();
    _configured = _configure();
    _open();
  }

  Future<void> _configure() async {
    final p = _player.platform;
    if (p is NativePlayer) {
      await p.setProperty('user-agent', userAgent);
      await p.setProperty('network-timeout', '20');
      // Let ffmpeg ride out short network hiccups on live streams.
      await p.setProperty('stream-lavf-o', 'reconnect=1,reconnect_streamed=1,reconnect_delay_max=5');
    }
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _hideTimer?.cancel();
    _startTimer?.cancel();
    _zapTimer?.cancel();
    _player.dispose();
    _focus.dispose();
    _retryFocus.dispose();
    if (_fullscreen || !_desktop) defaultExitNativeFullscreen();
    super.dispose();
  }

  // ---- playback ---------------------------------------------------------

  void _open({bool reconnect = false}) {
    final gen = ++_gen;
    _startTimer?.cancel();
    setState(() {
      _started = false;
      _error = null;
      _status = reconnect ? 'Reconnecting…' : 'Loading…';
    });
    if (!reconnect) _reconnects = 0;
    _httpError = null;
    final src = _currentSource = _item.sources[_sourceIndex];
    _configured.then((_) {
      if (gen == _gen && mounted) _player.open(Media(src, httpHeaders: const {'User-Agent': userAgent}));
    });
    // If a format hangs, try the next one instead of waiting forever.
    if (_sourceIndex + 1 < _item.sources.length) {
      _startTimer = Timer(const Duration(seconds: 20), () {
        if (gen == _gen && !_started) _failed('Timed out');
      });
    }
    _showOverlay();
  }

  void _markStarted() {
    _startTimer?.cancel();
    setState(() {
      _started = true;
      _startedAt = DateTime.now();
      _status = null;
    });
  }

  void _failed(String reason) {
    final gen = _gen;
    if (!_started && _sourceIndex + 1 < _item.sources.length) {
      _sourceIndex++;
      _open();
      return;
    }
    if (_started && _live) {
      // A stream that played for a while and then dropped: reconnect.
      if (_startedAt != null && DateTime.now().difference(_startedAt!) > const Duration(seconds: 60)) {
        _reconnects = 0;
      }
      if (_reconnects < 3) {
        _reconnects++;
        Future.delayed(Duration(seconds: _reconnects), () {
          if (mounted && gen == _gen) _open(reconnect: true);
        });
        setState(() => _status = 'Reconnecting…');
        return;
      }
    }
    if (_error != null) return;
    _startTimer?.cancel();
    setState(() {
      _status = null;
      _error = _friendly(reason);
    });
    _showOverlay(sticky: true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _error != null) _retryFocus.requestFocus();
    });
  }

  String _friendly(String raw) {
    final r = raw.toLowerCase();
    if (r.contains('403') || r.contains('401')) {
      return 'The provider refused this stream. Your account may be expired, or too many devices are watching.';
    }
    if (r.contains('404')) return 'This stream isn\'t available right now (not found).';
    if (r.contains('timed out') || r.contains('timeout')) return 'The stream took too long to start.';
    if (r.contains('ended')) return 'The stream stopped.';
    if (r.contains('recognize')) return 'This stream is in a format the player can\'t read.';
    // Don't echo the raw error: stream URLs contain the account password.
    return 'This channel isn\'t working right now. Try again, or pick another one.';
  }

  void _step(int delta) {
    if (widget.items.length < 2) return;
    _zapTimer?.cancel();
    _player.stop();
    setState(() {
      _index = (_index + delta) % widget.items.length;
      if (_index < 0) _index += widget.items.length;
      _sourceIndex = 0;
      _error = null;
      _status = 'Loading…';
    });
    _showOverlay();
    // Wait a moment so holding the button skips through channels quickly.
    _zapTimer = Timer(const Duration(milliseconds: 400), _open);
  }

  void _seek(int seconds) {
    final pos = _player.state.position + Duration(seconds: seconds);
    _player.seek(pos < Duration.zero ? Duration.zero : pos);
    _showOverlay();
  }

  Future<void> _toggleFullscreen() async {
    _fullscreen = !_fullscreen;
    await (_fullscreen ? defaultEnterNativeFullscreen() : defaultExitNativeFullscreen());
    setState(() {});
  }

  void _showOverlay({bool sticky = false}) {
    _hideTimer?.cancel();
    if (!_overlay) setState(() => _overlay = true);
    if (!sticky) {
      _hideTimer = Timer(const Duration(seconds: 4), () {
        if (mounted && _error == null && _status == null) setState(() => _overlay = false);
      });
    }
  }

  // ---- input ------------------------------------------------------------

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    final isRepeat = e is KeyRepeatEvent;

    if (k == LogicalKeyboardKey.channelUp ||
        k == LogicalKeyboardKey.pageUp ||
        (k == LogicalKeyboardKey.arrowUp && _live)) {
      _step(-1);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.channelDown ||
        k == LogicalKeyboardKey.pageDown ||
        (k == LogicalKeyboardKey.arrowDown && _live)) {
      _step(1);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.escape) {
      if (_fullscreen) {
        _toggleFullscreen();
      } else {
        Navigator.of(context).maybePop();
      }
      return KeyEventResult.handled;
    }
    // While an error is showing, let OK/arrows drive the Retry/Back buttons.
    if (_error != null) return KeyEventResult.ignored;

    if (!_live && (k == LogicalKeyboardKey.arrowLeft || k == LogicalKeyboardKey.mediaRewind)) {
      _seek(-10);
      return KeyEventResult.handled;
    }
    if (!_live && (k == LogicalKeyboardKey.arrowRight || k == LogicalKeyboardKey.mediaFastForward)) {
      _seek(10);
      return KeyEventResult.handled;
    }
    if (isRepeat) return KeyEventResult.handled;
    if (k == LogicalKeyboardKey.select ||
        k == LogicalKeyboardKey.enter ||
        k == LogicalKeyboardKey.space ||
        k == LogicalKeyboardKey.mediaPlayPause) {
      if (_live && !_overlay && k != LogicalKeyboardKey.mediaPlayPause) {
        _showOverlay();
      } else {
        _player.playOrPause();
        _showOverlay();
      }
      return KeyEventResult.handled;
    }
    if ((k == LogicalKeyboardKey.contextMenu || k == LogicalKeyboardKey.keyS) &&
        _item.kind != ItemKind.episode) {
      setState(() => widget.onToggleFavorite(_item));
      _showOverlay();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.keyF && _desktop) {
      _toggleFullscreen();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowUp ||
        k == LogicalKeyboardKey.arrowDown ||
        k == LogicalKeyboardKey.arrowLeft ||
        k == LogicalKeyboardKey.arrowRight) {
      _showOverlay();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // ---- UI ---------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Focus(
        focusNode: _focus,
        autofocus: true,
        onKeyEvent: _onKey,
        child: MouseRegion(
          onHover: (_) => _showOverlay(),
          cursor: _overlay ? SystemMouseCursors.basic : SystemMouseCursors.none,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _overlay && _error == null && _status == null
                ? setState(() => _overlay = false)
                : _showOverlay(),
            onDoubleTap: _desktop ? _toggleFullscreen : null,
            child: Stack(
              fit: StackFit.expand,
              children: [
                Video(controller: _video, controls: NoVideoControls, fill: Colors.black),
                if (_status != null && _error == null)
                  Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const CircularProgressIndicator(),
                        const SizedBox(height: 12),
                        Text(_status!, style: const TextStyle(color: Colors.white70)),
                      ],
                    ),
                  ),
                if (_error != null) _errorBox(),
                AnimatedOpacity(
                  opacity: _overlay ? 1 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: IgnorePointer(
                    ignoring: !_overlay,
                    child: ExcludeFocus(child: _controls()),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _errorBox() => Center(
    child: Container(
      constraints: const BoxConstraints(maxWidth: 520),
      margin: const EdgeInsets.all(24),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: panel.withValues(alpha: 0.95),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(_error!, textAlign: TextAlign.center),
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            alignment: WrapAlignment.center,
            children: [
              FilledButton(
                focusNode: _retryFocus,
                onPressed: () {
                  _sourceIndex = 0;
                  _open();
                  _focus.requestFocus();
                },
                child: const Text('Retry'),
              ),
              OutlinedButton(onPressed: () => Navigator.of(context).maybePop(), child: const Text('Back')),
            ],
          ),
        ],
      ),
    ),
  );

  Widget _controls() {
    final fav = widget.isFavorite(_item);
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xCC000000), Colors.transparent, Colors.transparent, Color(0xCC000000)],
          stops: [0, 0.25, 0.7, 1],
        ),
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back),
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                  const SizedBox(width: 8),
                  Logo(_item, size: 40),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      [if (_item.number != null) '${_item.number}', _item.name].join('  '),
                      style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (_item.kind != ItemKind.episode)
                    IconButton(
                      tooltip: fav ? 'Remove from favorites' : 'Add to favorites',
                      icon: Icon(fav ? Icons.star : Icons.star_border, color: fav ? star : null),
                      onPressed: () => setState(() => widget.onToggleFavorite(_item)),
                    ),
                  if (_desktop)
                    IconButton(
                      tooltip: 'Fullscreen (F)',
                      icon: Icon(_fullscreen ? Icons.fullscreen_exit : Icons.fullscreen),
                      onPressed: _toggleFullscreen,
                    ),
                ],
              ),
              const Spacer(),
              if (!_live) _seekBar(),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (widget.items.length > 1)
                    IconButton(
                      iconSize: 32,
                      icon: const Icon(Icons.skip_previous),
                      onPressed: () => _step(-1),
                    ),
                  StreamBuilder<bool>(
                    stream: _player.stream.playing,
                    initialData: _player.state.playing,
                    builder: (_, s) => IconButton(
                      iconSize: 44,
                      icon: Icon(s.data == true ? Icons.pause_circle : Icons.play_circle),
                      onPressed: _player.playOrPause,
                    ),
                  ),
                  if (widget.items.length > 1)
                    IconButton(iconSize: 32, icon: const Icon(Icons.skip_next), onPressed: () => _step(1)),
                ],
              ),
              if (_live && widget.items.length > 1)
                const Text('▲ ▼ change channel', style: TextStyle(color: Colors.white54, fontSize: 12)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _seekBar() {
    return StreamBuilder<Duration>(
      stream: _player.stream.position,
      builder: (_, _) {
        final pos = _player.state.position;
        final dur = _player.state.duration;
        final max = dur.inMilliseconds.toDouble();
        return Row(
          children: [
            Text(_fmt(pos), style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()])),
            Expanded(
              child: Slider(
                value: max <= 0 ? 0 : pos.inMilliseconds.clamp(0, max).toDouble(),
                max: max <= 0 ? 1 : max,
                onChanged: max <= 0 ? null : (v) => _player.seek(Duration(milliseconds: v.round())),
              ),
            ),
            Text(_fmt(dur), style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()])),
          ],
        );
      },
    );
  }

  static String _fmt(Duration d) {
    final h = d.inHours, m = d.inMinutes % 60, s = d.inSeconds % 60;
    String two(int n) => n.toString().padLeft(2, '0');
    return h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
  }
}

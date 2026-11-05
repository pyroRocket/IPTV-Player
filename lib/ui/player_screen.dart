import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../epg/epg.dart';
import '../models.dart';
import '../playback.dart';
import '../sources/net.dart';
import 'theme.dart';
import 'widgets.dart';

/// Full-screen player.
///
/// Remote / keyboard:
///   Up/Down, Channel +/-   previous / next channel (live)
///   Left/Right             back / forward 10s (hold to scrub faster);
///                          on live TV this rewinds within the buffer
///   OK / Enter / Space     play-pause (shows info on live)
///   Menu / S               add or remove favorite
///   I                      show playback stats
///   F / double-click       fullscreen (desktop)
///   Back / Esc             return to list
class PlayerScreen extends StatefulWidget {
  const PlayerScreen({
    super.key,
    required this.items,
    required this.index,
    required this.isFavorite,
    required this.onToggleFavorite,
    this.playback = const PlaybackSettings(),
    this.epg,
  });

  final List<MediaItem> items;
  final int index;
  final bool Function(MediaItem) isFavorite;
  final void Function(MediaItem) onToggleFavorite;
  final PlaybackSettings playback;

  /// Guide data for "Now / Next" on live channels.
  final Epg? epg;

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  late final (Player, VideoController, Future<void>) _created = createPlayer(widget.playback);
  late final Player _player = _created.$1;
  late final VideoController _video = _created.$2;
  List<(String, String)>? _stats;
  Timer? _statsTimer;
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

  // Seeking: taps and held keys add up into one target, applied after a pause.
  Duration? _scrubTarget;
  Timer? _scrubTimer;
  DateTime? _holdStart, _lastRepeat;
  double? _dragMs; // seek bar position while dragging

  /// What can be seeked to right now (mpv's buffered range; for live TV the
  /// end is the live edge).
  (Duration, Duration)? _range;
  Timer? _rangeTimer;
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
    _configured = _created.$3;
    _open();
  }

  void _toggleStats() {
    _statsTimer?.cancel();
    if (_stats != null) {
      setState(() => _stats = null);
      return;
    }
    Future<void> refresh() async {
      final s = await playbackStats(_player);
      if (mounted) setState(() => _stats = s);
    }

    refresh();
    _statsTimer = Timer.periodic(const Duration(seconds: 1), (_) => refresh());
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _hideTimer?.cancel();
    _startTimer?.cancel();
    _zapTimer?.cancel();
    _statsTimer?.cancel();
    _scrubTimer?.cancel();
    _rangeTimer?.cancel();
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
    _watchRange();
    // Frame info (interlaced or not) is known once a couple of frames decode.
    final gen = _gen;
    Future.delayed(const Duration(milliseconds: 800), () {
      if (mounted && gen == _gen) autoDeinterlace(_player, widget.playback);
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

  /// Back/forward by [seconds]. Repeated presses (or a held key) build up
  /// a target that is applied once input pauses; holding speeds it up.
  void _nudge(int seconds, {bool repeat = false}) {
    if (!_started) return;
    final now = DateTime.now();
    if (repeat) {
      // Remotes repeat at different rates; step at most ~4 times a second and
      // speed up the longer the button is held: 10 s, then 30 s, then 60 s.
      if (_lastRepeat != null && now.difference(_lastRepeat!) < const Duration(milliseconds: 250)) return;
      _holdStart ??= now;
    } else {
      _holdStart = null;
    }
    _lastRepeat = now;
    final held = _holdStart == null ? Duration.zero : now.difference(_holdStart!);
    final mult = held > const Duration(seconds: 5) ? 6 : (held > const Duration(seconds: 2) ? 3 : 1);
    var t = (_scrubTarget ?? _player.state.position) + Duration(seconds: seconds * mult);
    final (lo, hi) = _seekBounds;
    if (t < lo) t = lo;
    if (t > hi) t = hi;
    setState(() => _scrubTarget = t);
    _showOverlay();
    _scrubTimer?.cancel();
    _scrubTimer = Timer(Duration(milliseconds: repeat ? 500 : 400), () {
      final target = _scrubTarget;
      if (target != null) _player.seek(target);
      if (mounted) setState(() => _scrubTarget = null);
    });
  }

  (Duration, Duration) get _seekBounds {
    final r = _range;
    if (_live) {
      final pos = _player.state.position;
      return r ?? (pos, pos);
    }
    final dur = _player.state.duration;
    return (Duration.zero, dur > Duration.zero ? dur : const Duration(days: 1));
  }

  Duration get _behindLive {
    final r = _range;
    if (!_live || r == null) return Duration.zero;
    final b = r.$2 - _player.state.position;
    return b.isNegative ? Duration.zero : b;
  }

  void _goLive() {
    final r = _range;
    if (r == null) return;
    _player.seek(r.$2 - const Duration(milliseconds: 500));
    _showOverlay();
  }

  /// Reads mpv's seekable cache range once a second.
  void _watchRange() {
    _rangeTimer?.cancel();
    _range = null;
    _rangeTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
      final p = _player.platform;
      if (p is! NativePlayer || !_started) return;
      (Duration, Duration)? r;
      try {
        final state = jsonDecode(await p.getProperty('demuxer-cache-state'));
        final ranges = state is Map ? state['seekable-ranges'] : null;
        if (ranges is List && ranges.isNotEmpty) {
          Duration d(num v) => Duration(milliseconds: (v * 1000).round());
          final last = ranges.last as Map;
          r = (d(ranges.first['start'] as num), d(last['end'] as num));
        }
      } catch (_) {}
      if (!mounted) return;
      if (_overlay) {
        setState(() => _range = r);
      } else {
        _range = r;
      }
    });
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

    if (k == LogicalKeyboardKey.arrowLeft || k == LogicalKeyboardKey.mediaRewind) {
      _nudge(-10, repeat: isRepeat);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowRight || k == LogicalKeyboardKey.mediaFastForward) {
      _nudge(10, repeat: isRepeat);
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
    if (k == LogicalKeyboardKey.keyI || k == LogicalKeyboardKey.info) {
      _toggleStats();
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
                if (_stats != null) _statsBox(),
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

  Widget _statsBox() => Positioned(
    top: 80,
    right: 16,
    child: IgnorePointer(
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.75),
          borderRadius: BorderRadius.circular(8),
        ),
        child: DefaultTextStyle(
          style: const TextStyle(
            fontSize: 12,
            color: Colors.white,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final (k, v) in _stats!)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 1),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 110,
                        child: Text(k, style: const TextStyle(color: Colors.white60)),
                      ),
                      Text(v),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _nowNext() {
    final now = widget.epg!.nowFor(_item);
    final next = widget.epg!.nextFor(_item);
    if (now == null && next == null) return const SizedBox();
    String t(DateTime d) => MaterialLocalizations.of(context).formatTimeOfDay(
      TimeOfDay.fromDateTime(d),
      alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
    );
    return Padding(
      padding: const EdgeInsets.only(left: 112, top: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (now != null) ...[
            Text(
              '${t(now.start)} – ${t(now.stop)}  ${now.title}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 4),
            SizedBox(
              width: 320,
              child: LinearProgressIndicator(value: now.progressAt(DateTime.now()), minHeight: 3),
            ),
          ],
          if (next != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Next  ${t(next.start)}  ${next.title}',
                style: const TextStyle(color: Colors.white70),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
      ),
    );
  }

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
                  IconButton(
                    tooltip: 'Playback stats (I)',
                    icon: const Icon(Icons.info_outline),
                    onPressed: _toggleStats,
                  ),
                  if (_desktop)
                    IconButton(
                      tooltip: 'Fullscreen (F)',
                      icon: Icon(_fullscreen ? Icons.fullscreen_exit : Icons.fullscreen),
                      onPressed: _toggleFullscreen,
                    ),
                ],
              ),
              if (_live && widget.epg != null) _nowNext(),
              const Spacer(),
              _live ? _liveBar() : _seekBar(),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    iconSize: 32,
                    tooltip: 'Back 10 seconds (←)',
                    icon: const Icon(Icons.replay_10),
                    onPressed: () => _nudge(-10),
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
                  IconButton(
                    iconSize: 32,
                    tooltip: 'Forward 10 seconds (→)',
                    icon: const Icon(Icons.forward_10),
                    onPressed: _live && _behindLive < const Duration(seconds: 2) ? null : () => _nudge(10),
                  ),
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

  static const _mono = TextStyle(fontFeatures: [FontFeature.tabularFigures()]);

  Widget _seekBar() {
    return StreamBuilder<Duration>(
      stream: _player.stream.position,
      builder: (_, _) {
        final dur = _player.state.duration;
        final max = dur.inMilliseconds.toDouble();
        final shown = _dragMs != null
            ? Duration(milliseconds: _dragMs!.round())
            : (_scrubTarget ?? _player.state.position);
        return Row(
          children: [
            Text(_fmt(shown), style: _mono),
            Expanded(
              child: Slider(
                value: max <= 0 ? 0 : shown.inMilliseconds.clamp(0, max).toDouble(),
                max: max <= 0 ? 1 : max,
                // Show where you'll land while dragging; seek once on release.
                onChanged: max <= 0
                    ? null
                    : (v) {
                        setState(() => _dragMs = v);
                        _showOverlay(sticky: true);
                      },
                onChangeEnd: max <= 0
                    ? null
                    : (v) {
                        _player.seek(Duration(milliseconds: v.round()));
                        setState(() => _dragMs = null);
                        _showOverlay();
                      },
              ),
            ),
            Text(_fmt(dur), style: _mono),
          ],
        );
      },
    );
  }

  /// Live TV: rewind within what's buffered, with a way back to live.
  Widget _liveBar() {
    return StreamBuilder<Duration>(
      stream: _player.stream.position,
      builder: (_, _) {
        final r = _range;
        final pos = _player.state.position;
        final atLive = _behindLive < const Duration(seconds: 4) && _scrubTarget == null;
        final span = r == null ? Duration.zero : r.$2 - r.$1;
        final shown = _dragMs != null ? Duration(milliseconds: _dragMs!.round()) : (_scrubTarget ?? pos);
        final behind = r == null ? Duration.zero : r.$2 - shown;
        return Row(
          children: [
            ActionChip(
              avatar: Icon(Icons.circle, size: 10, color: atLive ? const Color(0xFFFF5D5D) : Colors.white38),
              label: Text(atLive ? 'LIVE' : 'Go live'),
              onPressed: _goLive,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: r == null || span < const Duration(seconds: 5)
                  ? const SizedBox()
                  : Slider(
                      min: r.$1.inMilliseconds.toDouble(),
                      max: r.$2.inMilliseconds.toDouble(),
                      value: shown.inMilliseconds.clamp(r.$1.inMilliseconds, r.$2.inMilliseconds).toDouble(),
                      onChanged: (v) {
                        setState(() => _dragMs = v);
                        _showOverlay(sticky: true);
                      },
                      onChangeEnd: (v) {
                        _player.seek(Duration(milliseconds: v.round()));
                        setState(() => _dragMs = null);
                        _showOverlay();
                      },
                    ),
            ),
            SizedBox(
              width: 64,
              child: Text(
                atLive || behind.inSeconds < 1 ? '' : '−${_fmt(behind)}',
                textAlign: TextAlign.right,
                style: _mono,
              ),
            ),
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

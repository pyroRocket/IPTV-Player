import 'dart:async';

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

const _rowHeight = 60.0;
const _channelWidth = 220.0;
const _step = Duration(minutes: 30);

/// TV guide: channels down the side, programmes across a time grid.
///
/// Remote: arrows move between programmes (Left/Right at the edge moves the
/// time window), OK watches the channel (or shows details for a later
/// programme). P toggles the preview pane, R refreshes, S or / searches.
class GuideView extends StatefulWidget {
  const GuideView({
    super.key,
    required this.channels,
    required this.epg,
    required this.loading,
    required this.error,
    required this.onRefresh,
    required this.onPlay,
    required this.showPreview,
    required this.onTogglePreview,
    required this.playback,
  });

  final List<MediaItem> channels;
  final Epg? epg;
  final bool loading;
  final String? error;
  final VoidCallback onRefresh;

  /// Opens the full-screen player. The guide stops its preview first.
  final Future<void> Function(MediaItem item, List<MediaItem> list) onPlay;
  final bool showPreview;
  final VoidCallback onTogglePreview;
  final PlaybackSettings playback;

  @override
  State<GuideView> createState() => _GuideViewState();
}

class _GuideViewState extends State<GuideView> {
  late DateTime _start = _floor(DateTime.now());
  final _scroll = ScrollController();
  MediaItem? _selItem;
  Programme? _selProg;
  Timer? _tick;

  // Preview pane player, created only while the pane is visible.
  Player? _player;
  VideoController? _video;
  String? _previewKey;
  String? _previewError;
  Timer? _previewTimer;
  StreamSubscription? _previewErr;

  @override
  void initState() {
    super.initState();
    // Keep the "now" line and progress moving.
    _tick = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _selectFirst());
  }

  /// Start with the first channel selected so the preview pane isn't empty.
  void _selectFirst() {
    if (!mounted || _selItem != null || widget.channels.isEmpty) return;
    final first = widget.channels.first;
    _select(first, widget.epg?.nowFor(first));
  }

  @override
  void didUpdateWidget(GuideView old) {
    super.didUpdateWidget(old);
    if (!widget.showPreview && old.showPreview) _stopPreview(dispose: true);
    if (widget.showPreview && !old.showPreview && _selItem != null) _schedulePreview(_selItem!);
    if (widget.epg != old.epg && _selItem != null && _selProg == null) {
      _selProg = widget.epg?.nowFor(_selItem!);
    }
    if (_selItem == null) WidgetsBinding.instance.addPostFrameCallback((_) => _selectFirst());
  }

  @override
  void dispose() {
    _tick?.cancel();
    _previewTimer?.cancel();
    _stopPreview(dispose: true);
    _scroll.dispose();
    super.dispose();
  }

  static DateTime _floor(DateTime t) => DateTime(t.year, t.month, t.day, t.hour, t.minute >= 30 ? 30 : 0);

  int _windowMinutes(double width) {
    final m = ((width - _channelWidth) / 6).floor(); // ~6 px per minute
    return ((m ~/ 30) * 30).clamp(60, 240);
  }

  /// Moves the time window. Returns false at the edge of the guide data.
  bool _shift(Duration d) {
    final now = DateTime.now();
    final next = _start.add(d);
    if (next.isBefore(_floor(now.subtract(const Duration(hours: 3))))) return false;
    if (next.isAfter(now.add(const Duration(days: 3)))) return false;
    setState(() => _start = next);
    return true;
  }

  void _goNow() => setState(() => _start = _floor(DateTime.now()));

  // ---- selection & preview ----------------------------------------------

  void _select(MediaItem item, Programme? p) {
    if (_selItem?.key == item.key && _selProg == p) return;
    setState(() {
      _selItem = item;
      _selProg = p;
    });
    if (widget.showPreview) _schedulePreview(item);
  }

  void _schedulePreview(MediaItem item) {
    _previewTimer?.cancel();
    if (_previewKey == item.key) return;
    // Wait until focus rests, so scrolling doesn't open a stream per row.
    _previewTimer = Timer(const Duration(milliseconds: 900), () => _startPreview(item));
  }

  Future<void> _startPreview(MediaItem item) async {
    if (!mounted || !widget.showPreview || item.sources.isEmpty) return;
    if (_player == null) {
      final (p, v, ready) = createPlayer(widget.playback, preview: true);
      _player = p;
      _video = v;
      _previewErr = p.stream.error.listen((e) {
        if (e.startsWith('Failed to open') && mounted) setState(() => _previewError = 'Preview unavailable');
      });
      await ready;
    }
    setState(() {
      _previewKey = item.key;
      _previewError = null;
    });
    await _player!.open(Media(item.sources.first, httpHeaders: const {'User-Agent': userAgent}));
  }

  Future<void> _stopPreview({bool dispose = false}) async {
    _previewTimer?.cancel();
    _previewKey = null;
    final p = _player;
    if (p == null) return;
    if (dispose) {
      _previewErr?.cancel();
      _player = null;
      _video = null;
      await p.dispose();
    } else {
      await p.stop();
    }
  }

  Future<void> _play(MediaItem item) async {
    // Many accounts allow one stream at a time: free the preview first.
    await _stopPreview();
    await widget.onPlay(item, widget.channels);
    if (mounted && widget.showPreview && _selItem != null) _schedulePreview(_selItem!);
  }

  void _activate(MediaItem item, Programme? p) {
    final now = DateTime.now();
    if (p == null || !p.start.isAfter(now)) {
      _play(item);
    } else {
      _details(item, p);
    }
  }

  Future<void> _details(MediaItem item, Programme p) async {
    final watch = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(p.title),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '${item.name} · ${_dayLabel(p.start)} ${formatTime(ctx, p.start)}–${formatTime(ctx, p.stop)}',
                  style: const TextStyle(color: muted),
                ),
                if (p.description != null) ...[const SizedBox(height: 12), Text(p.description!)],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Close')),
          FilledButton(
            autofocus: true,
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Watch channel now'),
          ),
        ],
      ),
    );
    if (watch == true) _play(item);
  }

  // ---- search ------------------------------------------------------------

  Future<void> _search() async {
    final epg = widget.epg;
    if (epg == null) return;
    final picked = await showDialog<(int, MediaItem, Programme)>(
      context: context,
      builder: (_) => _SearchDialog(channels: widget.channels, epg: epg),
    );
    if (picked == null || !mounted) return;
    final (row, item, p) = picked;
    if (p.isOnAt(DateTime.now())) {
      _play(item);
      return;
    }
    setState(() => _start = _floor(p.start));
    _select(item, p);
    if (_scroll.hasClients) {
      _scroll.animateTo(
        (row * _rowHeight).clamp(0, _scroll.position.maxScrollExtent),
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    }
  }

  // ---- UI ----------------------------------------------------------------

  String _dayLabel(DateTime t) {
    final today = DateTime.now();
    final d = DateTime(t.year, t.month, t.day);
    final diff = d.difference(DateTime(today.year, today.month, today.day)).inDays;
    if (diff == 0) return 'Today';
    if (diff == 1) return 'Tomorrow';
    if (diff == -1) return 'Yesterday';
    return MaterialLocalizations.of(context).formatShortMonthDay(t);
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyP): widget.onTogglePreview,
        const SingleActivator(LogicalKeyboardKey.keyR): widget.onRefresh,
        const SingleActivator(LogicalKeyboardKey.slash): _search,
        const SingleActivator(LogicalKeyboardKey.keyN): _goNow,
      },
      child: LayoutBuilder(
        builder: (context, box) {
          final minutes = _windowMinutes(box.maxWidth);
          final end = _start.add(Duration(minutes: minutes));
          final ppm = (box.maxWidth - _channelWidth) / minutes;
          return Column(
            children: [
              _toolbar(),
              if (widget.showPreview) _previewPane(box.maxHeight),
              _timeHeader(end, ppm),
              const Divider(height: 1, color: line),
              Expanded(child: _rows(end, ppm)),
            ],
          );
        },
      ),
    );
  }

  Widget _toolbar() {
    final status = widget.loading
        ? 'Loading guide…'
        : widget.error != null
        ? widget.error!
        : widget.epg == null
        ? ''
        : '${_dayLabel(_start)} ${formatTime(context, _start)}';
    return FocusTraversalGroup(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
        child: Row(
          children: [
            IconButton(
              tooltip: 'Earlier',
              icon: const Icon(Icons.chevron_left),
              onPressed: () => _shift(-_step),
            ),
            TextButton(onPressed: _goNow, child: const Text('Now')),
            IconButton(
              tooltip: 'Later',
              icon: const Icon(Icons.chevron_right),
              onPressed: () => _shift(_step),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                status,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: widget.error != null ? const Color(0xFFFF6B6B) : muted),
              ),
            ),
            IconButton(
              tooltip: 'Search the guide',
              icon: const Icon(Icons.search),
              onPressed: widget.epg == null ? null : _search,
            ),
            IconButton(
              tooltip: widget.showPreview ? 'Hide preview' : 'Show preview',
              isSelected: widget.showPreview,
              icon: const Icon(Icons.picture_in_picture_alt_outlined),
              selectedIcon: const Icon(Icons.picture_in_picture_alt),
              onPressed: widget.onTogglePreview,
            ),
            widget.loading
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                  )
                : IconButton(
                    tooltip: 'Refresh guide',
                    icon: const Icon(Icons.refresh),
                    onPressed: widget.onRefresh,
                  ),
          ],
        ),
      ),
    );
  }

  Widget _previewPane(double maxHeight) {
    final h = (maxHeight * 0.32).clamp(150.0, 280.0);
    final item = _selItem;
    final p = _selProg;
    final now = DateTime.now();
    return Container(
      height: h,
      color: panel,
      padding: const EdgeInsets.all(12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 16 / 9,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: ColoredBox(
                color: Colors.black,
                child: _video != null && _previewKey != null && _previewError == null
                    ? Video(controller: _video!, controls: NoVideoControls, fill: Colors.black)
                    : Center(
                        child: Text(
                          _previewError ?? (item == null ? 'Select a channel' : 'Loading preview…'),
                          style: const TextStyle(color: muted),
                        ),
                      ),
              ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: item == null
                ? const SizedBox()
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(item.name, style: const TextStyle(color: muted)),
                      const SizedBox(height: 4),
                      Text(
                        p?.title ?? 'No programme information',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
                      ),
                      if (p != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          '${_dayLabel(p.start)} ${formatTime(context, p.start)} – ${formatTime(context, p.stop)}',
                          style: const TextStyle(color: muted),
                        ),
                        if (p.isOnAt(now))
                          Padding(
                            padding: const EdgeInsets.only(top: 6, right: 40),
                            child: LinearProgressIndicator(
                              value: p.progressAt(now),
                              minHeight: 3,
                              backgroundColor: line,
                            ),
                          ),
                        if (p.description != null) ...[
                          const SizedBox(height: 8),
                          Expanded(
                            child: Text(
                              p.description!,
                              overflow: TextOverflow.fade,
                              style: const TextStyle(color: Color(0xFFC5C9D2)),
                            ),
                          ),
                        ],
                      ],
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _timeHeader(DateTime end, double ppm) {
    final marks = <DateTime>[];
    for (var t = _start; t.isBefore(end); t = t.add(_step)) {
      marks.add(t);
    }
    return SizedBox(
      height: 28,
      child: Row(
        children: [
          const SizedBox(width: _channelWidth),
          Expanded(
            child: Stack(
              children: [
                for (final t in marks)
                  Positioned(
                    left: t.difference(_start).inMinutes * ppm + 6,
                    top: 6,
                    child: Text(formatTime(context, t), style: const TextStyle(color: muted, fontSize: 12)),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _rows(DateTime end, double ppm) {
    final channels = widget.channels;
    if (channels.isEmpty) return const Message(text: 'No channels in this category.');
    final now = DateTime.now();
    final nowX = now.isAfter(_start) && now.isBefore(end)
        ? now.difference(_start).inSeconds / 60 * ppm
        : null;
    return FocusTraversalGroup(
      child: ListView.builder(
        controller: _scroll,
        itemCount: channels.length,
        itemExtent: _rowHeight,
        itemBuilder: (_, i) {
          final item = channels[i];
          final progs = widget.epg?.between(item, _start, end) ?? const <Programme>[];
          return _GuideRow(
            key: ValueKey(item.key),
            item: item,
            programmes: progs,
            start: _start,
            end: end,
            ppm: ppm,
            nowX: nowX,
            autofocus: i == 0,
            selectedProgramme: _selItem?.key == item.key ? _selProg : null,
            onFocus: _select,
            onActivate: _activate,
            onPlayChannel: _play,
            onEdge: (left) => _shift(left ? -_step : _step),
          );
        },
      ),
    );
  }
}

class _GuideRow extends StatelessWidget {
  const _GuideRow({
    super.key,
    required this.item,
    required this.programmes,
    required this.start,
    required this.end,
    required this.ppm,
    required this.nowX,
    required this.autofocus,
    required this.selectedProgramme,
    required this.onFocus,
    required this.onActivate,
    required this.onPlayChannel,
    required this.onEdge,
  });

  final MediaItem item;
  final List<Programme> programmes;
  final DateTime start, end;
  final double ppm;
  final double? nowX;
  final bool autofocus;
  final Programme? selectedProgramme;
  final void Function(MediaItem, Programme?) onFocus;
  final void Function(MediaItem, Programme?) onActivate;
  final void Function(MediaItem) onPlayChannel;
  final bool Function(bool left) onEdge;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final blocks = <Widget>[];
    if (programmes.isEmpty) {
      blocks.add(
        _Block(
          key: const ValueKey('none'),
          left: 0,
          width: end.difference(start).inMinutes * ppm,
          title: 'No programme information',
          subtitle: null,
          live: true,
          autofocus: autofocus,
          onFocus: () => onFocus(item, null),
          onTap: () => onActivate(item, null),
          onKey: onEdge,
        ),
      );
    } else {
      for (var i = 0; i < programmes.length; i++) {
        final p = programmes[i];
        final s = p.start.isBefore(start) ? start : p.start;
        final e = p.stop.isAfter(end) ? end : p.stop;
        final left = s.difference(start).inSeconds / 60 * ppm;
        final width = e.difference(s).inSeconds / 60 * ppm;
        final isFirst = i == 0, isLast = i == programmes.length - 1;
        blocks.add(
          _Block(
            key: ValueKey(p.start.millisecondsSinceEpoch),
            left: left,
            width: width,
            title: p.title,
            subtitle: '${formatTime(context, p.start)} – ${formatTime(context, p.stop)}',
            live: p.isOnAt(now),
            autofocus: autofocus && (p.isOnAt(now) || (isFirst && !programmes.any((x) => x.isOnAt(now)))),
            onFocus: () => onFocus(item, p),
            onTap: () => onActivate(item, p),
            onKey: (goLeft) {
              if (goLeft && isFirst) return onEdge(true);
              if (!goLeft && isLast) return onEdge(false);
              return false;
            },
          ),
        );
      }
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: _channelWidth,
          child: Padding(
            padding: const EdgeInsets.all(2),
            child: Material(
              color: panel,
              borderRadius: BorderRadius.circular(8),
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => onPlayChannel(item),
                onFocusChange: (f) {
                  if (f) onFocus(item, programmes.where((p) => p.isOnAt(now)).firstOrNull);
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Row(
                    children: [
                      Logo(item, size: 36),
                      const SizedBox(width: 8),
                      if (item.number != null) ...[
                        Text('${item.number}', style: const TextStyle(color: muted, fontSize: 12)),
                        const SizedBox(width: 6),
                      ],
                      Expanded(child: Text(item.name, maxLines: 2, overflow: TextOverflow.ellipsis)),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        Expanded(
          child: Stack(
            clipBehavior: Clip.hardEdge,
            children: [
              ...blocks,
              if (nowX != null)
                Positioned(
                  left: nowX,
                  top: 0,
                  bottom: 0,
                  child: IgnorePointer(child: Container(width: 2, color: const Color(0xFFFF5D5D))),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Block extends StatefulWidget {
  const _Block({
    super.key,
    required this.left,
    required this.width,
    required this.title,
    required this.subtitle,
    required this.live,
    required this.autofocus,
    required this.onFocus,
    required this.onTap,
    required this.onKey,
  });

  final double left, width;
  final String title;
  final String? subtitle;
  final bool live;
  final bool autofocus;
  final VoidCallback onFocus;
  final VoidCallback onTap;

  /// Left/Right at the row's edge. Returns true if it moved the time window.
  final bool Function(bool left) onKey;

  @override
  State<_Block> createState() => _BlockState();
}

class _BlockState extends State<_Block> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: widget.left,
      width: widget.width,
      top: 2,
      bottom: 2,
      child: Padding(
        padding: const EdgeInsets.only(right: 2),
        child: Focus(
          canRequestFocus: false,
          skipTraversal: true,
          onKeyEvent: (_, e) {
            if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
            if (e.logicalKey == LogicalKeyboardKey.arrowLeft && widget.onKey(true)) {
              return KeyEventResult.handled;
            }
            if (e.logicalKey == LogicalKeyboardKey.arrowRight && widget.onKey(false)) {
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: Material(
            color: widget.live ? const Color(0xFF1C2433) : panel2,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(6),
              side: _focused ? const BorderSide(color: Colors.white, width: 2) : BorderSide.none,
            ),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              autofocus: widget.autofocus,
              onTap: widget.onTap,
              onFocusChange: (f) {
                setState(() => _focused = f);
                if (f) widget.onFocus();
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                    if (widget.subtitle != null && widget.width > 90)
                      Text(
                        widget.subtitle!,
                        maxLines: 1,
                        overflow: TextOverflow.clip,
                        style: const TextStyle(color: muted, fontSize: 11),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SearchDialog extends StatefulWidget {
  const _SearchDialog({required this.channels, required this.epg});
  final List<MediaItem> channels;
  final Epg epg;

  @override
  State<_SearchDialog> createState() => _SearchDialogState();
}

class _SearchDialogState extends State<_SearchDialog> {
  List<(int, MediaItem, Programme)> _results = const [];
  String _q = '';

  void _run(String q) {
    final query = q.trim().toLowerCase();
    final now = DateTime.now();
    final out = <(int, MediaItem, Programme)>[];
    if (query.length >= 2) {
      for (var i = 0; i < widget.channels.length; i++) {
        final c = widget.channels[i];
        for (final p in widget.epg.programmesFor(c)) {
          if (p.stop.isAfter(now) && p.title.toLowerCase().contains(query)) out.add((i, c, p));
        }
      }
      out.sort((a, b) => a.$3.start.compareTo(b.$3.start));
    }
    setState(() {
      _q = query;
      _results = out.take(200).toList();
    });
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    return AlertDialog(
      title: const Text('Search the guide'),
      contentPadding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      content: SizedBox(
        width: 520,
        height: 420,
        child: Column(
          children: [
            TextField(
              autofocus: true,
              decoration: const InputDecoration(hintText: 'Programme name', prefixIcon: Icon(Icons.search)),
              onChanged: _run,
              textInputAction: TextInputAction.search,
            ),
            const SizedBox(height: 8),
            Expanded(
              child: _results.isEmpty
                  ? Center(
                      child: Text(
                        _q.length < 2 ? 'Type at least 2 letters' : 'Nothing on your channels matches',
                        style: const TextStyle(color: muted),
                      ),
                    )
                  : ListView.builder(
                      itemCount: _results.length,
                      itemBuilder: (_, i) {
                        final (row, c, p) = _results[i];
                        final onNow = p.isOnAt(now);
                        return ListTile(
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          title: Text(p.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text(
                            '${c.name} · ${MaterialLocalizations.of(context).formatShortMonthDay(p.start)} '
                            '${formatTime(context, p.start)}',
                            style: const TextStyle(color: muted),
                          ),
                          trailing: onNow
                              ? const Text('On now', style: TextStyle(color: Color(0xFFFF5D5D)))
                              : null,
                          onTap: () => Navigator.pop(context, (row, c, p)),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
    );
  }
}

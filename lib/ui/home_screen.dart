import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../epg/epg.dart';
import '../epg/epg_service.dart';
import '../models.dart';
import '../playback.dart';
import '../sources/source.dart';
import '../storage.dart';
import 'guide_view.dart';
import 'login_screen.dart';
import 'player_screen.dart';
import 'series_screen.dart';
import 'sports_zone.dart';
import 'theme.dart';
import 'widgets.dart';

const _all = '__all';
const _fav = '__fav';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.storage, required this.profile, this.source});
  final Storage storage;
  final Profile profile;

  /// Already-connected source (from the login screen). If null we connect here.
  final IptvSource? source;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  IptvSource? _source;
  String? _error;
  Section _section = Section.live;
  final Map<Section, Catalog> _catalogs = {};
  final Map<Section, String> _errors = {};
  final Map<Section, String> _category = {};
  String _query = '';
  late Set<String> _favs = widget.storage.favorites(widget.profile);
  final _search = TextEditingController();
  final _listScroll = ScrollController();

  late Profile _profile = widget.profile;
  late PlaybackSettings _playback = widget.storage.playback;
  Epg? _epg;
  bool _epgLoading = false;
  String? _epgError;
  bool _guide = false;
  late bool _showPreview = widget.storage.guidePreview;
  Timer? _tick;
  bool _sportsPanel = false;
  double _width = 0;

  // Cache of the filtered list so rebuilds stay cheap on big catalogs.
  List<MediaItem>? _visible;
  Object? _visibleKey;

  @override
  void initState() {
    super.initState();
    if (widget.source != null) {
      _ready(widget.source!);
    } else {
      _connect();
    }
    // Keep "on now" lines current.
    _tick = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted && _epg != null) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    _search.dispose();
    _listScroll.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    setState(() => _error = null);
    try {
      _ready(await connect(widget.profile));
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  void _ready(IptvSource s) {
    setState(() {
      _source = s;
      _section = s.sections.isEmpty ? Section.live : s.sections.first;
    });
    _load(_section);
  }

  Future<void> _load(Section s) async {
    if (_catalogs.containsKey(s)) return;
    setState(() => _errors.remove(s));
    try {
      final c = await _source!.load(s);
      if (mounted) setState(() => _catalogs[s] = c);
      if (s == Section.live && _epg == null) _loadEpg();
    } catch (e) {
      if (mounted) setState(() => _errors[s] = '$e');
    }
  }

  List<String> get _epgUrls => _profile.epgUrl != null ? [_profile.epgUrl!] : _source!.epgUrls;

  Future<void> _loadEpg({bool refresh = false}) async {
    final channels = _catalogs[Section.live]?.items;
    if (_source == null || channels == null || _epgLoading) return;
    if (_epgUrls.isEmpty) {
      setState(() => _epgError = 'No guide for this playlist. Add a guide address in Account → TV guide.');
      return;
    }
    setState(() {
      _epgLoading = true;
      _epgError = null;
    });
    try {
      final epg = await EpgService.load(urls: _epgUrls, channels: channels, refresh: refresh);
      if (mounted) setState(() => _epg = epg);
    } catch (e) {
      if (mounted) setState(() => _epgError = 'Guide: $e');
    } finally {
      if (mounted) setState(() => _epgLoading = false);
    }
  }

  Future<void> _guideSettings() async {
    final c = TextEditingController(text: _profile.epgUrl ?? '');
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('TV guide'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _source!.epgUrls.isEmpty
                    ? 'This playlist doesn\'t include a guide. Paste an XMLTV guide address below.'
                    : 'Your provider\'s guide is used automatically. To use a different one, paste an '
                          'XMLTV address (.xml or .xml.gz) below.',
                style: const TextStyle(color: muted),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: c,
                autofocus: true,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  labelText: 'Guide (XMLTV) address',
                  hintText: 'Leave blank for default',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('Save and reload')),
        ],
      ),
    );
    c.dispose();
    if (result == null) return;
    _profile = _profile.withEpgUrl(result);
    await widget.storage.saveProfile(_profile);
    setState(() => _epg = null);
    _loadEpg(refresh: true);
  }

  Future<void> _playbackSettings() async {
    var s = _playback;
    final saved = await showDialog<PlaybackSettings>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: const Text('Playback'),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Video decoding', style: TextStyle(fontWeight: FontWeight.w600)),
                  RadioGroup<Decoder>(
                    groupValue: s.decoder,
                    onChanged: (v) => set(() => s = s.copyWith(decoder: v)),
                    child: Column(
                      children: [
                        for (final d in Decoder.values)
                          RadioListTile<Decoder>(value: d, title: Text(d.label), dense: true),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text('Deinterlacing', style: TextStyle(fontWeight: FontWeight.w600)),
                  RadioGroup<Deinterlace>(
                    groupValue: s.deinterlace,
                    onChanged: (v) => set(() => s = s.copyWith(deinterlace: v)),
                    child: Column(
                      children: [
                        for (final d in Deinterlace.values)
                          RadioListTile<Deinterlace>(value: d, title: Text(d.label), dense: true),
                      ],
                    ),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Smooth playback'),
                    subtitle: const Text(
                      'Uses lighter video scaling. Turn off for slightly sharper picture on a fast computer.',
                    ),
                    value: s.smoothScaling,
                    onChanged: (v) => set(() => s = s.copyWith(smoothScaling: v)),
                  ),
                  const Text(
                    'Tip: press I (or the ⓘ button) while watching to see playback stats.',
                    style: TextStyle(color: muted, fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, s), child: const Text('Save')),
          ],
        ),
      ),
    );
    if (saved == null) return;
    setState(() => _playback = saved);
    await widget.storage.setPlayback(saved);
  }

  List<MediaItem> get _liveChannels => _catalogs[Section.live]?.items ?? const [];

  SportsZone _sportsZone({VoidCallback? onClose}) => SportsZone(
    storage: widget.storage,
    channels: _liveChannels,
    epg: _epg,
    onPlay: (ch, list) => _open(ch, list),
    onClose: onClose,
  );

  /// Side panel on wide screens, full page otherwise (phones, smaller TVs).
  void _openSports() {
    _load(Section.live);
    if (_width >= 1100) {
      setState(() => _sportsPanel = !_sportsPanel);
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (ctx) => Scaffold(
          body: SafeArea(child: _sportsZone(onClose: () => Navigator.pop(ctx))),
        ),
      ),
    );
  }

  void _togglePreview() {
    setState(() => _showPreview = !_showPreview);
    widget.storage.setGuidePreview(_showPreview);
  }

  void _setSection(Section s) {
    setState(() => _section = s);
    _load(s);
    _jumpTop();
  }

  void _setCategory(String id) {
    setState(() => _category[_section] = id);
    _jumpTop();
  }

  void _jumpTop() {
    if (_listScroll.hasClients) _listScroll.jumpTo(0);
  }

  String get _cat => _category[_section] ?? _all;

  List<MediaItem> get _items {
    final c = _catalogs[_section];
    if (c == null) return const [];
    final key = (_section, _cat, _query, _favs, c);
    if (_visibleKey == key && _visible != null) return _visible!;
    Iterable<MediaItem> list = c.items;
    final q = _query.trim().toLowerCase();
    if (_cat == _fav) {
      list = list.where((i) => _favs.contains(i.key));
    } else if (_cat != _all && q.isEmpty) {
      list = list.where((i) => i.categoryId == _cat);
    }
    // Search looks across the whole section, not just the open category.
    if (q.isNotEmpty) list = list.where((i) => i.searchName.contains(q));
    _visibleKey = key;
    return _visible = list.toList(growable: false);
  }

  int get _favCount => _catalogs[_section]?.items.where((i) => _favs.contains(i.key)).length ?? 0;

  void _toggleFav(MediaItem item) {
    setState(() {
      if (!_favs.remove(item.key)) _favs.add(item.key);
      _favs = {..._favs};
    });
    widget.storage.setFavorites(widget.profile, _favs);
  }

  Future<void> _open(MediaItem item, List<MediaItem> list) async {
    if (item.kind == ItemKind.series) {
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => SeriesScreen(source: _source!, series: item),
        ),
      );
      return;
    }
    final playable = list.where((i) => i.playable).toList();
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlayerScreen(
          items: playable,
          index: playable.indexOf(item),
          isFavorite: (i) => _favs.contains(i.key),
          onToggleFavorite: _toggleFav,
          playback: _playback,
          epg: _epg,
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _signOut() async {
    await widget.storage.clearLastProfile();
    if (!mounted) return;
    Navigator.of(context)
        .pushReplacement(MaterialPageRoute(builder: (_) => LoginScreen(storage: widget.storage)));
  }

  Future<void> _openSearchDialog() async {
    final c = TextEditingController(text: _query);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Search ${_section.label}'),
        content: TextField(
          controller: c,
          autofocus: true,
          textInputAction: TextInputAction.search,
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, ''), child: const Text('Clear')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('Search')),
        ],
      ),
    );
    c.dispose();
    if (result != null) {
      setState(() => _query = result);
      _search.text = result;
      _jumpTop();
    }
  }

  // TV remotes (Fire TV) and phones: a search button instead of a
  // permanently visible text field, so moving focus doesn't pop a keyboard.
  bool get _useSearchButton => Platform.isAndroid || Platform.isIOS;

  @override
  Widget build(BuildContext context) {
    if (_source == null) {
      return Scaffold(
        body: _error == null
            ? const Center(child: CircularProgressIndicator())
            : Message(
                text: _error!,
                actions: [
                  FilledButton(autofocus: true, onPressed: _connect, child: const Text('Try again')),
                  OutlinedButton(onPressed: _signOut, child: const Text('Switch account')),
                ],
              ),
      );
    }
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyF, control: true): _openSearchDialog,
        const SingleActivator(LogicalKeyboardKey.keyF, meta: true): _openSearchDialog,
        const SingleActivator(LogicalKeyboardKey.keyG, control: true): _toggleGuide,
        const SingleActivator(LogicalKeyboardKey.keyG, meta: true): _toggleGuide,
      },
      child: Scaffold(
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, box) {
              final wide = box.maxWidth >= 720;
              _width = box.maxWidth;
              return Column(
                children: [
                  _topBar(wide),
                  const Divider(height: 1, color: line),
                  Expanded(child: wide ? _wideBody() : _narrowBody()),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _topBar(bool wide) {
    final acct = _source!.account;
    final exp = acct?.expires;
    return FocusTraversalGroup(
      child: Container(
        color: panel,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            if (wide) ...[
              const Text('IPTV', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
              const SizedBox(width: 16),
            ],
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final s in _source!.sections)
                      Padding(
                        padding: const EdgeInsets.only(right: 4),
                        child: TextButton(
                          autofocus: s == _section,
                          onPressed: () => _setSection(s),
                          style: TextButton.styleFrom(
                            backgroundColor: s == _section ? panel2 : null,
                            foregroundColor: s == _section ? Colors.white : muted,
                          ),
                          child: Text(s.label),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            if (!_useSearchButton && wide)
              SizedBox(
                width: 260,
                child: TextField(
                  controller: _search,
                  onChanged: (v) {
                    setState(() => _query = v);
                    _jumpTop();
                  },
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: 'Search ${_section.label}',
                    prefixIcon: const Icon(Icons.search, size: 20),
                  ),
                ),
              )
            else
              IconButton(tooltip: 'Search', onPressed: _openSearchDialog, icon: const Icon(Icons.search)),
            IconButton(
              tooltip: 'Sports Zone',
              isSelected: _sportsPanel,
              onPressed: _openSports,
              icon: const Icon(Icons.emoji_events_outlined),
              selectedIcon: const Icon(Icons.emoji_events, color: accent),
            ),
            if (_section == Section.live)
              IconButton(
                tooltip: _guide ? 'Channel list' : 'TV guide',
                isSelected: _guide,
                onPressed: _toggleGuide,
                icon: const Icon(Icons.calendar_view_day_outlined),
                selectedIcon: const Icon(Icons.calendar_view_day, color: accent),
              ),
            PopupMenuButton<String>(
              tooltip: 'Account',
              icon: const Icon(Icons.account_circle_outlined),
              onSelected: (v) {
                switch (v) {
                  case 'out':
                    _signOut();
                  case 'guide':
                    _guideSettings();
                  case 'playback':
                    _playbackSettings();
                }
              },
              itemBuilder: (_) => [
                PopupMenuItem(
                  enabled: false,
                  child: Text(
                    [
                      widget.profile.name,
                      if (exp != null) 'Expires ${exp.year}-${_two(exp.month)}-${_two(exp.day)}',
                      if (acct?.maxConnections != null) '${acct!.maxConnections} connection(s)',
                    ].join('\n'),
                  ),
                ),
                const PopupMenuItem(value: 'playback', child: Text('Playback settings')),
                const PopupMenuItem(value: 'guide', child: Text('TV guide settings')),
                const PopupMenuItem(value: 'out', child: Text('Switch account')),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _toggleGuide() {
    if (_section != Section.live) _setSection(Section.live);
    setState(() => _guide = !_guide);
    if (_epg == null && !_epgLoading) _loadEpg();
  }

  static String _two(int n) => n.toString().padLeft(2, '0');

  Widget _categoryTiles(Catalog c) {
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        SideTile(
          label: 'All',
          count: c.items.length,
          selected: _cat == _all,
          onTap: () => _setCategory(_all),
        ),
        SideTile(
          label: 'Favorites',
          icon: Icons.star,
          count: _favCount,
          selected: _cat == _fav,
          onTap: () => _setCategory(_fav),
        ),
        for (final cat in c.categories)
          if ((c.counts[cat.id] ?? 0) > 0)
            SideTile(
              label: cat.name,
              count: c.counts[cat.id],
              selected: _cat == cat.id,
              onTap: () => _setCategory(cat.id),
            ),
      ],
    );
  }

  Widget _wideBody() {
    final c = _catalogs[_section];
    return Row(
      children: [
        SizedBox(
          width: 260,
          child: FocusTraversalGroup(child: c == null ? const SizedBox() : _categoryTiles(c)),
        ),
        const VerticalDivider(width: 1, color: line),
        Expanded(child: FocusTraversalGroup(child: _list())),
        if (_sportsPanel && _width >= 1100) ...[
          const VerticalDivider(width: 1, color: line),
          SizedBox(width: 420, child: _sportsZone(onClose: () => setState(() => _sportsPanel = false))),
        ],
      ],
    );
  }

  Widget _narrowBody() {
    final c = _catalogs[_section];
    return Column(
      children: [
        if (c != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: DropdownButtonFormField<String>(
              isExpanded: true,
              initialValue: _cat,
              key: ValueKey((_section, _cat)),
              decoration: const InputDecoration(isDense: true),
              items: [
                DropdownMenuItem(value: _all, child: Text('All (${c.items.length})')),
                const DropdownMenuItem(value: _fav, child: Text('★ Favorites')),
                for (final cat in c.categories)
                  if ((c.counts[cat.id] ?? 0) > 0)
                    DropdownMenuItem(
                      value: cat.id,
                      child: Text('${cat.name} (${c.counts[cat.id]})', overflow: TextOverflow.ellipsis),
                    ),
              ],
              onChanged: (v) => _setCategory(v ?? _all),
            ),
          ),
        Expanded(child: _list()),
      ],
    );
  }

  Widget _list() {
    final err = _errors[_section];
    if (err != null) {
      return Message(
        text: err,
        actions: [FilledButton(onPressed: () => _load(_section), child: const Text('Try again'))],
      );
    }
    if (!_catalogs.containsKey(_section)) {
      return const Message(text: 'Loading…');
    }
    final items = _items;
    if (_section == Section.live && _guide) {
      return GuideView(
        channels: items,
        epg: _epg,
        loading: _epgLoading,
        error: _epgError,
        onRefresh: () => _loadEpg(refresh: true),
        onPlay: (it, list) => _open(it, list),
        showPreview: _showPreview,
        onTogglePreview: _togglePreview,
        playback: _playback,
      );
    }
    final now = DateTime.now();
    return Column(
      children: [
        if (_query.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text('Results for "$_query"', style: const TextStyle(color: muted)),
                ),
                TextButton(
                  onPressed: () {
                    setState(() => _query = '');
                    _search.clear();
                  },
                  child: const Text('Clear search'),
                ),
              ],
            ),
          ),
        Expanded(
          child: items.isEmpty
              ? Message(
                  text: _cat == _fav && _query.isEmpty
                      ? 'No favorites yet. Use the ☆ next to anything to add it.'
                      : 'Nothing here.',
                )
              : ListView.builder(
                  controller: _listScroll,
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  itemCount: items.length,
                  itemExtent: 60,
                  itemBuilder: (_, i) {
                    final it = items[i];
                    final on = it.kind == ItemKind.live ? _epg?.nowFor(it, now) : null;
                    return ItemTile(
                      item: it,
                      subtitle: on?.title,
                      progress: on?.progressAt(now),
                      favorite: _favs.contains(it.key),
                      onTap: () => _open(it, items),
                      onFavorite: () => _toggleFav(it),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

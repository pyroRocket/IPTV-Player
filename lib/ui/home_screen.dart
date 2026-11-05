import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models.dart';
import '../sources/source.dart';
import '../storage.dart';
import 'login_screen.dart';
import 'player_screen.dart';
import 'series_screen.dart';
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
  }

  @override
  void dispose() {
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
    } catch (e) {
      if (mounted) setState(() => _errors[s] = '$e');
    }
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
      },
      child: Scaffold(
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, box) {
              final wide = box.maxWidth >= 720;
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
            PopupMenuButton<String>(
              tooltip: 'Account',
              icon: const Icon(Icons.account_circle_outlined),
              onSelected: (v) {
                if (v == 'out') _signOut();
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
                const PopupMenuItem(value: 'out', child: Text('Switch account')),
              ],
            ),
          ],
        ),
      ),
    );
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
                    return ItemTile(
                      item: it,
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

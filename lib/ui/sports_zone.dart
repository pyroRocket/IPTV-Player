import 'dart:async';

import 'package:flutter/material.dart';

import '../epg/epg.dart';
import '../models.dart';
import '../sports/espn.dart';
import '../sports/leagues.dart';
import '../sports/matching.dart';
import '../storage.dart';
import 'theme.dart';
import 'widgets.dart';

/// Live scores and upcoming fixtures for chosen sports and teams, with the
/// channels in your playlist that are showing each one.
class SportsZone extends StatefulWidget {
  const SportsZone({
    super.key,
    required this.storage,
    required this.channels,
    required this.epg,
    required this.onPlay,
    this.onClose,
  });

  final Storage storage;

  /// Live TV channels from the playlist (empty until loaded).
  final List<MediaItem> channels;
  final Epg? epg;
  final Future<void> Function(MediaItem channel, List<MediaItem> list) onPlay;

  /// Shown as a close button when used as a side panel.
  final VoidCallback? onClose;

  @override
  State<SportsZone> createState() => _SportsZoneState();
}

class _SportsZoneState extends State<SportsZone> {
  late List<String> _sports = widget.storage.sportsSelected;
  late Map<String, List<String>> _leagueFilter = widget.storage.sportsLeagueFilter;
  late List<Team> _teams = widget.storage.sportsTeams;
  late bool _teamsOnly = widget.storage.sportsTeamsOnly;
  bool _results = false;
  final Set<String> _sportFilter = {};

  List<SportEvent> _events = const [];
  final Map<String, String> _errors = {};
  bool _loading = false;
  DateTime? _updated;
  Timer? _timer;
  SportsMatcher? _matcher;

  /// Every competition of each chosen sport, unless that sport was narrowed.
  List<League> get _leagues => [
    for (final sport in _sports)
      for (final l in leagues.where((l) => l.sport == sport))
        if (_leagueFilter[sport] == null || _leagueFilter[sport]!.contains(l.path)) l,
  ];
  Set<String> get _teamKeys => {for (final t in _teams) t.key};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(SportsZone old) {
    super.didUpdateWidget(old);
    if (old.channels != widget.channels || old.epg != widget.epg) _matcher = null;
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  SportsMatcher get _match => _matcher ??= SportsMatcher(widget.channels, widget.epg);

  Future<void> _load() async {
    if (_loading) return;
    final leagues = _leagues;
    setState(() => _loading = true);
    final now = DateTime.now();
    final from = now.subtract(const Duration(days: 2));
    final to = now.add(const Duration(days: 7));
    final results = await Future.wait(
      leagues.map((l) async {
        try {
          return (l, await fetchEvents(l, from, to), null);
        } catch (e) {
          return (l, const <SportEvent>[], '$e');
        }
      }),
    );
    if (!mounted) return;
    final all = <SportEvent>[];
    _errors.clear();
    for (final (l, events, err) in results) {
      all.addAll(events);
      if (err != null) _errors[l.name] = err;
    }
    setState(() {
      _events = all;
      _loading = false;
      _updated = DateTime.now();
    });
    _schedule();
  }

  /// Refresh every minute while something is live, otherwise every 10 minutes.
  void _schedule() {
    _timer?.cancel();
    final live = _events.any((e) => e.state == EventState.live);
    _timer = Timer(Duration(minutes: live ? 1 : 10), _load);
  }

  // ---- settings ----------------------------------------------------------

  Future<void> _pickSports() async {
    final result = await showDialog<(List<String>, Map<String, List<String>>)>(
      context: context,
      builder: (_) => _SportPicker(sports: _sports, filter: _leagueFilter),
    );
    if (result == null) return;
    final (sports, filter) = result;
    setState(() {
      _sports = sports;
      _leagueFilter = filter;
      _sportFilter.removeWhere((s) => !sports.contains(s));
    });
    await widget.storage.setSportsSelected(sports);
    await widget.storage.setSportsLeagueFilter(filter);
    _load();
  }

  Future<void> _manageTeams() async {
    final result = await showDialog<List<Team>>(
      context: context,
      builder: (_) => _TeamPicker(leagues: _leagues, selected: _teams),
    );
    if (result == null) return;
    setState(() => _teams = result);
    await widget.storage.setSportsTeams(result);
  }

  void _setTeamsOnly(bool v) {
    setState(() => _teamsOnly = v);
    widget.storage.setSportsTeamsOnly(v);
  }

  // ---- filtering ---------------------------------------------------------

  /// Sports that have no followed teams; hidden in "followed teams only".
  List<String> get _sportsWithoutTeams {
    final withTeams = {for (final t in _teams) t.sportKey};
    return {
      for (final l in _leagues)
        if (!withTeams.contains(l.sportKey)) l.sport,
    }.toList();
  }

  List<SportEvent> get _visible {
    final keys = _teamKeys;
    var list = _events.where(
      (e) => _results ? e.state == EventState.finished : e.state != EventState.finished,
    );
    if (_sportFilter.isNotEmpty) list = list.where((e) => _sportFilter.contains(e.league.sport));
    if (_teamsOnly) list = list.where((e) => e.involves(keys));
    final out = list.toList();
    out.sort((a, b) {
      if (!_results) {
        final la = a.state == EventState.live ? 0 : 1, lb = b.state == EventState.live ? 0 : 1;
        if (la != lb) return la - lb;
        final fa = a.involves(keys) ? 0 : 1, fb = b.involves(keys) ? 0 : 1;
        if (a.start.day == b.start.day && fa != fb) return fa - fb;
        return a.start.compareTo(b.start);
      }
      return b.start.compareTo(a.start);
    });
    return out;
  }

  String _dayLabel(DateTime t) {
    final now = DateTime.now();
    final diff = DateTime(t.year, t.month, t.day).difference(DateTime(now.year, now.month, now.day)).inDays;
    if (diff == 0) return 'Today';
    if (diff == 1) return 'Tomorrow';
    if (diff == -1) return 'Yesterday';
    return MaterialLocalizations.of(context).formatMediumDate(t);
  }

  // ---- UI ----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final events = _visible;
    final rows = <Widget>[];
    String? day;
    for (final e in events) {
      final d = e.state == EventState.live ? 'Live now' : _dayLabel(e.start);
      if (d != day) {
        day = d;
        rows.add(
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 16, 4, 6),
            child: Text(
              d,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: d == 'Live now' ? const Color(0xFFFF5D5D) : null,
              ),
            ),
          ),
        );
      }
      rows.add(
        _EventCard(
          event: e,
          followed: e.involves(_teamKeys),
          matches: _match.channelsFor(e),
          onPlay: (m, all) => widget.onPlay(m.channel, all.map((x) => x.channel).toList()),
        ),
      );
    }

    return FocusTraversalGroup(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
              children: [
                _tabs(),
                const SizedBox(height: 12),
                _teamsCard(),
                const SizedBox(height: 10),
                _sportChips(),
                if (_errors.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Text(
                      'Couldn\'t load ${_errors.keys.join(', ')}: ${_errors.values.first}',
                      style: const TextStyle(color: Color(0xFFFF6B6B), fontSize: 12),
                    ),
                  ),
                if (_sports.isEmpty)
                  Message(
                    text: 'Pick the sports you follow.',
                    actions: [FilledButton(onPressed: _pickSports, child: const Text('Pick sports'))],
                  )
                else if (events.isEmpty && !_loading)
                  Message(
                    text: _results
                        ? 'No recent results.'
                        : _teamsOnly
                        ? 'Nothing coming up for your teams in the next week.'
                        : 'Nothing scheduled in the next week.',
                  )
                else if (events.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(32),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                ...rows,
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _header() => Container(
    color: panel,
    padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
    child: Row(
      children: [
        const Icon(Icons.emoji_events_outlined),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Sports Zone', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              Text(
                _loading
                    ? 'Updating…'
                    : _updated == null
                    ? 'Live scores and what\'s on'
                    : 'Updated ${formatTime(context, _updated!)}',
                style: const TextStyle(color: muted, fontSize: 12),
              ),
            ],
          ),
        ),
        OutlinedButton(onPressed: _pickSports, child: const Text('Pick sports')),
        const SizedBox(width: 4),
        IconButton(tooltip: 'Refresh', onPressed: _loading ? null : _load, icon: const Icon(Icons.refresh)),
        if (widget.onClose != null)
          IconButton(tooltip: 'Close', onPressed: widget.onClose, icon: const Icon(Icons.close)),
      ],
    ),
  );

  Widget _tabs() => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: SegmentedButton<bool>(
      segments: [
        ButtonSegment(
          value: false,
          label: Text(
            _events.any((e) => e.state == EventState.live) ? 'Live & upcoming  •' : 'Live & upcoming',
          ),
        ),
        const ButtonSegment(value: true, label: Text('Results')),
      ],
      selected: {_results},
      showSelectedIcon: false,
      onSelectionChanged: (s) => setState(() => _results = s.first),
    ),
  );

  Widget _teamsCard() {
    final hidden = _teamsOnly ? _sportsWithoutTeams : const <String>[];
    final sports = {for (final t in _teams) t.sportKey}.length;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: panel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _teamsOnly ? accent.withValues(alpha: 0.5) : line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text('Followed teams only', style: TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text(
              _teams.isEmpty
                  ? 'Follow teams to see just their games.'
                  : '${_teams.length} team${_teams.length == 1 ? '' : 's'} across $sports sport${sports == 1 ? '' : 's'}',
              style: const TextStyle(color: muted),
            ),
            value: _teamsOnly,
            onChanged: _teams.isEmpty ? null : _setTeamsOnly,
          ),
          if (_teams.isNotEmpty)
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final t in _teams.take(6))
                  Chip(
                    avatar: t.logo == null ? null : Image.network(t.logo!, width: 18, height: 18),
                    label: Text(t.shortName ?? t.name),
                    visualDensity: VisualDensity.compact,
                  ),
                if (_teams.length > 6)
                  Chip(label: Text('+${_teams.length - 6}'), visualDensity: VisualDensity.compact),
              ],
            ),
          if (hidden.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Hidden (no teams followed): ${hidden.join(', ')}',
                style: const TextStyle(color: Color(0xFFE8C36A), fontSize: 12),
              ),
            ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: _leagues.isEmpty ? null : _manageTeams,
              child: const Text('Manage teams'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sportChips() {
    final sports = {for (final l in _leagues) l.sport}.toList();
    if (sports.length < 2) return const SizedBox();
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final s in sports)
          FilterChip(
            label: Text(s),
            selected: _sportFilter.contains(s),
            onSelected: (v) => setState(() => v ? _sportFilter.add(s) : _sportFilter.remove(s)),
          ),
      ],
    );
  }
}

class _EventCard extends StatelessWidget {
  const _EventCard({
    required this.event,
    required this.followed,
    required this.matches,
    required this.onPlay,
  });

  final SportEvent event;
  final bool followed;
  final List<ChannelMatch> matches;
  final void Function(ChannelMatch, List<ChannelMatch>) onPlay;

  @override
  Widget build(BuildContext context) {
    final e = event;
    final live = e.state == EventState.live;
    final showScore = e.state != EventState.upcoming;
    final unmatched = e.broadcasts.where((b) => !matches.any((m) => m.viaBroadcaster == b)).toList();
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: panel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: live ? const Color(0x88FF5D5D) : line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (followed)
                const Padding(
                  padding: EdgeInsets.only(right: 4),
                  child: Icon(Icons.star, size: 14, color: star),
                ),
              Expanded(
                child: Text(e.league.name, style: const TextStyle(color: muted, fontSize: 12)),
              ),
              _StatusBadge(event: e),
            ],
          ),
          const SizedBox(height: 8),
          if (e.isTeamEvent)
            for (final c in e.competitors)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    SizedBox(
                      width: 26,
                      height: 26,
                      child: c.logo == null
                          ? const Icon(Icons.shield_outlined, size: 20, color: muted)
                          : Image.network(c.logo!, errorBuilder: (_, _, _) => const SizedBox()),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        c.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: c.winner ? FontWeight.w700 : FontWeight.w500,
                        ),
                      ),
                    ),
                    if (showScore)
                      Text(
                        c.score ?? '-',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          fontFeatures: const [FontFeature.tabularFigures()],
                          color: e.state == EventState.finished && !c.winner ? muted : null,
                        ),
                      ),
                  ],
                ),
              )
          else
            Text(e.name, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          if (e.venue != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(e.venue!, style: const TextStyle(color: muted, fontSize: 12)),
            ),
          if (e.state != EventState.finished) ...[
            const SizedBox(height: 10),
            if (matches.isNotEmpty) ...[
              Text(
                'On your channels (${matches.length})',
                style: const TextStyle(color: muted, fontSize: 12),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final m in matches)
                    ActionChip(
                      avatar: const Icon(Icons.play_arrow, size: 16),
                      label: Text(m.channel.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                      tooltip: m.programme?.title ?? 'Broadcast on ${m.viaBroadcaster}',
                      onPressed: () => onPlay(m, matches),
                    ),
                ],
              ),
            ] else
              const Text('Not found on your channels yet', style: TextStyle(color: muted, fontSize: 12)),
            if (unmatched.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  'Broadcast: ${unmatched.take(8).join(', ')}',
                  style: const TextStyle(color: muted, fontSize: 12),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.event});
  final SportEvent event;

  @override
  Widget build(BuildContext context) {
    final (text, color) = switch (event.state) {
      EventState.live => ('LIVE  ${event.status}', const Color(0xFFFF5D5D)),
      EventState.finished => (event.status.isEmpty ? 'Final' : event.status, muted),
      EventState.upcoming => (formatTime(context, event.start), Colors.white),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: event.state == EventState.live ? const Color(0x33FF5D5D) : panel2,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600),
      ),
    );
  }
}

/// Follow or unfollow teams, one competition at a time.
class _TeamPicker extends StatefulWidget {
  const _TeamPicker({required this.leagues, required this.selected});
  final List<League> leagues;
  final List<Team> selected;

  @override
  State<_TeamPicker> createState() => _TeamPickerState();
}

class _TeamPickerState extends State<_TeamPicker> {
  late final List<Team> _chosen = [...widget.selected];
  late League _league = widget.leagues.first;
  final Map<String, Future<List<Team>>> _teams = {};
  String _q = '';

  Future<List<Team>> get _list => _teams.putIfAbsent(_league.path, () => fetchTeams(_league));

  bool _has(Team t) => _chosen.any((x) => x.key == t.key);

  void _toggle(Team t) => setState(() {
    if (_has(t)) {
      _chosen.removeWhere((x) => x.key == t.key);
    } else {
      _chosen.add(t);
    }
  });

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Manage teams'),
      content: SizedBox(
        width: 460,
        height: 520,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_chosen.isNotEmpty) ...[
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final t in _chosen)
                    InputChip(
                      label: Text(t.shortName ?? t.name),
                      onDeleted: () => _toggle(t),
                      visualDensity: VisualDensity.compact,
                    ),
                ],
              ),
              const SizedBox(height: 10),
            ],
            DropdownButtonFormField<League>(
              initialValue: _league,
              isExpanded: true,
              decoration: const InputDecoration(isDense: true, labelText: 'Competition'),
              items: [for (final l in widget.leagues) DropdownMenuItem(value: l, child: Text(l.name))],
              onChanged: (l) => setState(() => _league = l ?? _league),
            ),
            const SizedBox(height: 8),
            TextField(
              decoration: const InputDecoration(
                isDense: true,
                hintText: 'Search teams',
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: (v) => setState(() => _q = v.trim().toLowerCase()),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: FutureBuilder<List<Team>>(
                future: _list,
                builder: (_, snap) {
                  if (snap.hasError) return Message(text: 'Couldn\'t load teams: ${snap.error}');
                  if (!snap.hasData) return const Center(child: CircularProgressIndicator());
                  final teams = snap.data!
                      .where((t) => _q.isEmpty || t.name.toLowerCase().contains(_q))
                      .toList();
                  return ListView.builder(
                    itemCount: teams.length,
                    itemBuilder: (_, i) {
                      final t = teams[i];
                      return CheckboxListTile(
                        dense: true,
                        secondary: t.logo == null ? null : Image.network(t.logo!, width: 24, height: 24),
                        title: Text(t.name),
                        value: _has(t),
                        onChanged: (_) => _toggle(t),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, _chosen), child: const Text('Save')),
      ],
    );
  }
}

/// Choose sports; optionally narrow each one to particular competitions.
class _SportPicker extends StatefulWidget {
  const _SportPicker({required this.sports, required this.filter});
  final List<String> sports;
  final Map<String, List<String>> filter;

  @override
  State<_SportPicker> createState() => _SportPickerState();
}

class _SportPickerState extends State<_SportPicker> {
  late final Set<String> _sports = {...widget.sports};
  late final Map<String, Set<String>> _filter = {
    for (final e in widget.filter.entries) e.key: {...e.value},
  };
  final Set<String> _expanded = {};

  List<League> _of(String sport) => leagues.where((l) => l.sport == sport).toList();

  bool _on(String sport, League l) => _filter[sport]?.contains(l.path) ?? true;

  void _toggleLeague(String sport, League l, bool on) => setState(() {
    final all = _of(sport).map((x) => x.path).toSet();
    final set = _filter[sport] ?? {...all};
    if (!on && set.length == 1 && set.contains(l.path)) return; // keep at least one
    on ? set.add(l.path) : set.remove(l.path);
    // All ticked means "every competition": no filter.
    if (set.length == all.length) {
      _filter.remove(sport);
    } else {
      _filter[sport] = set;
    }
  });

  String _summary(String sport) {
    final f = _filter[sport];
    final n = _of(sport).length;
    return f == null ? 'All competitions' : '${f.length} of $n competitions';
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Pick sports'),
      content: SizedBox(
        width: 440,
        height: 500,
        child: ListView(
          children: [
            for (final sport in sportGroups) ...[
              CheckboxListTile(
                title: Text(sport, style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: _sports.contains(sport)
                    ? Text(_summary(sport), style: const TextStyle(color: muted))
                    : null,
                value: _sports.contains(sport),
                onChanged: (v) => setState(() {
                  v == true ? _sports.add(sport) : _sports.remove(sport);
                  if (v != true) _expanded.remove(sport);
                }),
              ),
              if (_sports.contains(sport) && _of(sport).length > 1)
                Padding(
                  padding: const EdgeInsets.only(left: 16),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: () => setState(
                        () => _expanded.contains(sport) ? _expanded.remove(sport) : _expanded.add(sport),
                      ),
                      icon: Icon(_expanded.contains(sport) ? Icons.expand_less : Icons.expand_more, size: 18),
                      label: Text(_expanded.contains(sport) ? 'Done' : 'Choose competitions (optional)'),
                    ),
                  ),
                ),
              if (_expanded.contains(sport))
                for (final l in _of(sport))
                  Padding(
                    padding: const EdgeInsets.only(left: 24),
                    child: CheckboxListTile(
                      dense: true,
                      title: Text(l.name),
                      value: _on(sport, l),
                      onChanged: (v) => _toggleLeague(sport, l, v == true),
                    ),
                  ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () => Navigator.pop(context, (
            [
              for (final s in sportGroups)
                if (_sports.contains(s)) s,
            ],
            {
              for (final e in _filter.entries)
                if (_sports.contains(e.key)) e.key: e.value.toList(),
            },
          )),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

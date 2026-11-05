import 'package:flutter/material.dart';

import '../models.dart';
import '../sources/source.dart';
import 'player_screen.dart';
import 'theme.dart';
import 'widgets.dart';

/// Seasons and episodes of an Xtream series.
class SeriesScreen extends StatefulWidget {
  const SeriesScreen({super.key, required this.source, required this.series});
  final IptvSource source;
  final MediaItem series;

  @override
  State<SeriesScreen> createState() => _SeriesScreenState();
}

class _SeriesScreenState extends State<SeriesScreen> {
  List<Season>? _seasons;
  String? _error;
  int _season = 0;
  final Set<String> _watched = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final s = await widget.source.seasons(widget.series);
      if (mounted) setState(() => _seasons = s.where((x) => x.episodes.isNotEmpty).toList());
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(backgroundColor: panel, title: Text(widget.series.name)),
      body: _body(),
    );
  }

  Widget _body() {
    if (_error != null) {
      return Message(
        text: _error!,
        actions: [FilledButton(autofocus: true, onPressed: _load, child: const Text('Try again'))],
      );
    }
    final seasons = _seasons;
    if (seasons == null) return const Center(child: CircularProgressIndicator());
    if (seasons.isEmpty) return const Message(text: 'No episodes available.');
    final eps = seasons[_season].episodes;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FocusTraversalGroup(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                for (var i = 0; i < seasons.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text('Season ${seasons[i].number}'),
                      selected: i == _season,
                      onSelected: (_) => setState(() => _season = i),
                    ),
                  ),
              ],
            ),
          ),
        ),
        Expanded(
          child: FocusTraversalGroup(
            child: ListView.builder(
              itemCount: eps.length,
              itemExtent: 60,
              itemBuilder: (_, i) => ItemTile(
                item: eps[i],
                autofocus: i == 0,
                favorite: false,
                playing: _watched.contains(eps[i].key),
                onFavorite: null,
                onTap: () {
                  setState(() => _watched.add(eps[i].key));
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => PlayerScreen(
                        items: eps,
                        index: i,
                        isFavorite: (_) => false,
                        onToggleFavorite: (_) {},
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ],
    );
  }
}

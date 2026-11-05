import 'package:flutter/material.dart';

import '../models.dart';
import 'theme.dart';

/// Channel logo / poster with a letter fallback when there's no image.
class Logo extends StatelessWidget {
  const Logo(this.item, {super.key, this.size = 44});
  final MediaItem item;
  final double size;

  @override
  Widget build(BuildContext context) {
    final letter = item.name.isEmpty ? '?' : item.name.characters.first.toUpperCase();
    final fallback = Center(
      child: Text(
        letter,
        style: TextStyle(color: muted, fontSize: size * 0.4, fontWeight: FontWeight.w600),
      ),
    );
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: panel2, borderRadius: BorderRadius.circular(8)),
      clipBehavior: Clip.antiAlias,
      child: item.logo == null
          ? fallback
          : Image.network(
              item.logo!,
              fit: BoxFit.contain,
              cacheWidth: (size * 2).round(),
              errorBuilder: (_, _, _) => fallback,
            ),
    );
  }
}

/// A list row that works with mouse, touch and TV remote.
class ItemTile extends StatelessWidget {
  const ItemTile({
    super.key,
    required this.item,
    required this.favorite,
    required this.onTap,
    required this.onFavorite,
    this.autofocus = false,
    this.playing = false,
  });

  final MediaItem item;
  final bool favorite;
  final bool playing;
  final bool autofocus;
  final VoidCallback onTap;
  final VoidCallback? onFavorite;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Row(
        children: [
          Expanded(
            child: Material(
              color: playing ? panel2 : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
              child: InkWell(
                autofocus: autofocus,
                borderRadius: BorderRadius.circular(10),
                onTap: onTap,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  child: Row(
                    children: [
                      Logo(item),
                      const SizedBox(width: 12),
                      if (item.number != null) ...[
                        SizedBox(
                          width: 44,
                          child: Text('${item.number}', style: const TextStyle(color: muted)),
                        ),
                      ],
                      Expanded(child: Text(item.name, maxLines: 2, overflow: TextOverflow.ellipsis)),
                      if (item.kind == ItemKind.series) const Icon(Icons.chevron_right, color: muted),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (onFavorite != null)
            IconButton(
              tooltip: favorite ? 'Remove from favorites' : 'Add to favorites',
              onPressed: onFavorite,
              icon: Icon(favorite ? Icons.star : Icons.star_border, color: favorite ? star : muted),
            ),
        ],
      ),
    );
  }
}

/// Selectable row for the category sidebar.
class SideTile extends StatelessWidget {
  const SideTile({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.count,
    this.icon,
    this.autofocus = false,
  });
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final int? count;
  final IconData? icon;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      child: Material(
        color: selected ? panel2 : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          autofocus: autofocus,
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 18, color: selected ? star : muted),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: selected ? Colors.white : const Color(0xFFC5C9D2)),
                  ),
                ),
                if (count != null) Text('$count', style: const TextStyle(color: muted, fontSize: 12)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class Message extends StatelessWidget {
  const Message({super.key, required this.text, this.actions = const []});
  final String text;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            text,
            textAlign: TextAlign.center,
            style: const TextStyle(color: muted),
          ),
          if (actions.isNotEmpty) ...[const SizedBox(height: 16), Wrap(spacing: 12, children: actions)],
        ],
      ),
    ),
  );
}

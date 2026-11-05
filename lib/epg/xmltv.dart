import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:xml/xml_events.dart';

import 'epg.dart';

/// What the parser should keep, so a 200 MB guide doesn't fill memory.
class EpgFilter {
  const EpgFilter({this.ids = const {}, this.names = const {}, required this.from, required this.to});

  /// XMLTV ids and normalized names of the playlist's channels. Empty = keep all.
  final Set<String> ids;
  final Set<String> names;
  final DateTime from;
  final DateTime to;

  bool get keepAll => ids.isEmpty && names.isEmpty;
}

/// Streams XMLTV from [file] (plain or gzip) and returns the kept programmes.
Future<Epg> parseXmltvFile(String path, EpgFilter filter) async {
  final file = File(path);
  final head = await file.openRead(0, 2).fold<List<int>>([], (a, b) => a..addAll(b));
  Stream<List<int>> bytes = file.openRead();
  if (head.length == 2 && head[0] == 0x1f && head[1] == 0x8b) bytes = bytes.transform(gzip.decoder);
  return parseXmltv(bytes.transform(const Utf8Decoder(allowMalformed: true)), filter);
}

Future<Epg> parseXmltv(Stream<String> text, EpgFilter filter) async {
  final byChannel = <String, List<Programme>>{};
  final idByName = <String, String>{};
  final keepIds = <String>{...filter.ids};
  final lowerIds = {for (final i in filter.ids) i.toLowerCase()};

  String? channelId;
  // Current programme being read.
  String? pChannel;
  DateTime? pStart, pStop;
  String? pTitle, pDesc;
  String? field; // 'name' | 'title' | 'desc'
  final buf = StringBuffer();

  await for (final events in text.toXmlEvents()) {
    for (final e in events) {
      if (e is XmlStartElementEvent) {
        switch (e.name) {
          case 'channel':
            channelId = _attr(e, 'id');
          case 'display-name':
            if (channelId != null && !e.isSelfClosing) {
              field = 'name';
              buf.clear();
            }
          case 'programme':
            pChannel = _attr(e, 'channel');
            pStart = parseXmltvTime(_attr(e, 'start'));
            pStop = parseXmltvTime(_attr(e, 'stop'));
            pTitle = pDesc = null;
          case 'title' || 'desc':
            if (pChannel != null && !e.isSelfClosing) {
              field = e.name;
              buf.clear();
            }
        }
      } else if (e is XmlTextEvent) {
        if (field != null) buf.write(e.value);
      } else if (e is XmlCDATAEvent) {
        if (field != null) buf.write(e.value);
      } else if (e is XmlEndElementEvent) {
        switch (e.name) {
          case 'display-name':
            if (field == 'name' && channelId != null) {
              final n = normalizeChannelName(buf.toString());
              if (n.isNotEmpty) {
                idByName.putIfAbsent(n, () => channelId!);
                if (filter.names.contains(n)) keepIds.add(channelId);
              }
              if (lowerIds.contains(channelId.toLowerCase())) keepIds.add(channelId);
            }
            field = null;
          case 'channel':
            channelId = null;
          case 'title':
            if (field == 'title') pTitle ??= buf.toString().trim();
            field = null;
          case 'desc':
            if (field == 'desc') pDesc ??= buf.toString().trim();
            field = null;
          case 'programme':
            final c = pChannel, s = pStart, t = pStop;
            if (c != null &&
                s != null &&
                t != null &&
                t.isAfter(filter.from) &&
                s.isBefore(filter.to) &&
                (filter.keepAll || keepIds.contains(c))) {
              (byChannel[c] ??= []).add(
                Programme(
                  channel: c,
                  start: s,
                  stop: t,
                  title: (pTitle == null || pTitle.isEmpty) ? 'Untitled' : pTitle,
                  description: (pDesc == null || pDesc.isEmpty) ? null : pDesc,
                ),
              );
            }
            pChannel = null;
        }
      }
    }
  }
  for (final list in byChannel.values) {
    list.sort((a, b) => a.start.compareTo(b.start));
  }
  // Only keep name lookups for channels that have programmes.
  idByName.removeWhere((_, id) => !byChannel.containsKey(id));
  return Epg(byChannel, idByName);
}

String? _attr(XmlStartElementEvent e, String name) {
  for (final a in e.attributes) {
    if (a.name == name) return a.value;
  }
  return null;
}

final _time = RegExp(r'^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})?\s*([+-]\d{2}):?(\d{2})?');

/// Parses XMLTV times like "20261105183000 +0100" into local time.
DateTime? parseXmltvTime(String? s) {
  if (s == null) return null;
  final m = _time.firstMatch(s.trim());
  if (m == null) {
    final digits = RegExp(r'^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})?').firstMatch(s.trim());
    if (digits == null) return null;
    int g(int i) => int.parse(digits.group(i) ?? '0');
    return DateTime.utc(g(1), g(2), g(3), g(4), g(5), g(6)).toLocal();
  }
  int g(int i) => int.parse(m.group(i) ?? '0');
  final utc = DateTime.utc(g(1), g(2), g(3), g(4), g(5), g(6));
  final sign = m.group(7)!.startsWith('-') ? -1 : 1;
  final offset = Duration(hours: int.parse(m.group(7)!.substring(1)), minutes: g(8));
  return utc.subtract(offset * sign).toLocal();
}

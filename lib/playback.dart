import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'sources/net.dart';

enum Decoder { hardware, hardwareCopy, software }

enum Deinterlace { auto, on, off }

extension DecoderLabel on Decoder {
  String get label => switch (this) {
    Decoder.hardware => 'Hardware (fastest)',
    Decoder.hardwareCopy => 'Hardware, compatibility mode',
    Decoder.software => 'Software (uses more CPU)',
  };
  String get hwdec => switch (this) {
    Decoder.hardware => 'auto-safe',
    Decoder.hardwareCopy => 'auto-copy',
    Decoder.software => 'no',
  };
}

extension DeinterlaceLabel on Deinterlace {
  String get label => switch (this) {
    Deinterlace.auto => 'Automatic (only interlaced channels)',
    Deinterlace.on => 'Always',
    Deinterlace.off => 'Off',
  };
}

/// Player options the user can change in Settings → Playback.
class PlaybackSettings {
  const PlaybackSettings({
    this.decoder = Decoder.hardware,
    this.deinterlace = Deinterlace.auto,
    this.smoothScaling = true,
  });

  final Decoder decoder;
  final Deinterlace deinterlace;

  /// Use cheap video scaling. Big win on weaker GPUs, barely visible on TV
  /// resolutions. Turning it off uses mpv's higher-quality scalers.
  final bool smoothScaling;

  PlaybackSettings copyWith({Decoder? decoder, Deinterlace? deinterlace, bool? smoothScaling}) =>
      PlaybackSettings(
        decoder: decoder ?? this.decoder,
        deinterlace: deinterlace ?? this.deinterlace,
        smoothScaling: smoothScaling ?? this.smoothScaling,
      );

  static PlaybackSettings load(SharedPreferences p) => PlaybackSettings(
    decoder: Decoder.values.asNameMap()[p.getString('pb.decoder')] ?? Decoder.hardware,
    deinterlace: Deinterlace.values.asNameMap()[p.getString('pb.deint')] ?? Deinterlace.auto,
    smoothScaling: p.getBool('pb.smooth') ?? true,
  );

  Future<void> save(SharedPreferences p) async {
    await p.setString('pb.decoder', decoder.name);
    await p.setString('pb.deint', deinterlace.name);
    await p.setBool('pb.smooth', smoothScaling);
  }

  VideoControllerConfiguration get videoConfig => VideoControllerConfiguration(
    hwdec: decoder.hwdec,
    enableHardwareAcceleration: decoder != Decoder.software,
  );
}

/// Creates a player with network and performance settings applied.
/// [preview] makes a lighter player for the guide's preview pane.
(Player, VideoController, Future<void>) createPlayer(PlaybackSettings s, {bool preview = false}) {
  final player = Player(
    configuration: PlayerConfiguration(
      title: 'IPTV Player',
      bufferSize: (preview ? 16 : 64) * 1024 * 1024,
      logLevel: MPVLogLevel.warn, // so HTTP errors (403/404) reach us
    ),
  );
  final video = VideoController(player, configuration: s.videoConfig);
  return (player, video, _configure(player, s, preview));
}

Future<void> _configure(Player player, PlaybackSettings s, bool preview) async {
  final p = player.platform;
  if (p is! NativePlayer) return;
  final props = <String, String>{
    'user-agent': userAgent,
    'network-timeout': '20',
    // Let ffmpeg ride out short network hiccups on live streams.
    'stream-lavf-o': 'reconnect=1,reconnect_streamed=1,reconnect_delay_max=5',
    // Read ahead a few seconds so network jitter doesn't turn into stutter.
    'cache': 'yes',
    'demuxer-readahead-secs': preview ? '2' : '8',
    // Let mpv drop late frames instead of falling further behind.
    'framedrop': 'vo',
    if (s.deinterlace == Deinterlace.on) 'deinterlace': 'yes',
    if (s.smoothScaling) ...{
      'scale': 'bilinear',
      'dscale': 'bilinear',
      'cscale': 'bilinear',
      'dither-depth': 'no',
      'correct-downscaling': 'no',
      'linear-downscaling': 'no',
      'sigmoid-upscaling': 'no',
      'deband': 'no',
    },
    if (preview) 'volume': '60',
  };
  for (final e in props.entries) {
    try {
      await p.setProperty(e.key, e.value);
    } catch (_) {
      // Older libmpv builds may not know every option; skip those.
    }
  }
}

/// Turns deinterlacing on for interlaced streams when set to Automatic.
/// Interlaced live TV (1080i/576i) looks juddery without it.
Future<void> autoDeinterlace(Player player, PlaybackSettings s) async {
  final p = player.platform;
  if (p is! NativePlayer || s.deinterlace != Deinterlace.auto) return;
  try {
    final interlaced = await p.getProperty('video-frame-info/interlaced');
    await p.setProperty('deinterlace', interlaced == 'yes' ? 'yes' : 'no');
  } catch (_) {}
}

/// Technical details for the player's stats panel.
Future<List<(String, String)>> playbackStats(Player player) async {
  final p = player.platform;
  if (p is! NativePlayer) return const [];
  Future<String> get(String name) async {
    try {
      final v = await p.getProperty(name);
      return v.isEmpty ? '—' : v;
    } catch (_) {
      return '—';
    }
  }

  final hw = await get('hwdec-current');
  final w = await get('video-params/w'), h = await get('video-params/h');
  final fps = await get('container-fps');
  final outFps = await get('estimated-vf-fps');
  double? n(String v) => double.tryParse(v);
  String f1(String v) => n(v)?.toStringAsFixed(1) ?? v;
  return [
    ('Video', '${await get('video-format')}  ${w}x$h'),
    ('Frame rate', '${f1(fps)} fps (showing ${f1(outFps)})'),
    ('Decoder', hw == 'no' || hw == '—' ? 'Software' : 'Hardware ($hw)'),
    ('Interlaced', '${await get('video-frame-info/interlaced')}, deinterlace ${await get('deinterlace')}'),
    (
      'Dropped frames',
      '${await get('frame-drop-count')} output, ${await get('decoder-frame-drop-count')} decoder',
    ),
    ('Buffered', '${f1(await get('demuxer-cache-duration'))} s'),
    ('Audio', await get('audio-codec-name')),
  ];
}

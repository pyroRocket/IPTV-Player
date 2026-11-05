import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';
import 'playback.dart';

/// Saved logins, favorites and last-watched channel, stored on this device only.
class Storage {
  Storage._(this._prefs);
  final SharedPreferences _prefs;

  static Future<Storage> open() async => Storage._(await SharedPreferences.getInstance());

  List<Profile> get profiles {
    try {
      final list = jsonDecode(_prefs.getString('profiles') ?? '[]') as List;
      return list.map((e) => Profile.fromJson(Map<String, dynamic>.from(e))).toList();
    } catch (_) {
      return [];
    }
  }

  /// Saves [p] as the most recently used profile.
  Future<void> saveProfile(Profile p) async {
    final list = profiles.where((x) => x.id != p.id).toList()..insert(0, p);
    await _prefs.setString('profiles', jsonEncode(list.map((e) => e.toJson()).toList()));
    await _prefs.setString('lastProfile', p.id);
  }

  Future<void> removeProfile(Profile p) async {
    final list = profiles.where((x) => x.id != p.id).toList();
    await _prefs.setString('profiles', jsonEncode(list.map((e) => e.toJson()).toList()));
    await _prefs.remove('fav|${p.id}');
    if (_prefs.getString('lastProfile') == p.id) await _prefs.remove('lastProfile');
  }

  /// The profile to auto-connect on launch, if the user didn't sign out.
  Profile? get lastProfile {
    final id = _prefs.getString('lastProfile');
    if (id == null) return null;
    for (final p in profiles) {
      if (p.id == id) return p;
    }
    return null;
  }

  Future<void> clearLastProfile() => _prefs.remove('lastProfile');

  Set<String> favorites(Profile p) => (_prefs.getStringList('fav|${p.id}') ?? const []).toSet();

  Future<void> setFavorites(Profile p, Set<String> keys) =>
      _prefs.setStringList('fav|${p.id}', keys.toList());

  PlaybackSettings get playback => PlaybackSettings.load(_prefs);
  Future<void> setPlayback(PlaybackSettings s) => s.save(_prefs);

  /// Whether the guide shows its preview pane.
  bool get guidePreview => _prefs.getBool('guidePreview') ?? true;
  Future<void> setGuidePreview(bool v) => _prefs.setBool('guidePreview', v);
}

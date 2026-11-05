import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';

import 'storage.dart';
import 'ui/home_screen.dart';
import 'ui/login_screen.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  final storage = await Storage.open();
  runApp(IptvApp(storage: storage));
}

final _nav = GlobalKey<NavigatorState>();

class _BackIntent extends Intent {
  const _BackIntent();
}

class IptvApp extends StatelessWidget {
  const IptvApp({super.key, required this.storage});
  final Storage storage;

  @override
  Widget build(BuildContext context) {
    final last = storage.lastProfile;
    return MaterialApp(
      title: 'IPTV Player',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      // TV remotes send "select" for the OK button; treat it like Enter.
      navigatorKey: _nav,
      shortcuts: {
        ...WidgetsApp.defaultShortcuts,
        const SingleActivator(LogicalKeyboardKey.select): const ActivateIntent(),
        // Esc goes back on desktop, like the Back button on a remote.
        const SingleActivator(LogicalKeyboardKey.escape): const _BackIntent(),
      },
      actions: {
        ...WidgetsApp.defaultActions,
        _BackIntent: CallbackAction<_BackIntent>(onInvoke: (_) => _nav.currentState?.maybePop()),
      },
      home: last != null ? HomeScreen(storage: storage, profile: last) : LoginScreen(storage: storage),
    );
  }
}

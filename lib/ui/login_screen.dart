import 'package:flutter/material.dart';

import '../models.dart';
import '../sources/source.dart';
import '../storage.dart';
import 'home_screen.dart';
import 'theme.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.storage, this.error});
  final Storage storage;
  final String? error;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  bool _xtream = true;
  bool _busy = false;
  String? _error;
  final _server = TextEditingController();
  final _user = TextEditingController();
  final _pass = TextEditingController();
  final _url = TextEditingController();
  final _epg = TextEditingController();
  late List<Profile> _saved = widget.storage.profiles;

  @override
  void initState() {
    super.initState();
    _error = widget.error;
  }

  @override
  void dispose() {
    for (final c in [_server, _user, _pass, _url, _epg]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _connect(Profile p) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final source = await connect(p);
      await widget.storage.saveProfile(p);
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => HomeScreen(storage: widget.storage, profile: p, source: source),
        ),
      );
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _submit() {
    if (_xtream) {
      if (_server.text.trim().isEmpty || _user.text.trim().isEmpty || _pass.text.isEmpty) {
        setState(() => _error = 'Fill in the server, username and password.');
        return;
      }
      _connect(Profile.xtream(server: _server.text, username: _user.text, password: _pass.text));
    } else {
      var url = _url.text.trim();
      if (url.isEmpty) {
        setState(() => _error = 'Paste your playlist link.');
        return;
      }
      if (!url.contains('://')) url = 'http://$url';
      final epg = _epg.text.trim();
      _connect(Profile.m3u(url: url, epgUrl: epg.isEmpty ? null : epg));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Card(
              color: panel,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: const BorderSide(color: line),
              ),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: FocusTraversalGroup(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text('IPTV Player', style: Theme.of(context).textTheme.headlineSmall),
                      const SizedBox(height: 4),
                      const Text(
                        'Sign in with your provider\'s details. They stay on this device.',
                        style: TextStyle(color: muted),
                      ),
                      const SizedBox(height: 20),
                      SegmentedButton<bool>(
                        segments: const [
                          ButtonSegment(value: true, label: Text('Xtream login')),
                          ButtonSegment(value: false, label: Text('M3U link')),
                        ],
                        selected: {_xtream},
                        showSelectedIcon: false,
                        onSelectionChanged: (s) => setState(() {
                          _xtream = s.first;
                          _error = null;
                        }),
                      ),
                      const SizedBox(height: 16),
                      if (_xtream) ...[
                        _field(
                          _server,
                          'Server URL',
                          hint: 'http://provider.example:8080',
                          keyboard: TextInputType.url,
                        ),
                        _field(_user, 'Username'),
                        _field(_pass, 'Password', obscure: true, last: true),
                      ] else ...[
                        _field(
                          _url,
                          'Playlist URL',
                          hint: 'http://provider.example/get.php?username=…&password=…&type=m3u_plus',
                          keyboard: TextInputType.url,
                        ),
                        _field(
                          _epg,
                          'TV guide (EPG) address, optional',
                          hint: 'Leave blank to use the playlist\'s own guide',
                          keyboard: TextInputType.url,
                          last: true,
                        ),
                      ],
                      const SizedBox(height: 8),
                      FilledButton(
                        onPressed: _busy ? null : _submit,
                        style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
                        child: _busy
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : Text(_xtream ? 'Connect' : 'Load playlist'),
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: 12),
                        Text(_error!, style: const TextStyle(color: Color(0xFFFF6B6B))),
                      ],
                      if (_saved.isNotEmpty) ...[
                        const SizedBox(height: 24),
                        const Divider(color: line),
                        const SizedBox(height: 8),
                        const Text('Saved accounts', style: TextStyle(color: muted)),
                        const SizedBox(height: 4),
                        for (final p in _saved)
                          ListTile(
                            contentPadding: const EdgeInsets.only(left: 8),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            leading: Icon(p.isXtream ? Icons.dns_outlined : Icons.playlist_play),
                            title: Text(p.name),
                            subtitle: Text(
                              p.isXtream ? '${p.username} · Xtream' : 'M3U playlist',
                              style: const TextStyle(color: muted),
                            ),
                            onTap: _busy ? null : () => _connect(p),
                            trailing: IconButton(
                              tooltip: 'Remove',
                              icon: const Icon(Icons.close),
                              onPressed: () async {
                                await widget.storage.removeProfile(p);
                                setState(() => _saved = widget.storage.profiles);
                              },
                            ),
                          ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _field(
    TextEditingController c,
    String label, {
    String? hint,
    bool obscure = false,
    bool last = false,
    TextInputType? keyboard,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: c,
        obscureText: obscure,
        autocorrect: false,
        enableSuggestions: false,
        keyboardType: keyboard,
        textInputAction: last ? TextInputAction.go : TextInputAction.next,
        onSubmitted: last ? (_) => _submit() : null,
        decoration: InputDecoration(labelText: label, hintText: hint),
      ),
    );
  }
}

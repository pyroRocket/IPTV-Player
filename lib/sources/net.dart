import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// Many providers reject requests that don't look like a media player.
const userAgent = 'VLC/3.0.20 LibVLC/3.0.20';

class SourceException implements Exception {
  SourceException(this.message);
  final String message;
  @override
  String toString() => message;
}

final _client = http.Client();

Future<String> fetchText(String url, {Duration timeout = const Duration(seconds: 45)}) async {
  final Uri uri;
  try {
    uri = Uri.parse(url);
  } catch (_) {
    throw SourceException('That address doesn\'t look right: $url');
  }
  if (uri.scheme != 'http' && uri.scheme != 'https') {
    throw SourceException('Address must start with http:// or https://');
  }
  http.Response res;
  try {
    res = await _client.get(uri, headers: {'User-Agent': userAgent}).timeout(timeout);
  } on TimeoutException {
    throw SourceException('The provider took too long to respond.');
  } on SocketException catch (e) {
    throw SourceException('Couldn\'t reach the provider (${e.osError?.message ?? e.message}).');
  } on HandshakeException {
    throw SourceException('Secure connection to the provider failed (certificate problem).');
  } on http.ClientException catch (e) {
    throw SourceException('Couldn\'t reach the provider (${e.message}).');
  }
  if (res.statusCode != 200) {
    throw SourceException(switch (res.statusCode) {
      401 || 403 => 'The provider refused the login (HTTP ${res.statusCode}). Check your details.',
      404 => 'Nothing found at that address (HTTP 404).',
      _ => 'The provider returned an error (HTTP ${res.statusCode}).',
    });
  }
  // Decode as UTF-8 regardless of headers; IPTV servers often mislabel it.
  return utf8.decode(res.bodyBytes, allowMalformed: true);
}

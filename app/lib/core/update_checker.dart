// Checks GitHub Releases for a newer CloudBox build.
//
// Every CloudBox release is a pre-release with make_latest: false, so GitHub's `/releases/latest`
// endpoint is meaningless here. We list recent releases and choose the highest version tag
// ourselves. Versions are MAJOR.MINOR.DD.MM.YY — see docs/decisions/0001-versioning.md.
//
// This file is shared verbatim with pc/lib/core/update_checker.dart.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'gen/version.dart';

/// Compares two CloudBox versions. Returns a negative number when [a] is older than [b].
///
/// The wire order is MAJOR.MINOR.DD.MM.YY; reorder to MAJOR.MINOR.YY.MM.DD so plain integer
/// comparison gives chronological order. Leading zeros ("01") parse as ordinary integers.
int compareCloudBoxVersions(String a, String b) {
  final left = _versionParts(a);
  final right = _versionParts(b);
  for (var i = 0; i < 5; i++) {
    final result = left[i].compareTo(right[i]);
    if (result != 0) return result;
  }
  return 0;
}

List<int> _versionParts(String raw) {
  var value = raw.trim();
  if (value.startsWith('v') || value.startsWith('V')) value = value.substring(1);
  final pieces = value.split('.');
  if (pieces.length != 5) return const [0, 0, 0, 0, 0];
  final numbers = pieces.map((p) => int.tryParse(p) ?? 0).toList();
  return [numbers[0], numbers[1], numbers[4], numbers[3], numbers[2]];
}

/// A release newer than the running app, together with the download for this platform.
class AppRelease {
  const AppRelease({
    required this.version,
    required this.name,
    required this.pageUrl,
    required this.assetUrl,
    required this.publishedAt,
    required this.prerelease,
  });

  factory AppRelease.fromJson(Map<String, dynamic> json, {String? assetUrl}) {
    final tag = json['tag_name'] as String? ?? '';
    return AppRelease(
      version: tag.startsWith('v') ? tag.substring(1) : tag,
      name: json['name'] as String? ?? '',
      pageUrl: json['html_url'] as String? ?? '',
      assetUrl: assetUrl,
      publishedAt: json['published_at'] as String? ?? '',
      prerelease: json['prerelease'] as bool? ?? false,
    );
  }

  final String version;
  final String name;
  final String pageUrl;
  final String? assetUrl;
  final String publishedAt;
  final bool prerelease;

  String get displayName => name.isEmpty ? 'CloudBox $version' : name;

  String get publishedDay {
    if (publishedAt.length < 10) return '';
    return publishedAt.substring(0, 10);
  }
}

/// Chooses the newest release that is both newer than [currentVersion] and has an installable
/// asset for [platform] ("android" or "windows"). Pure so it can be unit-tested without network.
AppRelease? newestRelease(
  List<dynamic> payload, {
  required String platform,
  String currentVersion = kCloudBoxVersion,
}) {
  final extension = platform == 'android' ? '.apk' : '.exe';
  AppRelease? best;

  for (final entry in payload) {
    if (entry is! Map) continue;
    final json = entry.cast<String, dynamic>();
    final tag = json['tag_name'] as String? ?? '';
    if (!tag.startsWith('v')) continue;
    final version = tag.substring(1);
    if (compareCloudBoxVersions(version, currentVersion) <= 0) continue;

    String? assetUrl;
    final assets = json['assets'];
    if (assets is List) {
      for (final asset in assets) {
        if (asset is! Map) continue;
        final name = asset['name'] as String? ?? '';
        if (name.toLowerCase().endsWith(extension)) {
          assetUrl = asset['browser_download_url'] as String?;
          if (assetUrl != null) break;
        }
      }
    }

    final candidate = AppRelease.fromJson(json, assetUrl: assetUrl);
    if (best == null || compareCloudBoxVersions(candidate.version, best.version) > 0) {
      best = candidate;
    }
  }
  return best;
}

class UpdateCheckException implements Exception {
  const UpdateCheckException(this.message);

  final String message;

  @override
  String toString() => message;
}

class UpdateChecker {
  UpdateChecker({HttpClient? client, this.platform = 'android'})
      : _client = client ?? HttpClient() {
    _client.userAgent = 'CloudBox/$kCloudBoxVersion';
    _client.connectionTimeout = const Duration(seconds: 6);
  }

  final HttpClient _client;

  /// "android" looks for an .apk asset, "windows" for an .exe.
  final String platform;

  static const _endpoint =
      'https://api.github.com/repos/Gyakudos/CloudBox/releases?per_page=10';
  static const _timeout = Duration(seconds: 8);

  /// Returns a newer release, or null when the app is current. Throws [UpdateCheckException]
  /// with a message suitable for showing the user when GitHub cannot be reached.
  Future<AppRelease?> check({
    String currentVersion = kCloudBoxVersion,
  }) async {
    final HttpClientResponse response;
    try {
      final request = await _client.getUrl(Uri.parse(_endpoint)).timeout(_timeout);
      request.headers.set('Accept', 'application/vnd.github+json');
      request.headers.set('X-GitHub-Api-Version', '2022-11-28');
      response = await request.close().timeout(_timeout);
    } on TimeoutException {
      throw const UpdateCheckException(
        'GitHub did not answer in time. Check your internet connection and try again.',
      );
    } on IOException catch (error) {
      throw UpdateCheckException('Could not reach GitHub to check for updates: $error');
    }

    final text = await response.transform(utf8.decoder).join();
    if (response.statusCode != 200) {
      throw UpdateCheckException(
        'GitHub returned HTTP ${response.statusCode} while checking for updates.',
      );
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      throw const UpdateCheckException('GitHub sent a response this app could not read.');
    }
    if (decoded is! List) {
      throw const UpdateCheckException('GitHub sent an unexpected response.');
    }
    return newestRelease(decoded, platform: platform, currentVersion: currentVersion);
  }

  void close() => _client.close(force: true);
}

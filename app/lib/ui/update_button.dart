import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/update_checker.dart';

/// AppBar action that checks GitHub Releases for a newer build.
///
/// [platform] selects the installable asset in the release ("android" looks for an .apk).
class UpdateButton extends StatefulWidget {
  const UpdateButton({super.key, required this.platform});

  final String platform;

  @override
  State<UpdateButton> createState() => _UpdateButtonState();
}

class _UpdateButtonState extends State<UpdateButton> {
  bool _busy = false;

  Future<void> _checkForUpdates() async {
    if (_busy) return;
    setState(() => _busy = true);

    final checker = UpdateChecker(platform: widget.platform);
    AppRelease? release;
    Object? failure;
    try {
      release = await checker.check();
    } on UpdateCheckException catch (error) {
      failure = error;
    } on Object catch (error) {
      failure = UpdateCheckException('Could not check for updates: $error');
    } finally {
      checker.close();
      if (mounted) setState(() => _busy = false);
    }

    if (!mounted) return;
    if (failure != null) {
      _showMessage(failure.toString());
    } else if (release == null) {
      _showMessage('You are up to date.');
    } else {
      _showRelease(release);
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _open(Uri uri) async {
    try {
      final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!opened) _showMessage('Could not open $uri');
    } on Object {
      _showMessage('Could not open $uri');
    }
  }

  void _showRelease(AppRelease release) {
    final assetUrl = release.assetUrl;
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Update available: ${release.version}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(release.displayName),
            if (release.publishedDay.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('Published ${release.publishedDay}'),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Not now'),
          ),
          if (assetUrl != null && release.pageUrl.isNotEmpty)
            TextButton(
              onPressed: () {
                Navigator.of(dialogContext).pop();
                _open(Uri.parse(release.pageUrl));
              },
              child: const Text('View release'),
            ),
          FilledButton(
            onPressed: () {
              Navigator.of(dialogContext).pop();
              final url = assetUrl ?? release.pageUrl;
              if (url.isEmpty) {
                _showMessage('This release has no download link.');
                return;
              }
              _open(Uri.parse(url));
            },
            child: const Text('Download'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: 'Check for updates',
      onPressed: _busy ? null : _checkForUpdates,
      icon: _busy
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.system_update),
    );
  }
}

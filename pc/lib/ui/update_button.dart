// Small header button that asks GitHub Releases whether a newer CloudBox build is available.
// All CloudBox releases are pre-releases, so this uses the release list rather than /latest.

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/gen/version.dart';
import '../core/update_checker.dart';

class UpdateButton extends StatefulWidget {
  const UpdateButton({super.key, required this.platform});

  /// "windows" looks for an .exe asset; "android" for an .apk.
  final String platform;

  @override
  State<UpdateButton> createState() => _UpdateButtonState();
}

class _UpdateButtonState extends State<UpdateButton> {
  bool _checking = false;

  Future<void> _check() async {
    if (_checking) return;
    setState(() => _checking = true);
    final checker = UpdateChecker(platform: widget.platform);
    try {
      final release = await checker.check();
      if (!mounted) return;
      if (release == null) {
        _showMessage('CloudBox $kCloudBoxVersion is the latest available build.');
        return;
      }
      await _showRelease(release);
    } on UpdateCheckException catch (error) {
      if (mounted) _showMessage(error.message);
    } on Object catch (error) {
      if (mounted) _showMessage('Could not check for updates: $error');
    } finally {
      checker.close();
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _showRelease(AppRelease release) async {
    Future<void> openPage() => _open(release.pageUrl);
    Future<void> download() => _open(release.assetUrl ?? release.pageUrl);

    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Update available'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(release.displayName, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text('Version ${release.version}'),
            if (release.publishedDay.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text('Published ${release.publishedDay}'),
            ],
            const SizedBox(height: 12),
            Text(
              'You are running $kCloudBoxVersion. Downloads open in your browser.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, 'close'), child: const Text('Later')),
          if (release.assetUrl != null)
            TextButton(onPressed: () => Navigator.pop(context, 'page'), child: const Text('View release')),
          FilledButton(onPressed: () => Navigator.pop(context, 'download'), child: const Text('Download')),
        ],
      ),
    );

    if (!mounted || result == null || result == 'close') return;
    await (result == 'page' ? openPage() : download());
  }

  Future<void> _open(String url) async {
    if (url.isEmpty) return;
    final uri = Uri.tryParse(url);
    if (uri == null) {
      _showMessage('That download link is not valid.');
      return;
    }
    try {
      final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!launched && mounted) _showMessage('Could not open the browser for this download.');
    } on Object catch (error) {
      if (mounted) _showMessage('Could not open the browser: $error');
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: 'Check for updates',
      onPressed: _checking ? null : _check,
      icon: _checking
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.system_update),
    );
  }
}

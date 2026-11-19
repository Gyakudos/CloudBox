import 'package:cloudbox_pc/core/update_checker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('compares MAJOR.MINOR.DD.MM.YY chronologically', () {
    expect(compareCloudBoxVersions('0.01.15.11.26', '0.01.16.11.26'), lessThan(0));
    expect(compareCloudBoxVersions('0.01.15.11.26', '0.01.15.12.26'), lessThan(0));
    expect(compareCloudBoxVersions('0.01.15.11.26', '0.01.15.11.27'), lessThan(0));
    expect(compareCloudBoxVersions('0.01.15.11.26', 'v0.01.15.11.26'), 0);
    expect(compareCloudBoxVersions('1.00.01.01.26', '0.99.31.12.26'), greaterThan(0));
  });

  test('ignores malformed versions and malformed releases', () {
    expect(compareCloudBoxVersions('nope', '0.00.01.01.26'), lessThan(0));
    final picked = newestRelease(
      const [
        'not a map',
        {'tag_name': 'not-a-version'},
        {
          'tag_name': 'v0.01.16.11.26',
          'name': 'CloudBox',
          'html_url': 'https://example.test/release',
          'published_at': '2026-11-16T00:00:00Z',
          'prerelease': true,
          'assets': [
            {
              'name': 'CloudBoxSetup.exe',
              'browser_download_url': 'https://example.test/setup.exe',
            },
          ],
        },
      ],
      platform: 'windows',
      currentVersion: '0.01.15.11.26',
    );
    expect(picked?.version, '0.01.16.11.26');
    expect(picked?.assetUrl, 'https://example.test/setup.exe');
  });

  test('still suggests a release without a direct asset, linking to its page', () {
    final picked = newestRelease(
      const [
        {
          'tag_name': 'v0.01.16.11.26',
          'name': 'CloudBox',
          'html_url': 'https://example.test/release',
          'published_at': '2026-11-16T00:00:00Z',
          'prerelease': true,
          'assets': [
            {
              'name': 'cloudbox.apk',
              'browser_download_url': 'https://example.test/app.apk',
            },
          ],
        },
      ],
      platform: 'windows',
      currentVersion: '0.01.15.11.26',
    );
    expect(picked?.version, '0.01.16.11.26');
    expect(picked?.assetUrl, isNull);
    expect(picked?.pageUrl, 'https://example.test/release');
  });
}

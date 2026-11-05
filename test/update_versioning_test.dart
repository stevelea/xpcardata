import 'package:flutter_test/flutter_test.dart';

import 'package:carsoc/services/update_versioning.dart';

void main() {
  group('compareVersions', () {
    test('orders patch releases numerically, not as strings', () {
      expect(compareVersions('1.4.23', '1.4.22'), greaterThan(0));
      expect(compareVersions('1.4.9', '1.4.23'), lessThan(0));
      expect(compareVersions('1.4.22', '1.4.23'), lessThan(0));
    });

    test('equal versions compare as equal, with or without v prefix', () {
      expect(compareVersions('1.4.24', '1.4.24'), 0);
      expect(compareVersions('v1.4.24', '1.4.24'), 0);
      expect(compareVersions('V1.4.24', 'v1.4.24'), 0);
    });

    test('missing segments are treated as zero', () {
      expect(compareVersions('1.4', '1.4.0'), 0);
      expect(compareVersions('1.5', '1.4.99'), greaterThan(0));
    });

    test('non-numeric suffixes do not break comparison', () {
      expect(compareVersions('1.4.24-beta', '1.4.24'), 0);
      expect(compareVersions('1.4.24-beta', '1.4.23'), greaterThan(0));
    });

    test('major and minor bumps win over patch numbers', () {
      expect(compareVersions('2.0.0', '1.99.99'), greaterThan(0));
      expect(compareVersions('1.10.0', '1.9.9'), greaterThan(0));
    });
  });

  group('isNewerVersion', () {
    test('is true only when strictly newer', () {
      expect(isNewerVersion('1.4.24', '1.4.22'), isTrue);
      expect(isNewerVersion('1.4.22', '1.4.22'), isFalse);
      expect(isNewerVersion('1.4.21', '1.4.22'), isFalse);
      expect(isNewerVersion('v1.5.0', '1.4.24'), isTrue);
    });
  });

  group('needsSigningMigration', () {
    test('true when an old build upgrades past the v1.4.23 key change', () {
      expect(needsSigningMigration('1.4.22', '1.4.24'), isTrue);
      expect(needsSigningMigration('1.4.9', '1.4.24'), isTrue);
      expect(needsSigningMigration('1.3.94', '1.4.24'), isTrue);
      expect(needsSigningMigration('v1.4.22', 'v1.4.24'), isTrue);
    });

    test('true when the target is exactly the first re-signed release', () {
      expect(needsSigningMigration('1.4.22', '1.4.23'), isTrue);
    });

    test('false once the running build is already re-signed', () {
      expect(needsSigningMigration('1.4.23', '1.4.24'), isFalse);
      expect(needsSigningMigration('1.4.24', '1.5.0'), isFalse);
    });

    test('false when both builds predate the key change', () {
      expect(needsSigningMigration('1.4.10', '1.4.20'), isFalse);
      expect(needsSigningMigration('1.4.22', '1.4.22'), isFalse);
    });
  });

  group('reusable instructions text', () {
    test('mentions the backup path and the AI box alternative', () {
      expect(signingMigrationInstructions, contains('Backup & Restore'));
      expect(signingMigrationInstructions, contains('Share Backup'));
      expect(signingMigrationInstructions.toLowerCase(), contains('clipboard'));
      expect(
        signingMigrationInstructions.toLowerCase(),
        contains('uninstall'),
      );
      expect(signingMigrationSummary, contains('Backup & Restore'));
    });
  });
}

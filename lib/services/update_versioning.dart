/// Pure version helpers for the in-app updater.
///
/// Deliberately free of Flutter/plugin imports so the version comparison and the
/// signing-migration predicate can be unit-tested directly (no widget binding).
library;

/// First release signed with the permanent release keystore.
///
/// Releases up to and including 1.4.22 were signed with a machine-specific
/// debug key, so Android refuses to install a 1.4.23+ APK over them in place
/// ("The application could not be installed due to a conflict with a package.").
/// See GitHub issue #14.
const String signingKeyMigrationVersion = '1.4.23';

/// Short explanation shown inline in the Updates card and at the top of the
/// update dialog when [needsSigningMigration] is true.
const String signingMigrationSummary =
    'This update cannot be installed over your current version. The app is now '
    'signed with a new, permanent key, so Android reports a package conflict '
    'when updating in place from version 1.4.22 or older. Uninstall this '
    'version, then install the new one. Back up first: Settings → Data → '
    'Backup & Restore → Share Backup. On AI boxes use Share or Clipboard '
    'instead of Downloads. Your backup is imported again in the new version.';

/// Complete recovery steps, reused verbatim in the in-app dialog, the release
/// notes and GitHub issue replies.
const String signingMigrationInstructions =
    'XPCarData: one-time reinstall required (app version 1.4.22 or older)\n'
    '\n'
    'Starting with v1.4.23 the app is signed with a new, permanent release key. '
    'Android will not install the new APK over an older copy, and the in-app '
    'updater reports: "The application could not be installed due to a conflict '
    'with a package." This is expected and only affects builds up to 1.4.22. '
    'Reinstalling once fixes it permanently; after that, in-app updates install '
    'normally.\n'
    '\n'
    'Back up your data first - the app is uninstalled in step 3.\n'
    '1. Open Settings → Data → Backup & Restore.\n'
    '2. Tap "Share Backup" and send the file somewhere you can still reach after '
    'the app is gone (email, messaging app, cloud drive or USB stick).\n'
    '   On an Android AI box (Carlinkit, Ottocast, ...) use "Share Backup" or '
    '"Clipboard" instead of "Downloads" - the Downloads folder may not be '
    'writable there.\n'
    '3. Uninstall XPCarData: long-press the app icon → App info → Uninstall.\n'
    '4. Download the latest release from '
    'https://github.com/stevelea/xpcardata/releases (the APK is inside the ZIP) '
    'and install it. Allow Android to install unknown apps if it asks.\n'
    '5. Open XPCarData, go to Settings → Data → Backup & Restore and import the '
    'backup from step 2.\n'
    '\n'
    'Only versions 1.4.22 and older need this; v1.4.23 and later update in '
    'place.';

/// Compare two semantic-ish version strings ("v1.4.23", "1.4.23", "1.4").
///
/// Returns a negative number if [a] is older than [b], zero if they are equal
/// and a positive number if [a] is newer. Missing parts count as zero and
/// non-numeric suffixes are ignored, so "1.4" equals "1.4.0".
int compareVersions(String a, String b) {
  final aParts = _parseVersion(a);
  final bParts = _parseVersion(b);

  final length = aParts.length > bParts.length ? aParts.length : bParts.length;
  for (var i = 0; i < length; i++) {
    final aPart = i < aParts.length ? aParts[i] : 0;
    final bPart = i < bParts.length ? bParts[i] : 0;
    if (aPart != bPart) {
      return aPart < bPart ? -1 : 1;
    }
  }
  return 0;
}

/// True when [candidate] is strictly newer than [current].
bool isNewerVersion(String candidate, String current) =>
    compareVersions(candidate, current) > 0;

/// True when installing [targetVersion] over [runningVersion] crosses the
/// v1.4.23 signing-key change, so Android will refuse an in-place update.
///
/// That is the case only for devices running a build older than
/// [signingKeyMigrationVersion] that are moving to a build at or after it.
bool needsSigningMigration(String runningVersion, String targetVersion) {
  return compareVersions(runningVersion, signingKeyMigrationVersion) < 0 &&
      compareVersions(targetVersion, signingKeyMigrationVersion) >= 0;
}

List<int> _parseVersion(String version) {
  var cleaned = version.trim();
  if (cleaned.startsWith('v') || cleaned.startsWith('V')) {
    cleaned = cleaned.substring(1);
  }
  return cleaned.split('.').map((part) {
    final match = RegExp(r'^\d+').firstMatch(part);
    return match == null ? 0 : int.tryParse(match.group(0)!) ?? 0;
  }).toList();
}

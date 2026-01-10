import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Hardcoded app version (updated during build)
/// This avoids package_info_plus which fails on AAOS
const String _appVersion = '1.0.8';
const String _appBuildNumber = '34';

/// Service for checking and downloading updates from GitHub releases
class GitHubUpdateService {
  // Singleton instance
  static final GitHubUpdateService _instance = GitHubUpdateService._internal();
  static GitHubUpdateService get instance => _instance;
  GitHubUpdateService._internal();

  /// GitHub repository owner and name
  static const String _owner = 'dlee1j1';
  static const String _repo = 'xpcardata';

  /// GitHub API URL for releases
  static const String _apiUrl =
      'https://api.github.com/repos/$_owner/$_repo/releases/latest';

  /// Current release info
  ReleaseInfo? _latestRelease;
  ReleaseInfo? get latestRelease => _latestRelease;

  /// Check if an update is available
  bool _updateAvailable = false;
  bool get updateAvailable => _updateAvailable;

  /// Download progress (0.0 - 1.0)
  double _downloadProgress = 0.0;
  double get downloadProgress => _downloadProgress;

  /// Whether currently downloading
  bool _isDownloading = false;
  bool get isDownloading => _isDownloading;

  /// Path to downloaded APK
  String? _downloadedApkPath;
  String? get downloadedApkPath => _downloadedApkPath;

  /// Error message if any
  String? _error;
  String? get error => _error;

  /// Optional GitHub personal access token to avoid rate limiting
  /// Stored in SharedPreferences with key 'github_token'
  String? _githubToken;

  /// Set GitHub token for authenticated requests (higher rate limit)
  Future<void> setGitHubToken(String? token) async {
    _githubToken = token;

    // Try SharedPreferences first
    try {
      final prefs = await SharedPreferences.getInstance();
      if (token != null && token.isNotEmpty) {
        await prefs.setString('github_token', token);
      } else {
        await prefs.remove('github_token');
      }
    } catch (e) {
      // SharedPreferences may fail on AAOS - use file-based fallback
      try {
        final directory = await getExternalStorageDirectory() ?? await getTemporaryDirectory();
        final file = File('${directory.path}/github_token.txt');
        if (token != null && token.isNotEmpty) {
          await file.writeAsString(token);
        } else if (await file.exists()) {
          await file.delete();
        }
      } catch (_) {
        // Ignore - token storage failed but in-memory token is still set
      }
    }
  }

  /// Load GitHub token from storage
  Future<void> loadGitHubToken() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _githubToken = prefs.getString('github_token');
    } catch (e) {
      // SharedPreferences may fail on AAOS - try file-based fallback
      try {
        final directory = await getExternalStorageDirectory() ?? await getTemporaryDirectory();
        final file = File('${directory.path}/github_token.txt');
        if (await file.exists()) {
          _githubToken = await file.readAsString();
        }
      } catch (_) {
        // Ignore - token will remain null
      }
    }
  }

  /// Check for updates from GitHub
  Future<bool> checkForUpdates() async {
    _error = null;
    try {
      // Load token if not already loaded
      if (_githubToken == null) {
        await loadGitHubToken();
      }

      // Use hardcoded version (package_info_plus fails on AAOS)
      final currentVersion = _appVersion;

      final headers = <String, String>{
        'Accept': 'application/vnd.github.v3+json',
        'User-Agent': 'XPCarData/$currentVersion', // Required by GitHub API
      };

      // Add auth token if available (increases rate limit from 60 to 5000/hour)
      if (_githubToken != null && _githubToken!.isNotEmpty) {
        headers['Authorization'] = 'token $_githubToken';
      }

      final response = await http.get(
        Uri.parse(_apiUrl),
        headers: headers,
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        _latestRelease = ReleaseInfo.fromJson(data);

        _updateAvailable = _isNewerVersion(
          _latestRelease!.version,
          currentVersion,
        );

        return _updateAvailable;
      } else if (response.statusCode == 404) {
        _error = 'No releases found on GitHub';
        return false;
      } else if (response.statusCode == 403) {
        _error = 'GitHub rate limit exceeded. Try again in an hour, or add a GitHub token in Settings.';
        return false;
      } else if (response.statusCode == 401) {
        _error = 'Invalid GitHub token. Please check your token in Settings.';
        return false;
      } else {
        _error = 'GitHub API error: ${response.statusCode}';
        return false;
      }
    } catch (e) {
      _error = 'Failed to check for updates: $e';
      return false;
    }
  }

  /// Compare two semantic versions
  /// Returns true if newVersion > currentVersion
  bool _isNewerVersion(String newVersion, String currentVersion) {
    // Remove 'v' prefix if present
    newVersion = newVersion.replaceFirst('v', '');
    currentVersion = currentVersion.replaceFirst('v', '');

    final newParts = newVersion.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    final currentParts = currentVersion.split('.').map((e) => int.tryParse(e) ?? 0).toList();

    // Ensure both have at least 3 parts
    while (newParts.length < 3) {
      newParts.add(0);
    }
    while (currentParts.length < 3) {
      currentParts.add(0);
    }

    // Compare major, minor, patch
    for (var i = 0; i < 3; i++) {
      if (newParts[i] > currentParts[i]) return true;
      if (newParts[i] < currentParts[i]) return false;
    }

    return false; // Versions are equal
  }

  /// Download the latest APK
  Future<String?> downloadUpdate({
    void Function(double progress)? onProgress,
  }) async {
    if (_latestRelease == null || _latestRelease!.apkDownloadUrl == null) {
      _error = 'No APK available for download';
      return null;
    }

    _error = null;
    _isDownloading = true;
    _downloadProgress = 0.0;

    try {
      final request = http.Request('GET', Uri.parse(_latestRelease!.apkDownloadUrl!));
      request.headers['User-Agent'] = 'XPCarData';
      final response = await http.Client().send(request);

      if (response.statusCode != 200) {
        _error = 'Download failed: ${response.statusCode}';
        _isDownloading = false;
        return null;
      }

      final contentLength = response.contentLength ?? 0;
      final directory = await getExternalStorageDirectory() ?? await getTemporaryDirectory();
      final filePath = '${directory.path}/XPCarData-${_latestRelease!.version}.apk';
      final file = File(filePath);
      final sink = file.openWrite();

      var downloaded = 0;
      await for (final chunk in response.stream) {
        sink.add(chunk);
        downloaded += chunk.length;
        if (contentLength > 0) {
          _downloadProgress = downloaded / contentLength;
          onProgress?.call(_downloadProgress);
        }
      }

      await sink.close();

      _downloadedApkPath = filePath;
      _isDownloading = false;
      _downloadProgress = 1.0;

      return filePath;
    } catch (e) {
      _error = 'Download failed: $e';
      _isDownloading = false;
      return null;
    }
  }

  /// Get current app version info
  String getCurrentVersion() {
    // Use hardcoded version (package_info_plus fails on AAOS)
    return '$_appVersion (Build $_appBuildNumber)';
  }

  /// Reset state
  void reset() {
    _latestRelease = null;
    _updateAvailable = false;
    _downloadProgress = 0.0;
    _isDownloading = false;
    _downloadedApkPath = null;
    _error = null;
  }
}

/// Release information from GitHub
class ReleaseInfo {
  final String version;
  final String name;
  final String body;
  final String htmlUrl;
  final String? apkDownloadUrl;
  final int? apkSize;
  final DateTime publishedAt;

  ReleaseInfo({
    required this.version,
    required this.name,
    required this.body,
    required this.htmlUrl,
    this.apkDownloadUrl,
    this.apkSize,
    required this.publishedAt,
  });

  factory ReleaseInfo.fromJson(Map<String, dynamic> json) {
    // Find APK asset
    String? apkUrl;
    int? apkSize;
    final assets = json['assets'] as List<dynamic>? ?? [];
    for (final asset in assets) {
      final name = asset['name'] as String? ?? '';
      if (name.toLowerCase().endsWith('.apk')) {
        apkUrl = asset['browser_download_url'] as String?;
        apkSize = asset['size'] as int?;
        break;
      }
    }

    return ReleaseInfo(
      version: (json['tag_name'] as String? ?? '').replaceFirst('v', ''),
      name: json['name'] as String? ?? 'Unknown',
      body: json['body'] as String? ?? '',
      htmlUrl: json['html_url'] as String? ?? '',
      apkDownloadUrl: apkUrl,
      apkSize: apkSize,
      publishedAt: DateTime.tryParse(json['published_at'] as String? ?? '') ??
          DateTime.now(),
    );
  }

  /// Format file size for display
  String get formattedSize {
    if (apkSize == null) return 'Unknown size';
    if (apkSize! < 1024) return '$apkSize B';
    if (apkSize! < 1024 * 1024) return '${(apkSize! / 1024).toStringAsFixed(1)} KB';
    return '${(apkSize! / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  /// Format publish date for display
  String get formattedDate {
    return '${publishedAt.year}-${publishedAt.month.toString().padLeft(2, '0')}-${publishedAt.day.toString().padLeft(2, '0')}';
  }
}

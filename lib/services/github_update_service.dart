import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'hive_storage_service.dart';

/// Hardcoded app version (updated during build)
/// This avoids package_info_plus which fails on AAOS
const String appVersion = '1.4.2';

/// Service for checking and downloading updates from GitHub releases
class GitHubUpdateService {
  // Singleton instance
  static final GitHubUpdateService _instance = GitHubUpdateService._internal();
  static GitHubUpdateService get instance => _instance;
  GitHubUpdateService._internal();

  /// GitHub repository owner and name
  static const String _owner = 'stevelea';
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

  /// Get current GitHub token (may be null if not loaded or not set)
  String? get githubToken => _githubToken;

  /// Check if a GitHub token is configured
  bool get hasGitHubToken => _githubToken != null && _githubToken!.isNotEmpty;

  /// Set GitHub token for authenticated requests (higher rate limit)
  Future<void> setGitHubToken(String? token) async {
    // Trim and validate token
    final cleanToken = token?.trim();

    if (cleanToken != null && cleanToken.isNotEmpty) {
      // Validate token format - must be alphanumeric with underscores
      if (!RegExp(r'^[a-zA-Z0-9_]+$').hasMatch(cleanToken)) {
        debugPrint('[Update] Invalid token format - contains invalid characters');
        return;
      }
      if (cleanToken.length < 10) {
        debugPrint('[Update] Invalid token format - too short');
        return;
      }
    }

    _githubToken = cleanToken;
    debugPrint('[Update] Saving GitHub token (${cleanToken?.length ?? 0} chars)...');

    // Try Hive first (works on AI boxes)
    final hive = HiveStorageService.instance;
    if (hive.isAvailable) {
      try {
        if (token != null && token.isNotEmpty) {
          await hive.saveSetting('github_token', token);
          debugPrint('[Update] Token saved to Hive');
          return;
        } else {
          await hive.deleteSetting('github_token');
          debugPrint('[Update] Token removed from Hive');
          return;
        }
      } catch (e) {
        debugPrint('[Update] Hive save failed: $e');
      }
    }

    // Try SharedPreferences as fallback
    try {
      final prefs = await SharedPreferences.getInstance();
      if (token != null && token.isNotEmpty) {
        await prefs.setString('github_token', token);
        debugPrint('[Update] Token saved to SharedPreferences');
      } else {
        await prefs.remove('github_token');
        debugPrint('[Update] Token removed from SharedPreferences');
      }
    } catch (e) {
      debugPrint('[Update] SharedPreferences save failed: $e');
      // Try file-based fallback
      try {
        final file = File('/data/data/com.example.carsoc/files/github_token.txt');
        if (token != null && token.isNotEmpty) {
          await file.writeAsString(token);
          debugPrint('[Update] Token saved to file');
        } else if (await file.exists()) {
          await file.delete();
          debugPrint('[Update] Token file deleted');
        }
      } catch (e2) {
        debugPrint('[Update] File save failed: $e2');
      }
    }
  }

  /// Load GitHub token from storage
  Future<void> loadGitHubToken() async {
    debugPrint('[Update] Loading GitHub token...');

    // Try Hive first (works on AI boxes)
    final hive = HiveStorageService.instance;
    if (hive.isAvailable) {
      try {
        _githubToken = hive.getSetting<String>('github_token');
        if (_githubToken != null) {
          debugPrint('[Update] Token loaded from Hive');
          return;
        }
      } catch (e) {
        debugPrint('[Update] Hive load failed: $e');
      }
    }

    // Try SharedPreferences as fallback
    try {
      final prefs = await SharedPreferences.getInstance();
      _githubToken = prefs.getString('github_token');
      if (_githubToken != null) {
        debugPrint('[Update] Token loaded from SharedPreferences');
        return;
      }
    } catch (e) {
      debugPrint('[Update] SharedPreferences load failed: $e');
    }

    // Try file-based fallback
    try {
      final file = File('/data/data/com.example.carsoc/files/github_token.txt');
      if (await file.exists()) {
        _githubToken = await file.readAsString();
        debugPrint('[Update] Token loaded from file');
        return;
      }
    } catch (e) {
      debugPrint('[Update] File load failed: $e');
    }

    debugPrint('[Update] No token found in any storage');
  }

  /// Check for updates from GitHub
  Future<bool> checkForUpdates() async {
    _error = null;
    debugPrint('[Update] Checking for updates from $_apiUrl');
    try {
      // Load token if not already loaded
      if (_githubToken == null) {
        await loadGitHubToken();
      }

      // Use hardcoded version (package_info_plus fails on AAOS)
      final currentVersion = appVersion;
      debugPrint('[Update] Current version: $currentVersion');

      final headers = <String, String>{
        'Accept': 'application/vnd.github.v3+json',
        'User-Agent': 'XPCarData/$currentVersion', // Required by GitHub API
      };

      // Add auth token if available (increases rate limit from 60 to 5000/hour)
      if (_githubToken != null && _githubToken!.isNotEmpty) {
        // Validate token format - must be alphanumeric with underscores, typically starts with ghp_ or gho_
        final token = _githubToken!.trim();
        if (token.length >= 10 && RegExp(r'^[a-zA-Z0-9_]+$').hasMatch(token)) {
          headers['Authorization'] = 'token $token';
          debugPrint('[Update] Using GitHub token (${token.length} chars, starts with ${token.substring(0, 4)}...)');
        } else {
          debugPrint('[Update] Invalid token format, ignoring (length=${token.length})');
          // Clear invalid token
          _githubToken = null;
        }
      }

      final response = await http.get(
        Uri.parse(_apiUrl),
        headers: headers,
      ).timeout(
        const Duration(seconds: 15),
        onTimeout: () {
          debugPrint('[Update] Request timed out');
          throw Exception('Request timed out');
        },
      );

      debugPrint('[Update] Response status: ${response.statusCode}');

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        _latestRelease = ReleaseInfo.fromJson(data);
        debugPrint('[Update] Latest release: ${_latestRelease!.version}, APK URL: ${_latestRelease!.apkDownloadUrl}');

        _updateAvailable = _isNewerVersion(
          _latestRelease!.version,
          currentVersion,
        );
        debugPrint('[Update] Update available: $_updateAvailable (${_latestRelease!.version} > $currentVersion)');

        return _updateAvailable;
      } else if (response.statusCode == 404) {
        _error = 'No releases found on GitHub';
        debugPrint('[Update] Error: $_error');
        return false;
      } else if (response.statusCode == 403) {
        _error = 'GitHub rate limit exceeded. Try again in an hour, or add a GitHub token in Settings.';
        debugPrint('[Update] Error: $_error');
        return false;
      } else if (response.statusCode == 401) {
        _error = 'Invalid GitHub token. Please check your token in Settings.';
        debugPrint('[Update] Error: $_error');
        return false;
      } else {
        _error = 'GitHub API error: ${response.statusCode}';
        debugPrint('[Update] Error: $_error');
        return false;
      }
    } catch (e) {
      _error = 'Failed to check for updates: $e';
      debugPrint('[Update] Exception: $e');
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

  /// Download the latest APK (or ZIP containing APK)
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

      // Get download directory with AI box fallback
      Directory? directory;
      try {
        directory = await getExternalStorageDirectory();
      } catch (e) {
        debugPrint('[Update] getExternalStorageDirectory failed: $e');
      }
      if (directory == null) {
        try {
          directory = await getTemporaryDirectory();
        } catch (e) {
          debugPrint('[Update] getTemporaryDirectory failed: $e');
        }
      }
      // Fallback to hardcoded path for AI boxes
      directory ??= Directory('/data/data/com.example.carsoc/cache');
      if (!await directory.exists()) {
        await directory.create(recursive: true);
      }
      debugPrint('[Update] Using download directory: ${directory.path}');

      // Determine file extension based on release type
      final isZip = _latestRelease!.isZipFile;
      final downloadPath = isZip
          ? '${directory.path}/XPCarData-${_latestRelease!.version}.zip'
          : '${directory.path}/XPCarData-${_latestRelease!.version}.apk';

      final file = File(downloadPath);
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

      // If it's a ZIP file, extract the APK
      String apkPath;
      if (isZip) {
        apkPath = await _extractApkFromZip(downloadPath, directory.path);
        // Clean up the zip file after extraction
        try {
          await file.delete();
        } catch (_) {}
      } else {
        apkPath = downloadPath;
      }

      _downloadedApkPath = apkPath;
      _isDownloading = false;
      _downloadProgress = 1.0;

      return apkPath;
    } catch (e) {
      _error = 'Download failed: $e';
      _isDownloading = false;
      return null;
    }
  }

  /// Extract APK from a ZIP file
  Future<String> _extractApkFromZip(String zipPath, String outputDir) async {
    final bytes = await File(zipPath).readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);

    // Find the APK file in the archive
    for (final file in archive) {
      if (file.isFile && file.name.toLowerCase().endsWith('.apk')) {
        final apkPath = '$outputDir/${file.name}';
        final outputFile = File(apkPath);
        await outputFile.writeAsBytes(file.content as List<int>);
        return apkPath;
      }
    }

    throw Exception('No APK found in ZIP file');
  }

  /// Get current app version info
  String getCurrentVersion() {
    // Use hardcoded version (package_info_plus fails on AAOS)
    return 'v$appVersion';
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
  final bool isZipFile;
  final DateTime publishedAt;

  ReleaseInfo({
    required this.version,
    required this.name,
    required this.body,
    required this.htmlUrl,
    this.apkDownloadUrl,
    this.apkSize,
    this.isZipFile = false,
    required this.publishedAt,
  });

  factory ReleaseInfo.fromJson(Map<String, dynamic> json) {
    // Find APK or ZIP asset (prefer APK, fall back to ZIP)
    String? downloadUrl;
    int? fileSize;
    bool isZip = false;
    final assets = json['assets'] as List<dynamic>? ?? [];

    // First pass: look for APK
    for (final asset in assets) {
      final name = asset['name'] as String? ?? '';
      if (name.toLowerCase().endsWith('.apk')) {
        downloadUrl = asset['browser_download_url'] as String?;
        fileSize = asset['size'] as int?;
        isZip = false;
        break;
      }
    }

    // Second pass: if no APK found, look for ZIP containing APK
    if (downloadUrl == null) {
      for (final asset in assets) {
        final name = asset['name'] as String? ?? '';
        if (name.toLowerCase().endsWith('.zip')) {
          downloadUrl = asset['browser_download_url'] as String?;
          fileSize = asset['size'] as int?;
          isZip = true;
          break;
        }
      }
    }

    return ReleaseInfo(
      version: (json['tag_name'] as String? ?? '').replaceFirst('v', ''),
      name: json['name'] as String? ?? 'Unknown',
      body: json['body'] as String? ?? '',
      htmlUrl: json['html_url'] as String? ?? '',
      apkDownloadUrl: downloadUrl,
      apkSize: fileSize,
      isZipFile: isZip,
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

import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

class AppReleaseInfo {
  final String tagName;
  final String cleanVersion;
  final int buildNumber;
  final String releaseName;
  final String releaseNotes;
  final DateTime? publishedAt;
  final String? apkUrl;
  final String? apkFileName;
  final int apkSize;
  final bool isUpdateAvailable;
  final String currentVersion;
  final bool noReleaseFound;

  const AppReleaseInfo({
    required this.tagName,
    required this.cleanVersion,
    required this.buildNumber,
    required this.releaseName,
    required this.releaseNotes,
    this.publishedAt,
    this.apkUrl,
    this.apkFileName,
    this.apkSize = 0,
    required this.isUpdateAvailable,
    required this.currentVersion,
    this.noReleaseFound = false,
  });

  String get formattedApkSize {
    if (apkSize <= 0) return '54.1 MB';
    final mb = apkSize / (1024 * 1024);
    return '${mb.toStringAsFixed(1)} MB';
  }
}

class AppUpdateService {
  static const String repoOwner = 'Arib0510';
  static const String repoName = 'ClassRoom_Automation';
  static const String latestReleaseUrl =
      'https://api.github.com/repos/$repoOwner/$repoName/releases/latest';
  static const String rawPubspecUrl =
      'https://raw.githubusercontent.com/$repoOwner/$repoName/main/Classroom/pubspec.yaml';
  static const String directApkUrl =
      'https://raw.githubusercontent.com/$repoOwner/$repoName/main/releases/app-release.apk';
  static const String tagsUrl =
      'https://api.github.com/repos/$repoOwner/$repoName/tags';

  final Dio _dio = Dio(
    BaseOptions(
      headers: {
        'Accept': 'application/vnd.github.v3+json',
        'User-Agent': 'ClassPulse-IoT-App',
      },
      connectTimeout: const Duration(seconds: 12),
      receiveTimeout: const Duration(seconds: 30),
    ),
  );

  /// Check GitHub releases for the latest version and compare with current app version
  Future<AppReleaseInfo> checkForUpdate() async {
    final packageInfo = await PackageInfo.fromPlatform();
    final currentVerStr = '${packageInfo.version}+${packageInfo.buildNumber}';

    // 1. Try formal GitHub Releases API first
    try {
      final response = await _dio.get(latestReleaseUrl);

      if (response.statusCode == 200 && response.data != null) {
        final data = response.data as Map<String, dynamic>;
        final tagName = (data['tag_name'] as String?)?.trim() ?? '';
        final releaseName = (data['name'] as String?) ?? tagName;
        final releaseNotes = (data['body'] as String?) ?? 'No changelog provided.';
        final publishedStr = data['published_at'] as String?;
        final publishedAt = publishedStr != null ? DateTime.tryParse(publishedStr) : null;

        // Find APK asset
        String? apkUrl;
        String? apkFileName;
        int apkSize = 0;

        final assets = (data['assets'] as List<dynamic>?) ?? [];
        for (final asset in assets) {
          final name = (asset['name'] as String?) ?? '';
          if (name.toLowerCase().endsWith('.apk')) {
            apkUrl = asset['browser_download_url'] as String?;
            apkFileName = name;
            apkSize = (asset['size'] as num?)?.toInt() ?? 0;
            break;
          }
        }

        if (apkUrl != null) {
          final parsed = _parseTagVersion(tagName);
          final isAvailable = _compareVersions(
            remoteVer: parsed.version,
            remoteBuild: parsed.build,
            currentVer: packageInfo.version,
            currentBuild: int.tryParse(packageInfo.buildNumber) ?? 0,
          );

          return AppReleaseInfo(
            tagName: tagName,
            cleanVersion: parsed.version,
            buildNumber: parsed.build,
            releaseName: releaseName,
            releaseNotes: releaseNotes,
            publishedAt: publishedAt,
            apkUrl: apkUrl,
            apkFileName: apkFileName,
            apkSize: apkSize,
            isUpdateAvailable: isAvailable,
            currentVersion: currentVerStr,
            noReleaseFound: false,
          );
        }
      }
    } catch (e) {
      debugPrint('[AppUpdateService] GitHub releases API check notice: $e');
    }

    // 2. Direct GitHub Repository & Pubspec OTA Fallback (No GitHub Release draft needed)
    final fallback = await _checkRawRepoFallback(packageInfo, currentVerStr);
    if (fallback != null) {
      return fallback;
    }

    return AppReleaseInfo(
      tagName: 'v${packageInfo.version}+${packageInfo.buildNumber}',
      cleanVersion: packageInfo.version,
      buildNumber: int.tryParse(packageInfo.buildNumber) ?? 0,
      releaseName: 'Up to Date',
      releaseNotes: 'You are running the latest version.',
      apkUrl: directApkUrl,
      apkFileName: 'app-release.apk',
      apkSize: 56709983,
      isUpdateAvailable: false,
      currentVersion: currentVerStr,
      noReleaseFound: true,
    );
  }

  /// Fallback that queries the raw pubspec.yaml and direct APK in the GitHub repo
  Future<AppReleaseInfo?> _checkRawRepoFallback(PackageInfo packageInfo, String currentVerStr) async {
    try {
      final response = await _dio.get(rawPubspecUrl);
      if (response.statusCode == 200 && response.data != null) {
        final text = response.data.toString();
        final match = RegExp(r'^version:\s*(\d+\.\d+\.\d+)(?:\+(\d+))?', multiLine: true).firstMatch(text);
        if (match != null) {
          final remoteVer = match.group(1)!;
          final remoteBuild = match.group(2) != null ? int.tryParse(match.group(2)!) ?? 0 : 0;
          final currentBuild = int.tryParse(packageInfo.buildNumber) ?? 0;

          final isAvailable = _compareVersions(
            remoteVer: remoteVer,
            remoteBuild: remoteBuild,
            currentVer: packageInfo.version,
            currentBuild: currentBuild,
          );

          int apkSize = 56709983;
          try {
            final head = await _dio.head(directApkUrl);
            final cl = head.headers.value('content-length');
            if (cl != null) apkSize = int.tryParse(cl) ?? apkSize;
          } catch (_) {}

          return AppReleaseInfo(
            tagName: 'v$remoteVer+$remoteBuild',
            cleanVersion: remoteVer,
            buildNumber: remoteBuild,
            releaseName: 'ClassPulse v$remoteVer (Build $remoteBuild)',
            releaseNotes: 'OTA distribution build from GitHub repository main branch.\n\n• Cyberpunk animated OTA updater\n• Live vision watchdog & zero-occupancy offline guard\n• Multi-zone edge-triggered occupancy control',
            apkUrl: directApkUrl,
            apkFileName: 'app-release.apk',
            apkSize: apkSize,
            isUpdateAvailable: isAvailable,
            currentVersion: currentVerStr,
            noReleaseFound: false,
          );
        }
      }
    } catch (e) {
      debugPrint('[AppUpdateService] Raw pubspec fallback error: $e');
    }

    // Try tags endpoint
    try {
      final tagsResp = await _dio.get(tagsUrl);
      if (tagsResp.statusCode == 200 && tagsResp.data is List && (tagsResp.data as List).isNotEmpty) {
        final firstTag = (tagsResp.data as List).first as Map<String, dynamic>;
        final tagName = firstTag['name']?.toString() ?? 'v1.0.0';
        final parsed = _parseTagVersion(tagName);
        final currentBuild = int.tryParse(packageInfo.buildNumber) ?? 0;

        final isAvailable = _compareVersions(
          remoteVer: parsed.version,
          remoteBuild: parsed.build,
          currentVer: packageInfo.version,
          currentBuild: currentBuild,
        );

        return AppReleaseInfo(
          tagName: tagName,
          cleanVersion: parsed.version,
          buildNumber: parsed.build,
          releaseName: 'ClassPulse $tagName',
          releaseNotes: 'OTA distribution build from latest tag $tagName.',
          apkUrl: directApkUrl,
          apkFileName: 'app-release.apk',
          apkSize: 56709983,
          isUpdateAvailable: isAvailable,
          currentVersion: currentVerStr,
          noReleaseFound: false,
        );
      }
    } catch (e) {
      debugPrint('[AppUpdateService] Tags fallback error: $e');
    }

    return null;
  }

  /// Download APK with progress callback
  Future<File> downloadApk({
    required String downloadUrl,
    required void Function(int received, int total) onProgress,
    CancelToken? cancelToken,
  }) async {
    final tempDir = await getTemporaryDirectory();
    final filePath = '${tempDir.path}/ClassPulse-update.apk';
    final file = File(filePath);

    if (await file.exists()) {
      try {
        await file.delete();
      } catch (e) {
        debugPrint('Failed to delete old APK: $e');
      }
    }

    await _dio.download(
      downloadUrl,
      filePath,
      cancelToken: cancelToken,
      onReceiveProgress: onProgress,
    );

    return file;
  }

  /// Open Android package installer for the downloaded APK
  Future<OpenResult> installApk(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) {
      return OpenResult(
        type: ResultType.fileNotFound,
        message: 'The installer file was not found on device.',
      );
    }

    return await OpenFilex.open(
      filePath,
      type: 'application/vnd.android.package-archive',
    );
  }

  /// Parse tag strings like "v1.2.3", "1.2.3+4", "v2.0.0-beta+5"
  ({String version, int build}) _parseTagVersion(String tag) {
    var clean = tag.trim();
    if (clean.toLowerCase().startsWith('v')) {
      clean = clean.substring(1);
    }

    int build = 0;
    if (clean.contains('+')) {
      final parts = clean.split('+');
      clean = parts[0];
      build = int.tryParse(parts[1]) ?? 0;
    }

    // Strip any trailing non-numeric pre-release tag like -beta
    if (clean.contains('-')) {
      clean = clean.split('-')[0];
    }

    return (version: clean, build: build);
  }

  /// Returns true if remote is strictly newer than current
  bool _compareVersions({
    required String remoteVer,
    required int remoteBuild,
    required String currentVer,
    required int currentBuild,
  }) {
    final remoteParts = remoteVer.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    final currentParts = currentVer.split('.').map((e) => int.tryParse(e) ?? 0).toList();

    while (remoteParts.length < 3) {
      remoteParts.add(0);
    }
    while (currentParts.length < 3) {
      currentParts.add(0);
    }

    for (int i = 0; i < 3; i++) {
      if (remoteParts[i] > currentParts[i]) return true;
      if (remoteParts[i] < currentParts[i]) return false;
    }

    if (remoteBuild > currentBuild) {
      return true;
    }

    return false;
  }
}

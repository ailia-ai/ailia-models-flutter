import 'dart:ffi';
import 'dart:io';

import 'package:ailia/ailia.dart' as ailia;
import 'package:ailia/ailia_license.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

/// SDK exceptions are also forwarded as strings by the inference workers.
bool isAiliaLicenseError(Object error) {
  final text = error.toString();
  if (text == 'Exception: License file download failed') return true;
  if (RegExp(
    r'\bAILIA_STATUS_LICENSE_(NOT_FOUND|BROKEN|EXPIRED)\b',
  ).hasMatch(text)) {
    return true;
  }
  final matches = RegExp(
    r'\b(?:ailia\w+|SetPromptJson|GetResponseJson(?:Size)?)\b[^\r\n]*?'
    r'\b(?:failed|status|error|returned)\s*:?\s*(-\d+)\b',
    caseSensitive: false,
  ).allMatches(text);
  return matches.any(
    (match) => const {
      ailia.AILIA_STATUS_LICENSE_NOT_FOUND,
      ailia.AILIA_STATUS_LICENSE_BROKEN,
      ailia.AILIA_STATUS_LICENSE_EXPIRED,
    }.contains(int.tryParse(match.group(1)!)),
  );
}

enum LicenseState { valid, expired, missing, invalid, perpetual, unavailable }

class LicenseInfo {
  const LicenseInfo(this.state, [this.expiry]);

  final LicenseState state;
  final DateTime? expiry;

  /// Read the same header/date line that AiliaLicense validates. Never expose
  /// the remaining license contents (signature and user data) in the UI.
  factory LicenseInfo.parse(String? contents, {DateTime? now}) {
    if (contents == null) return const LicenseInfo(LicenseState.missing);
    final normalized = contents.replaceAll('\r\n', '\n');
    if (!normalized.startsWith(AiliaLicense.licenseFileFormat)) {
      return const LicenseInfo(LicenseState.invalid);
    }
    final line = normalized.split('\n')[2];
    final match = RegExp(r'(\d{4})/(\d{2})/(\d{2})').firstMatch(line);
    if (match == null) return const LicenseInfo(LicenseState.invalid);
    final year = int.parse(match[1]!);
    final month = int.parse(match[2]!);
    final day = int.parse(match[3]!);
    final expiry = DateTime(year, month, day, 23, 59, 59);
    if (expiry.year != year || expiry.month != month || expiry.day != day) {
      return const LicenseInfo(LicenseState.invalid);
    }
    return LicenseInfo(
      (now ?? DateTime.now()).isAfter(expiry)
          ? LicenseState.expired
          : LicenseState.valid,
      expiry,
    );
  }

  String get label {
    final date = expiry;
    if (date != null) {
      final formatted =
          '${date.year.toString().padLeft(4, '0')}/'
          '${date.month.toString().padLeft(2, '0')}/'
          '${date.day.toString().padLeft(2, '0')}';
      return state == LicenseState.expired ? '$formatted（期限切れ）' : formatted;
    }
    return switch (state) {
      LicenseState.perpetual => '無期限',
      LicenseState.missing => 'ファイルなし',
      LicenseState.invalid => 'ファイルが無効です',
      _ => '取得できません',
    };
  }
}

/// The native SDK version and the license used by AiliaLicense on this platform.
class SdkStatus extends ChangeNotifier {
  SdkStatus({
    String Function()? readVersion,
    Future<String?> Function()? readLicense,
  }) : _readVersion = readVersion ?? _nativeVersion,
       _readLicense = readLicense ?? _licenseContents;

  static final SdkStatus instance = SdkStatus();
  final String Function() _readVersion;
  final Future<String?> Function() _readLicense;
  String? version;
  LicenseInfo? license;
  Future<void>? _refreshing;

  Future<void> refresh() async {
    final pending = _refreshing;
    if (pending != null) return pending;
    final future = _load();
    _refreshing = future;
    try {
      await future;
    } finally {
      _refreshing = null;
    }
  }

  Future<void> _load() async {
    try {
      version = _readVersion();
    } catch (_) {
      // An unavailable native library must not prevent the home screen opening.
      version = null;
    }
    if (version?.contains('perpetual_license') == true) {
      license = const LicenseInfo(LicenseState.perpetual);
    } else {
      try {
        license = LicenseInfo.parse(await _readLicense());
      } catch (_) {
        license = const LicenseInfo(LicenseState.unavailable);
      }
    }
    notifyListeners();
  }

  static String _nativeVersion() {
    final DynamicLibrary library;
    if (Platform.isIOS) {
      library = DynamicLibrary.process();
    } else {
      final name = Platform.isWindows
          ? 'ailia.dll'
          : Platform.isMacOS
          ? 'libailia.dylib'
          : 'libailia.so';
      library = DynamicLibrary.open(name);
    }
    // ailiaGetVersion returns a borrowed, null-terminated string.
    return ailia
        .ailiaFFI(library)
        .ailiaGetVersion()
        .cast<Utf8>()
        .toDartString();
  }

  static Future<String?> _licenseContents() async {
    // Keep this in sync with AiliaLicense._getLicenseFolderPath(). Reading the
    // status does not download a license or create directories.
    final home = Platform.environment['HOME'];
    final folder = Platform.isMacOS
        ? p.join(home!, 'Library', 'SHALO')
        : Platform.isLinux
        ? p.join(home!, '.shalo')
        : Directory.current.path;
    final file = File(p.join(folder, 'AILIA.lic'));
    return await file.exists() ? file.readAsString() : null;
  }
}

/// Refresh the title bar after the SDK has checked or renewed the license.
Future<void> checkAiliaLicense() async {
  try {
    await AiliaLicense.checkAndDownloadLicense();
  } finally {
    await SdkStatus.instance.refresh();
  }
}

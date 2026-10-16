import 'dart:ffi';
import 'dart:io';

import 'package:ailia/ailia.dart' as ailia;
import 'package:ailia/ailia_license.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

// Read only the expiry line; license validation is left to the SDK.
String licenseExpiry(String? contents) {
  if (contents == null) return 'ファイルなし';
  final normalized = contents.replaceAll('\r\n', '\n');
  if (!normalized.startsWith(AiliaLicense.licenseFileFormat)) {
    return '取得できません';
  }
  return RegExp(
        r'\d{4}/\d{2}/\d{2}',
      ).firstMatch(normalized.split('\n')[2])?.group(0) ??
      '取得できません';
}

/// Read-only information for the title bar. No license checks or downloads.
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
  String expiry = '確認中…';

  Future<void> refresh() async {
    try {
      version = _readVersion();
    } catch (_) {
      version = null;
    }
    if (version?.contains('perpetual_license') == true) {
      expiry = '無期限';
    } else {
      try {
        expiry = licenseExpiry(await _readLicense());
      } catch (_) {
        expiry = '取得できません';
      }
    }
    notifyListeners();
  }

  static String _nativeVersion() {
    final library = Platform.isIOS
        ? DynamicLibrary.process()
        : DynamicLibrary.open(
            Platform.isWindows
                ? 'ailia.dll'
                : Platform.isMacOS
                ? 'libailia.dylib'
                : 'libailia.so',
          );
    // This pointer is owned by the SDK.
    return ailia
        .ailiaFFI(library)
        .ailiaGetVersion()
        .cast<Utf8>()
        .toDartString();
  }

  static Future<String?> _licenseContents() async {
    // Use the same location as AiliaLicense, without creating or updating files.
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

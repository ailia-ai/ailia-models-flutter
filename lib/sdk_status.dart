import 'dart:ffi';
import 'dart:io';

import 'package:ailia/ailia.dart' as ailia;
import 'package:ailia/ailia_license.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

// Read only the expiry line; license validation is left to the SDK.
String licenseExpiry(String? contents) {
  if (contents == null) return 'Not found';
  final normalized = contents.replaceAll('\r\n', '\n');
  if (!normalized.startsWith(AiliaLicense.licenseFileFormat)) {
    return 'Unavailable';
  }
  return RegExp(
        r'\d{4}/\d{2}/\d{2}',
      ).firstMatch(normalized.split('\n')[2])?.group(0) ??
      'Unavailable';
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
  String get version => _readVersion();
  String expiry = 'Loading...';

  /// Perpetual licenses and development builds of the SDK do not expire.
  static bool isPerpetual(String version) =>
      version.contains('perpetual_license') ||
      version.toLowerCase().contains('develop');

  Future<void> refresh() async {
    if (isPerpetual(version)) {
      expiry = 'Perpetual';
    } else {
      expiry = licenseExpiry(await _readLicense());
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

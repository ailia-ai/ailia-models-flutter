// Native smoke tests that exercise the ailia FFI bindings without the GUI.
//
// Prerequisites:
//   flutter build windows   (the DLLs are taken from the build bundle)
// Optional:
//   The gemma2 chat test runs only when the model file has already been
//   downloaded by the app (Documents/ailia MODELS flutter/models).
//
// Run with:
//   flutter test test/ailia_native_test.dart
@Timeout(Duration(minutes: 5))

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ailia/ailia_model.dart';
import 'package:ailia_llm/ailia_llm_model.dart';
import 'package:ailia_models_flutter/large_language_model/large_language_model.dart';

String? _findBundleDir() {
  for (final arch in ['arm64', 'x64']) {
    final dir = Directory('build/windows/$arch/runner/Release');
    if (File('${dir.path}/ailia.dll').existsSync()) {
      return dir.absolute.path;
    }
  }
  return null;
}

// Adds the build bundle to the DLL search path so that bare-name
// DynamicLibrary.open calls (ailia_llm.dll etc.) resolve.
void _setDllDirectory(String path) {
  final kernel32 = DynamicLibrary.open('kernel32.dll');
  final setDllDirectoryW = kernel32.lookupFunction<
      Int32 Function(Pointer<Utf16>),
      int Function(Pointer<Utf16>)>('SetDllDirectoryW');
  final p = path.toNativeUtf16();
  try {
    expect(setDllDirectoryW(p), isNot(0));
  } finally {
    malloc.free(p);
  }
}

String _modelCachePath(String filename) {
  final profile = Platform.environment['USERPROFILE']!;
  return '$profile\\Documents\\ailia MODELS flutter\\models\\$filename';
}

void main() {
  late String bundleDir;

  setUpAll(() {
    expect(Platform.isWindows, isTrue,
        reason: 'These smoke tests are Windows-only for now.');

    final dir = _findBundleDir();
    expect(dir, isNotNull,
        reason: 'Build bundle not found. Run "flutter build windows" first.');
    bundleDir = dir!;
    _setDllDirectory(bundleDir);

    // Under flutter_test the ailia package loads the relative path
    // windows/x64/ailia.dll. SetDllDirectory removes the current directory
    // from the search path, so relative paths resolve against the bundle
    // directory instead — place a copy there.
    final testDll = File('$bundleDir/windows/x64/ailia.dll');
    if (!testDll.existsSync()) {
      testDll.parent.createSync(recursive: true);
      File('$bundleDir/ailia.dll').copySync(testDll.path);
    }
  });

  test('ailia environment list is not empty', () {
    final envList = AiliaModel.getEnvironmentList();
    expect(envList, isNotEmpty);
    for (final env in envList) {
      // ignore: avoid_print
      print('ailia env ${env.id}: ${env.name}');
    }
  });

  test('ailia_llm backend list is not empty', () {
    final backendList = AiliaLLMModel.getBackendList();
    expect(backendList, isNotEmpty);
    // ignore: avoid_print
    print('ailia_llm backends: $backendList');
  });

  test('gemma2 chat produces a reply', () {
    final modelFile = File(_modelCachePath('gemma-2-2b-it-Q4_K_M.gguf'));
    if (!modelFile.existsSync()) {
      markTestSkipped('gemma-2-2b-it-Q4_K_M.gguf not downloaded; '
          'run the gemma2 demo in the app once to cache it.');
      return;
    }

    final llm = LargeLanguageModel();
    llm.open(modelFile);
    try {
      llm.setSystemPrompt('語尾に「わん」をつけてください。');
      final reply = llm.chat('こんにちは。');
      // ignore: avoid_print
      print('gemma2 reply: $reply');
      expect(reply.trim(), isNotEmpty);
    } finally {
      llm.close();
    }
  });
}

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

import 'package:ailia/ailia_license.dart';
import 'package:ailia/ailia_model.dart';
import 'package:ailia_llm/ailia_llm_model.dart';
import 'package:ailia_models_flutter/diffusion/sdxl/sdxl.dart';
import 'package:ailia_models_flutter/large_language_model/large_language_model.dart';
import 'package:image/image.dart' as img;

String? _findBundleDir() {
  for (final arch in ['arm64', 'x64']) {
    for (final config in ['Release', 'Debug']) {
      final dir = Directory('build/windows/$arch/runner/$config');
      if (File('${dir.path}/ailia.dll').existsSync()) {
        return dir.absolute.path;
      }
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

  setUpAll(() async {
    expect(Platform.isWindows, isTrue,
        reason: 'These smoke tests are Windows-only for now.');

    final dir = _findBundleDir();
    expect(dir, isNotNull,
        reason: 'Build bundle not found. Run "flutter build windows" first.');
    bundleDir = dir!;
    _setDllDirectory(bundleDir);

    // ailiaCreate needs a valid license; refresh the CWD AILIA.lic if
    // expired and place a copy next to the DLLs, where ailia.dll looks
    // for it under flutter_test (the app exe directory in production).
    await AiliaLicense.checkAndDownloadLicense();
    final lic = File('AILIA.lic');
    if (lic.existsSync()) {
      lic.copySync('$bundleDir/AILIA.lic');
    }

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

  test('sdxl txt2img produces an image', () async {
    final unetFile = File(_modelCachePath('sdxl\\sdxl_unet_fp16.onnx'));
    if (!unetFile.existsSync()) {
      markTestSkipped('sdxl models not downloaded; '
          'run the sdxl demo in the app once to cache them.');
      return;
    }

    final steps =
        int.tryParse(Platform.environment['AILIA_SDXL_TEST_STEPS'] ?? '') ?? 2;
    final sdxl = StableDiffusionXL(seed: 42);
    sdxl.open(_modelCachePath(''));
    try {
      final stopwatch = Stopwatch()..start();
      final image = await sdxl.txt2img(
        prompt:
            'Astronaut in a jungle, cold color palette, muted colors, detailed, 8k',
        width: 512,
        height: 512,
        steps: steps,
        onStatus: (status) async {
          // ignore: avoid_print
          print('sdxl [${stopwatch.elapsed}]: $status');
        },
      );
      expect(image.width, 512);
      expect(image.height, 512);

      // The output must not be a flat color.
      final colors = <int>{};
      for (int y = 0; y < image.height; y += 32) {
        for (int x = 0; x < image.width; x += 32) {
          final p = image.getPixel(x, y);
          colors.add((p.r.toInt() << 16) | (p.g.toInt() << 8) | p.b.toInt());
        }
      }
      expect(colors.length, greaterThan(8));

      final out = File('build/sdxl_test_output.png');
      out.writeAsBytesSync(img.encodePng(image));
      // ignore: avoid_print
      print('sdxl output saved: ${out.absolute.path}');

      // A second run must reuse the resident models (no reload) and
      // exercise the per-step VAE preview decode.
      int previews = 0;
      final second = await sdxl.txt2img(
        prompt: 'A cat sitting on a chair, watercolor',
        width: 512,
        height: 512,
        steps: 2,
        previewEachStep: true,
        onStep: (completedSteps, totalSteps, preview) async {
          if (preview != null) {
            previews++;
            expect(preview.width, 512);
          }
          // ignore: avoid_print
          print('sdxl [${stopwatch.elapsed}]: '
              'step $completedSteps/$totalSteps preview=${preview != null}');
        },
        onStatus: (status) async {
          // ignore: avoid_print
          print('sdxl [${stopwatch.elapsed}]: $status');
        },
      );
      expect(second.width, 512);
      expect(previews, 2);
    } finally {
      sdxl.close();
    }
  }, timeout: const Timeout(Duration(minutes: 60)));

  test('sdxl img2img produces an image', () async {
    final encoderFile = File(_modelCachePath('sdxl\\sdxl_vae_encoder.onnx'));
    if (!encoderFile.existsSync()) {
      markTestSkipped('sdxl models not downloaded; '
          'run the sdxl img2img demo in the app once to cache them.');
      return;
    }

    final steps =
        int.tryParse(Platform.environment['AILIA_SDXL_TEST_STEPS'] ?? '') ?? 2;
    final input = img.copyResizeCropSquare(
        img.decodeImage(File('assets/astronaut.jpg').readAsBytesSync())!,
        size: 512);

    final sdxl = StableDiffusionXL(seed: 42);
    sdxl.open(_modelCachePath(''));
    try {
      final stopwatch = Stopwatch()..start();
      final image = await sdxl.img2img(
        image: input,
        prompt: 'Astronaut in a red spacesuit standing in a jungle, '
            'cold color palette, muted colors, detailed, 8k',
        steps: steps,
        strength: 0.85,
        onStatus: (status) async {
          // ignore: avoid_print
          print('sdxl [${stopwatch.elapsed}]: $status');
        },
      );
      expect(image.width, 512);
      expect(image.height, 512);

      final out = File('build/sdxl_test_img2img_output.png');
      out.writeAsBytesSync(img.encodePng(image));
      // ignore: avoid_print
      print('sdxl img2img output saved: ${out.absolute.path}');
    } finally {
      sdxl.close();
    }
  }, timeout: const Timeout(Duration(minutes: 60)));

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

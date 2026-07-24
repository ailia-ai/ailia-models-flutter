import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ailia/ailia_model.dart';
import 'package:ailia_tokenizer/ailia_tokenizer.dart'
    as ailia_tokenizer_dart;
import 'package:ailia_tokenizer/ailia_tokenizer_model.dart';
import 'package:image/image.dart' as img;

/// Called between pipeline stages so the page can show progress (and
/// yield to the UI before the next blocking inference call).
typedef SdxlStatusCallback = Future<void> Function(String status);

/// Called once before sampling (completedSteps = 0) and once after
/// each completed step. [preview] is the current denoised estimate
/// decoded by the VAE, only set when previewEachStep is enabled.
typedef SdxlStepCallback = Future<void> Function(
    int completedSteps, int totalSteps, img.Image? preview);

/// Stable Diffusion XL base 1.0 (text2img / img2img), ported from
/// ailia-models/diffusion/sdxl.
///
/// The UNet and both text encoders always use the fp16 weights; the
/// VAE stays fp32 because the SDXL VAE overflows in fp16. The sigma
/// schedule, denoiser preconditioning, classifier free guidance and
/// the Euler sampler are not part of the ONNX graphs, so they are
/// implemented here.
///
/// Each network is opened lazily on its first use and then stays
/// resident until [close], so a repeated run skips the multi-GB model
/// load.
class StableDiffusionXL {
  static const int _tokenBos = 49406;
  static const int _tokenEos = 49407;
  // OpenCLIP bigG pads with "!" (id 0) instead of <|endoftext|>.
  static const int _tokenPadBigG = 0;
  static const int _maxTokens = 77;

  static const int _contextDim = 2048; // CLIP-L 768 + OpenCLIP bigG 1280
  static const int _pooledDim = 1280;
  static const int _vectorDim = 2816; // pooled + orig/crop/target size emb
  static const int _sizeEmbDim = 256; // per scalar (timestep embedding)

  // Same flags as ailia.get_memory_mode(reduce_constant=True,
  // ignore_input_with_initializer=True, reuse_interstage=True) in the
  // Python sample.
  static const int _memoryMode = 11;

  static const String remoteFolder = 'sdxl';
  static const String _localDir = 'sdxl';
  static const String _clipLFile = 'sdxl_text_encoder_clip_l_fp16.onnx';
  static const String _openClipFile =
      'sdxl_text_encoder_open_clip_bigg_fp16.onnx';
  static const String _unetFile = 'sdxl_unet_fp16.onnx';
  static const String _vaeDecoderFile = 'sdxl_vae_decoder.onnx';
  static const String _vaeEncoderFile = 'sdxl_vae_encoder.onnx';

  /// Marker file for the home screen's "downloaded" badge.
  static const String markerFile = '$_localDir/$_unetFile';

  /// (remote folder, local path) pairs in the DemoSession
  /// downloadModelList format. The *_weights.pb files are referenced
  /// from the .onnx files as external data and just need to sit next
  /// to them.
  static List<String> getModelList({required bool img2img}) {
    final files = [
      _clipLFile,
      'sdxl_text_encoder_clip_l_fp16_weights.pb',
      _openClipFile,
      'sdxl_text_encoder_open_clip_bigg_fp16_weights.pb',
      _unetFile,
      'sdxl_unet_fp16_weights.pb',
      _vaeDecoderFile,
      'sdxl_vae_decoder_weights.pb',
      if (img2img) _vaeEncoderFile,
      if (img2img) 'sdxl_vae_encoder_weights.pb',
    ];
    final list = <String>[];
    for (final file in files) {
      list.add(remoteFolder);
      list.add('$_localDir/$file');
    }
    return list;
  }

  String _modelDir = '';
  int _envId = 0;
  bool _available = false;

  AiliaTokenizerModel? _tokenizer; // CLIP ViT-L
  AiliaTokenizerModel? _tokenizer2; // OpenCLIP ViT-bigG

  // Lazily opened, then kept resident until close().
  AiliaModel? _clipLNet;
  AiliaModel? _openClipNet;
  AiliaModel? _unetNet;
  AiliaModel? _vaeDecoderNet;
  AiliaModel? _vaeEncoderNet;

  final math.Random _random;

  StableDiffusionXL({int? seed})
      : _random = seed == null ? math.Random() : math.Random(seed);

  /// [modelDir] is the directory that contains the downloaded sdxl/
  /// folder (the app model directory).
  void open(String modelDir, {int envId = 0}) {
    close();
    _modelDir = modelDir.endsWith('/') || modelDir.endsWith('\\')
        ? modelDir.substring(0, modelDir.length - 1)
        : modelDir;
    _envId = envId;

    // Both tokenizers use the CLIP BPE vocabulary built into ailia
    // Tokenizer (the same default as the Python sample); only the pad
    // token differs and padding is applied in _tokenize.
    _tokenizer = AiliaTokenizerModel();
    _tokenizer!.openFile(ailia_tokenizer_dart.AILIA_TOKENIZER_TYPE_CLIP);
    _tokenizer2 = AiliaTokenizerModel();
    _tokenizer2!.openFile(ailia_tokenizer_dart.AILIA_TOKENIZER_TYPE_CLIP);

    _available = true;
  }

  void close() {
    if (!_available) {
      return;
    }
    _tokenizer?.close();
    _tokenizer = null;
    _tokenizer2?.close();
    _tokenizer2 = null;
    _clipLNet?.close();
    _clipLNet = null;
    _openClipNet?.close();
    _openClipNet = null;
    _unetNet?.close();
    _unetNet = null;
    _vaeDecoderNet?.close();
    _vaeDecoderNet = null;
    _vaeEncoderNet?.close();
    _vaeEncoderNet = null;
    _available = false;
  }

  // ---------------------------------------------------------------------
  // Public pipelines
  // ---------------------------------------------------------------------

  Future<img.Image> txt2img({
    required String prompt,
    int width = 1024,
    int height = 1024,
    int steps = 20,
    double guidanceScale = 5.0,
    bool previewEachStep = false,
    SdxlStepCallback? onStep,
    required SdxlStatusCallback onStatus,
  }) async {
    _checkAvailable();
    final cond = await _buildConditioning(prompt, height, width, onStatus);

    final sigmas = _sigmaSchedule(steps);
    final latentHeight = height ~/ 8;
    final latentWidth = width ~/ 8;
    final xInit = _randn(4 * latentHeight * latentWidth);

    final latent = await _runUNet(
        xInit, sigmas, cond, guidanceScale, latentHeight, latentWidth,
        previewEachStep: previewEachStep, onStep: onStep, onStatus: onStatus);
    return _decode(latent, latentHeight, latentWidth, onStatus);
  }

  /// [image] is resized by the caller; each side must be a multiple
  /// of 64. [strength] (0-1) is the fraction of the sigma schedule to
  /// run: 1.0 keeps nothing of the input image.
  Future<img.Image> img2img({
    required img.Image image,
    required String prompt,
    int steps = 20,
    double guidanceScale = 5.0,
    double strength = 0.85,
    bool previewEachStep = false,
    SdxlStepCallback? onStep,
    required SdxlStatusCallback onStatus,
  }) async {
    _checkAvailable();
    final width = image.width;
    final height = image.height;
    if (width % 64 != 0 || height % 64 != 0) {
      throw Exception('img2img input must be a multiple of 64 pixels');
    }
    final cond = await _buildConditioning(prompt, height, width, onStatus);

    final z = await _encodeImage(image, onStatus);

    // Only the low-noise part of the schedule is run, so the input
    // image survives in proportion to (1 - strength).
    final sigmas = _img2imgSigmaSchedule(steps, strength);

    // Put sigma[0] worth of noise on the input latent. The sampler
    // scales x_init by sqrt(1 + sigma0^2), so divide it out here.
    final scale = math.sqrt(1.0 + sigmas[0] * sigmas[0]);
    final xInit = Float32List(z.length);
    for (int i = 0; i < z.length; i++) {
      xInit[i] = (z[i] + _nextGaussian() * sigmas[0]) / scale;
    }

    final latentHeight = height ~/ 8;
    final latentWidth = width ~/ 8;
    final latent = await _runUNet(
        xInit, sigmas, cond, guidanceScale, latentHeight, latentWidth,
        previewEachStep: previewEachStep, onStep: onStep, onStatus: onStatus);
    return _decode(latent, latentHeight, latentWidth, onStatus);
  }

  // ---------------------------------------------------------------------
  // Text conditioning
  // ---------------------------------------------------------------------

  void _checkAvailable() {
    if (!_available) {
      throw Exception('StableDiffusionXL is not opened');
    }
  }

  AiliaModel _openNet(String file) {
    final net = AiliaModel();
    net.openFile('$_modelDir/$_localDir/$file',
        envId: _envId, memoryMode: _memoryMode);
    return net;
  }

  AiliaModel _clipL() => _clipLNet ??= _openNet(_clipLFile);
  AiliaModel _openClip() => _openClipNet ??= _openNet(_openClipFile);
  AiliaModel _unet() => _unetNet ??= _openNet(_unetFile);
  AiliaModel _vaeDecoder() => _vaeDecoderNet ??= _openNet(_vaeDecoderFile);
  AiliaModel _vaeEncoder() => _vaeEncoderNet ??= _openNet(_vaeEncoderFile);

  AiliaTensor _tensor(Float32List data, List<int> shape) {
    final tensor = AiliaTensor();
    tensor.data = data;
    tensor.shape.dim = shape.length;
    final dims = [1, 1, 1, 1]; // x (innermost), y, z, w
    for (int i = 0; i < shape.length; i++) {
      dims[i] = shape[shape.length - 1 - i];
    }
    tensor.shape.x = dims[0];
    tensor.shape.y = dims[1];
    tensor.shape.z = dims[2];
    tensor.shape.w = dims[3];
    return tensor;
  }

  /// HF-style CLIP tokenization: BOS + tokens + EOS, truncated and
  /// padded to 77. The ONNX takes int64 ids; ailia converts the float
  /// input data to the blob type.
  Float32List _tokenize(
      AiliaTokenizerModel tokenizer, String prompt, int padToken) {
    var ids = tokenizer.encode(prompt).toList();
    if (ids.isEmpty || ids.first != _tokenBos) {
      ids.insert(0, _tokenBos);
    }
    if (ids.last != _tokenEos) {
      ids.add(_tokenEos);
    }
    if (ids.length > _maxTokens) {
      ids = ids.sublist(0, _maxTokens);
      ids[_maxTokens - 1] = _tokenEos;
    }
    final data = Float32List(_maxTokens);
    for (int i = 0; i < _maxTokens; i++) {
      data[i] = (i < ids.length ? ids[i] : padToken).toDouble();
    }
    return data;
  }

  /// Sinusoidal timestep embedding of a single scalar (dim 256).
  void _timestepEmbedding(double value, Float32List out, int offset) {
    const half = _sizeEmbDim ~/ 2;
    for (int i = 0; i < half; i++) {
      final freq = math.exp(-math.log(10000.0) * i / half);
      out[offset + i] = math.cos(value * freq);
      out[offset + half + i] = math.sin(value * freq);
    }
  }

  /// Embeds each scalar in [values] to 256 dims and concatenates them
  /// into [out] at [offset] (the Python sample's embed_nd).
  void _embedNd(List<double> values, Float32List out, int offset) {
    for (int i = 0; i < values.length; i++) {
      _timestepEmbedding(values[i], out, offset + i * _sizeEmbDim);
    }
  }

  /// Runs both text encoders and builds the batched (uncond, cond)
  /// UNet conditioning. The base model zeroes the unconditional text
  /// embedding instead of encoding a negative prompt.
  Future<_Conditioning> _buildConditioning(String prompt, int height,
      int width, SdxlStatusCallback onStatus) async {
    // CLIP ViT-L/14: penultimate hidden state (77, 768)
    await onStatus('Encoding prompt (CLIP ViT-L)...');
    final inputIds = _tokenize(_tokenizer!, prompt, _tokenEos);
    final clipLHidden = _clipL().run([
      _tensor(inputIds, [1, _maxTokens])
    ])[0]
        .data;

    // OpenCLIP ViT-bigG/14: penultimate hidden state (77, 1280) +
    // pooled (1280)
    await onStatus('Encoding prompt (OpenCLIP bigG)...');
    final inputIds2 = _tokenize(_tokenizer2!, prompt, _tokenPadBigG);
    final openClipOutput = _openClip().run([
      _tensor(inputIds2, [1, _maxTokens])
    ]);
    final openClipHidden = openClipOutput[0].data;
    final pooled = openClipOutput[1].data;

    // crossattn: CLIP-L(768) and OpenCLIP(1280) concatenated on the
    // feature dim -> (77, 2048). Batched as (2, 77, 2048) with the
    // zeroed uncond half first.
    final context = Float32List(2 * _maxTokens * _contextDim);
    const condOffset = _maxTokens * _contextDim;
    for (int t = 0; t < _maxTokens; t++) {
      final base = condOffset + t * _contextDim;
      context.setRange(base, base + 768, clipLHidden, t * 768);
      context.setRange(base + 768, base + _contextDim, openClipHidden,
          t * _pooledDim);
    }

    // vector(y): pooled(1280) + orig(512) + crop(512) + target(512)
    // = 2816, batched as (2, 2816). The size embeddings are shared by
    // cond and uncond; only the pooled part is zeroed on the uncond
    // side.
    final sizeEmb = Float32List(3 * 2 * _sizeEmbDim);
    _embedNd([height.toDouble(), width.toDouble()], sizeEmb, 0); // orig
    _embedNd([0.0, 0.0], sizeEmb, 2 * _sizeEmbDim); // crop_coords_top_left
    _embedNd([height.toDouble(), width.toDouble()], sizeEmb,
        4 * _sizeEmbDim); // target

    final vector = Float32List(2 * _vectorDim);
    for (int b = 0; b < 2; b++) {
      vector.setRange(
          b * _vectorDim + _pooledDim, (b + 1) * _vectorDim, sizeEmb);
    }
    vector.setRange(_vectorDim, _vectorDim + _pooledDim, pooled);

    return _Conditioning(context, vector);
  }

  // ---------------------------------------------------------------------
  // Sigma schedule (LegacyDDPMDiscretization)
  // ---------------------------------------------------------------------

  static const int _numTimesteps = 1000;

  late final Float64List _alphasCumprod = () {
    final alphasCumprod = Float64List(_numTimesteps);
    const linearStart = 0.00085;
    const linearEnd = 0.0120;
    final sqrtStart = math.sqrt(linearStart);
    final sqrtEnd = math.sqrt(linearEnd);
    double cumprod = 1.0;
    for (int i = 0; i < _numTimesteps; i++) {
      final sqrtBeta =
          sqrtStart + (sqrtEnd - sqrtStart) * i / (_numTimesteps - 1);
      cumprod *= 1.0 - sqrtBeta * sqrtBeta;
      alphasCumprod[i] = cumprod;
    }
    return alphasCumprod;
  }();

  /// The fixed 1000-entry table used to quantize a sigma to its
  /// timestep index (ascending: index 0 = lowest sigma).
  late final Float64List _discreteSigmas = () {
    final sigmas = Float64List(_numTimesteps);
    for (int i = 0; i < _numTimesteps; i++) {
      final ac = _alphasCumprod[i];
      sigmas[i] = math.sqrt((1 - ac) / ac);
    }
    return sigmas;
  }();

  /// Descending sigma schedule for [steps] steps with a trailing 0.
  List<double> _sigmaSchedule(int steps) {
    // np.linspace(999, 0, steps, endpoint=False) floored to int gives
    // the timesteps in descending order.
    final sigmas = <double>[];
    for (int i = 0; i < steps; i++) {
      final t = (999.0 - 999.0 * i / steps).truncate();
      final ac = _alphasCumprod[t];
      sigmas.add(math.sqrt((1 - ac) / ac));
    }
    sigmas.add(0.0);
    return sigmas;
  }

  /// Keeps only the low-noise fraction of the schedule (the Python
  /// sample's img2img_sigmas).
  List<double> _img2imgSigmaSchedule(int steps, double strength) {
    final ascending = _sigmaSchedule(steps).reversed.toList();
    final keep =
        math.max((strength * ascending.length).truncate(), 1);
    return ascending.sublist(0, keep).reversed.toList();
  }

  // ---------------------------------------------------------------------
  // Sampler (EulerEDMSampler, s_churn=0) with CFG
  // ---------------------------------------------------------------------

  Future<Float32List> _runUNet(
    Float32List xInit,
    List<double> sigmas,
    _Conditioning cond,
    double guidanceScale,
    int latentHeight,
    int latentWidth, {
    required bool previewEachStep,
    required SdxlStepCallback? onStep,
    required SdxlStatusCallback onStatus,
  }) async {
    if (_unetNet == null) {
      await onStatus('Loading UNet (about 5 GB, this takes a while)...');
    }
    final unet = _unet();
    if (previewEachStep && _vaeDecoderNet == null) {
      // Load the preview decoder up front so the first step's preview
      // does not stall on the model load.
      await onStatus('Loading VAE decoder...');
      _vaeDecoder();
    }

    final n = 4 * latentHeight * latentWidth;
    final x = Float32List(n);
    final initScale = math.sqrt(1.0 + sigmas[0] * sigmas[0]);
    for (int i = 0; i < n; i++) {
      x[i] = xInit[i] * initScale;
    }

    final totalSteps = sigmas.length - 1;
    await onStep?.call(0, totalSteps, null);
    for (int step = 0; step < totalSteps; step++) {
      final sigma = sigmas[step];
      final denoised =
          _denoise(unet, x, sigma, cond, guidanceScale, latentHeight,
              latentWidth);

      // to_d + Euler step (no churn noise).
      final dt = sigmas[step + 1] - sigma;
      for (int i = 0; i < n; i++) {
        x[i] += dt * (x[i] - denoised[i]) / sigma;
      }

      // The preview decodes the denoised (x0) estimate, which is what
      // the final latent converges to, rather than the noisy x.
      final preview = previewEachStep
          ? _runVaeDecoder(denoised, latentHeight, latentWidth)
          : null;
      await onStep?.call(step + 1, totalSteps, preview);
    }
    return x;
  }

  /// One denoiser evaluation: uncond/cond batched into one UNet run,
  /// EDM preconditioning around it and CFG mixing after it.
  Float32List _denoise(AiliaModel unet, Float32List x, double sigma,
      _Conditioning cond, double guidanceScale, int latentHeight,
      int latentWidth) {
    final n = 4 * latentHeight * latentWidth;

    // Quantize sigma to the discrete table, then precondition.
    int idx = 0;
    double best = double.infinity;
    for (int i = 0; i < _numTimesteps; i++) {
      final d = (sigma - _discreteSigmas[i]).abs();
      if (d < best) {
        best = d;
        idx = i;
      }
    }
    final sigmaQ = _discreteSigmas[idx];
    final cOut = -sigmaQ;
    final cIn = 1.0 / math.sqrt(sigmaQ * sigmaQ + 1.0);

    final sample = Float32List(2 * n);
    for (int i = 0; i < n; i++) {
      final v = x[i] * cIn;
      sample[i] = v;
      sample[n + i] = v;
    }
    final timesteps =
        Float32List.fromList([idx.toDouble(), idx.toDouble()]);

    final output = unet.run([
      _tensor(sample, [2, 4, latentHeight, latentWidth]),
      _tensor(timesteps, [2]),
      _tensor(cond.context, [2, _maxTokens, _contextDim]),
      _tensor(cond.vector, [2, _vectorDim]),
    ]);
    final eps = output[0].data;

    // denoised = eps * c_out + x, then CFG: x_u + scale * (x_c - x_u).
    final denoised = Float32List(n);
    for (int i = 0; i < n; i++) {
      final uncond = eps[i] * cOut + x[i];
      final condV = eps[n + i] * cOut + x[i];
      denoised[i] = uncond + guidanceScale * (condV - uncond);
    }
    return denoised;
  }

  // ---------------------------------------------------------------------
  // VAE
  // ---------------------------------------------------------------------

  /// Encodes an RGB image to a latent sample (img2img). The ONNX
  /// returns scale_factor-applied mean/std; only the
  /// reparameterization happens here.
  Future<Float32List> _encodeImage(
      img.Image image, SdxlStatusCallback onStatus) async {
    await onStatus('Encoding input image (VAE)...');
    final width = image.width;
    final height = image.height;
    final rgb =
        image.convert(numChannels: 3).getBytes(order: img.ChannelOrder.rgb);
    final pixel = Float32List(3 * height * width);
    for (int c = 0; c < 3; c++) {
      for (int i = 0; i < height * width; i++) {
        pixel[c * height * width + i] = rgb[i * 3 + c] / 127.5 - 1.0;
      }
    }

    final output = _vaeEncoder().run([
      _tensor(pixel, [1, 3, height, width])
    ]);
    final mean = output[0].data;
    final std = output[1].data;
    final z = Float32List(mean.length);
    for (int i = 0; i < mean.length; i++) {
      z[i] = mean[i] + std[i] * _nextGaussian();
    }
    return z;
  }

  Future<img.Image> _decode(Float32List latent, int latentHeight,
      int latentWidth, SdxlStatusCallback onStatus) async {
    await onStatus('Decoding image (VAE)...');
    return _runVaeDecoder(latent, latentHeight, latentWidth);
  }

  img.Image _runVaeDecoder(
      Float32List latent, int latentHeight, int latentWidth) {
    final output = _vaeDecoder().run([
      _tensor(latent, [1, 4, latentHeight, latentWidth])
    ]);
    final data = output[0].data; // (1, 3, H, W) in [-1, 1]

    final width = latentWidth * 8;
    final height = latentHeight * 8;
    final image = img.Image(width: width, height: height);
    final plane = width * height;
    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        final i = y * width + x;
        int channel(int c) =>
            (((data[c * plane + i] + 1.0) / 2.0).clamp(0.0, 1.0) * 255)
                .round();
        image.setPixelRgb(x, y, channel(0), channel(1), channel(2));
      }
    }
    return image;
  }

  // ---------------------------------------------------------------------
  // Random
  // ---------------------------------------------------------------------

  double _nextGaussian() {
    double u1 = _random.nextDouble();
    while (u1 == 0.0) {
      u1 = _random.nextDouble();
    }
    final u2 = _random.nextDouble();
    return math.sqrt(-2.0 * math.log(u1)) * math.cos(2.0 * math.pi * u2);
  }

  Float32List _randn(int n) {
    final data = Float32List(n);
    for (int i = 0; i < n; i++) {
      data[i] = _nextGaussian();
    }
    return data;
  }
}

/// Batched (uncond, cond) UNet conditioning: context is (2, 77, 2048)
/// crossattn, vector is (2, 2816) y. The uncond half is index 0.
class _Conditioning {
  final Float32List context;
  final Float32List vector;
  _Conditioning(this.context, this.vector);
}

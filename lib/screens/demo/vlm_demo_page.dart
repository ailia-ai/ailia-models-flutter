import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../backend_state.dart';
import '../../large_language_model/generation_metrics.dart';
import '../../large_language_model/multimodal_large_language_model.dart';
import '../../large_language_model/mtp.dart';
import '../../model_catalog.dart';
import '../../utils/download_model.dart';
import 'camera_input.dart';
import 'chat_bubble.dart';
import 'demo_session.dart';
import 'mtp_switch.dart';
import 'still_image.dart';

const _sampleImageUrl =
    "https://storage.googleapis.com/ailia-models/misc/sample_image.jpg";

/// VLM (image + text) chat: the first question carries the sample image
/// or a still frame captured from the camera, and follow-up questions
/// continue the same conversation about that image.
class VlmDemoPage extends StatefulWidget {
  const VlmDemoPage({super.key, required this.model});

  final ModelInfo model;

  @override
  State<VlmDemoPage> createState() => _VlmDemoPageState();
}

class _VlmDemoPageState extends State<VlmDemoPage>
    with SafeSetStateMixin, MtpToggleMixin {
  final DemoSession _session = DemoSession();
  final CameraInput _camera = CameraInput();
  final MultimodalLargeLanguageModel _vlm = MultimodalLargeLanguageModel();
  final ScrollController _scrollController = ScrollController();

  final TextEditingController _queryController =
      TextEditingController(text: 'この画像を簡潔に説明してください。');

  final List<ChatTurn> _turns = [];

  /// Whether the conversation already holds its image; only the first
  /// message carries one.
  bool _imageSent = false;

  /// Backend / MTP the conversation runs on; a change reopens the model,
  /// which starts a new conversation.
  (String, bool)? _conversationConfig;

  bool _useCamera = false;
  ui.Image? _image;

  @override
  void initState() {
    super.initState();
    _loadSampleImage();
    // Automation hook: AILIA_AUTO_RUN=1 sends the query once the page is up
    // and reports the outcome on stdout (used together with
    // AILIA_OPEN_MODEL and AILIA_SCREENSHOT).
    if (Platform.environment['AILIA_AUTO_RUN'] == '1') {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        await _send();
        debugPrint('AILIA_AUTO_RUN reply: ${_turns.lastOrNull?.text}');
        debugPrint('AILIA_AUTO_RUN result: ${_session.result}');
        debugPrint('AILIA_AUTO_RUN error: ${_session.errorText}');
      });
    }
  }

  @override
  void dispose() {
    _queryController.dispose();
    _scrollController.dispose();
    _camera.dispose();
    // Stop the inference isolate if a run is still in flight.
    _vlm.cancel();
    _session.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      }
    });
  }

  /// Shows the demo's sample image (downloaded, not bundled) above the
  /// conversation.
  Future<void> _loadSampleImage() async {
    try {
      final imageFile = await MultimodalLargeLanguageModel.downloadFile(
          _sampleImageUrl, await getModelPath("sample_image.jpg"));
      final loaded = await decodeImageFromList(await imageFile.readAsBytes());
      safeSetState(() {
        _image = loaded;
      });
    } catch (_) {
      // The image is downloaded again when the first message is sent.
    }
  }

  /// Switching between the sample image and the camera starts a new
  /// conversation; returning to the camera resumes the live preview.
  Future<void> _switchSource(bool useCamera) async {
    _clearChat();
    if (useCamera) {
      safeSetState(() {
        _useCamera = true;
        _image = null;
      });
      await _camera.open();
    } else {
      await _camera.close();
      safeSetState(() {
        _useCamera = false;
      });
      _loadSampleImage();
    }
  }

  void _clearChat() {
    _vlm.clearHistory();
    // The next conversation captures a new frame from the live preview.
    _camera.clearCapture();
    _session.showResult('');
    safeSetState(() {
      _turns.clear();
      _imageSent = false;
    });
  }

  /// Drops the bubbles before [current] after the worker started a new
  /// conversation (context full).
  void _keepOnly(ChatTurn current) {
    safeSetState(() {
      _turns.removeRange(0, _turns.indexOf(current));
    });
  }

  /// Returns the image for the first message of a conversation, or null
  /// for a text-only follow-up question.
  Future<String?> _nextImage() async {
    if (_imageSent) return null;
    if (_useCamera) {
      // The captured frame freezes the preview for the whole conversation.
      if (_camera.capturedPath == null) await _camera.captureStill();
      final captured = _camera.capturedPath;
      if (captured == null) throw StateError('Camera capture failed');
      return captured;
    }
    final file = await MultimodalLargeLanguageModel.downloadFile(
        _sampleImageUrl, await getModelPath("sample_image.jpg"));
    return file.path;
  }

  Future<void> _send() async {
    final query = _queryController.text.trim();
    if (query.isEmpty || _session.processing) return;
    await _session.run(() async {
      final backend = BackendState.instance.selectedLlmBackend.value;
      final modelList = _vlm.getModelList(widget.model.id, mtp);
      if (!await _session.downloadModelList(modelList) || !mounted) return;
      final modelFile = File(await getModelPath(modelList[1]));
      final mmprojFile = File(await getModelPath(modelList[3]));
      final useMtp = modelList.length > 4;
      final mtpFile = useMtp ? File(await getModelPath(modelList[5])) : null;
      if (_conversationConfig != (backend, useMtp)) {
        // The model is reopened, so the conversation starts over.
        _conversationConfig = (backend, useMtp);
        _vlm.clearHistory();
        _turns.clear();
        _imageSent = false;
      }
      final imagePath = await _nextImage();
      if (!mounted) return;

      final user = ChatTurn.user(query);
      final reply = ChatTurn.assistant();
      _queryController.clear();
      safeSetState(() {
        _turns
          ..add(user)
          ..add(reply);
      });
      _scrollToBottom();

      final watch = Stopwatch()..start();
      int lastPaintMs = 0;
      double? ttftMs;
      double? tps;
      String? mtpError;
      try {
        reply.text = await _vlm.chatWithImageIsolate(
          model: modelFile,
          mmproj: mmprojFile,
          backend: backend,
          nCtx: MultimodalLargeLanguageModel.contextSize(widget.model.id),
          systemPrompt: '',
          inputText: query,
          imagePath: imagePath,
          mtpAssistant: mtpFile,
          onModelLoading: () =>
              _session.setStatus('Loading model with selected backend...'),
          onModelLoaded: (error) {
            mtpError = error;
            if (imagePath != null) _imageSent = true;
            _session.setStatus(
                imagePath == null ? 'Generating...' : 'Image Processing...');
          },
          onHistoryReset: () => _keepOnly(user),
          onDelta: (delta) {
            if (reply.text.isEmpty) _session.clearStatus();
            reply.text += delta;
            if (watch.elapsedMilliseconds - lastPaintMs >= 33) {
              lastPaintMs = watch.elapsedMilliseconds;
              safeSetState(() {});
              _scrollToBottom();
            }
          },
          onMetrics: (firstMs, tokensPerSecond) {
            ttftMs = firstMs;
            tps = tokensPerSecond;
          },
        );
      } catch (_) {
        // A failed turn closes the model and its conversation.
        _session.clearStatus();
        _conversationConfig = null;
        safeSetState(() {
          _turns.clear();
          // Resend the same image (the camera frame stays frozen).
          _imageSent = false;
        });
        rethrow;
      }
      _session.clearStatus();
      safeSetState(() {});
      _scrollToBottom();
      _session.showResult('processing time : ${watch.elapsedMilliseconds} ms\n'
          'TTFT: ${formatTtft(ttftMs)}\n'
          'TPS: ${formatTps(tps)} tokens/s\n'
          '${mtpStatusText(requested: useMtp, error: mtpError)}');
    });
  }

  /// Image / Web Camera selector followed by the MTP toggle on one row.
  Widget _buildSourceSelector() {
    // Rebuilt with the session so the selector is disabled while generating.
    return ListenableBuilder(
      listenable: _session,
      builder: (context, _) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (CameraInput.supported)
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(
                    value: false,
                    label: Text('Image'),
                    icon: Icon(Icons.image)),
                ButtonSegment(
                    value: true,
                    label: Text('Web Camera'),
                    icon: Icon(Icons.videocam)),
              ],
              selected: {_useCamera},
              onSelectionChanged: _session.processing
                  ? null
                  : (selection) {
                      _switchSource(selection.first);
                    },
            ),
          if (_useCamera) ...[
            const SizedBox(width: 12),
            CameraDeviceSelector(input: _camera),
          ],
          if (supportsMtp(widget.model.id)) ...[
            const SizedBox(width: 12),
            ListenableBuilder(
              listenable: _session,
              builder: (context, _) => MtpSwitch(
                value: mtp,
                onChanged: _session.processing
                    ? null
                    : (value) => safeSetState(() {
                          mtp = value;
                        }),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildImage(BuildContext context) {
    final image = _image;
    if (image == null) {
      return const SizedBox.shrink();
    }
    return StillImageBox(image: image);
  }

  Widget _buildChat() {
    return ListenableBuilder(
      listenable: _session,
      builder: (context, _) => DemoPanel(
        child: Column(
          children: [
            Align(
              alignment: Alignment.centerRight,
              child: IconButton(
                tooltip: 'Clear conversation',
                onPressed:
                    _session.processing || _turns.isEmpty ? null : _clearChat,
                icon: const Icon(Icons.delete_sweep, size: 20),
              ),
            ),
            for (final turn in _turns) ChatBubble(turn: turn),
            const SizedBox(height: 8),
            ChatInputRow(
              controller: _queryController,
              label: 'Query',
              onSend: _session.processing ? null : _send,
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return DemoPageScaffold(
      model: widget.model,
      session: _session,
      scrollController: _scrollController,
      children: [
        if (CameraInput.supported || supportsMtp(widget.model.id))
          _buildSourceSelector(),
        const SizedBox(height: 8),
        if (_useCamera) CameraPreviewView(input: _camera),
        _buildImage(context),
        _buildChat(),
      ],
    );
  }
}

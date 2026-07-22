import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../model_catalog.dart';
import '../../natural_language_processing/fugumt.dart';
import '../../natural_language_processing/multilingual_e5.dart';
import '../../utils/download_model.dart';
import 'demo_session.dart';

/// Natural language processing demos: FuguMT translation and the
/// multilingual-e5 text embedding similarity.
class NlpDemoPage extends StatefulWidget {
  const NlpDemoPage({super.key, required this.model});

  final ModelInfo model;

  @override
  State<NlpDemoPage> createState() => _NlpDemoPageState();
}

class _NlpDemoPageState extends State<NlpDemoPage> {
  final DemoSession _session = DemoSession();

  // Source text for the translation demos.
  late final TextEditingController _translateController =
      TextEditingController(text: widget.model.defaultInputText ?? '');

  // Multilingual-E5: one query compared against three reference texts.
  final TextEditingController _e5QueryController =
      TextEditingController(text: 'Hello.');
  final List<TextEditingController> _e5RefControllers = [
    TextEditingController(text: 'こんにちは。'),
    TextEditingController(text: 'Today is good day.'),
    TextEditingController(text: '水をマレーシアから買わなくてはならない。'),
  ];

  bool get _isE5Model => widget.model.id == 'multilingual-e5';

  @override
  void dispose() {
    _translateController.dispose();
    _e5QueryController.dispose();
    for (final controller in _e5RefControllers) {
      controller.dispose();
    }
    _session.dispose();
    super.dispose();
  }

  Future<void> _run() => _session.run(() async {
        switch (widget.model.id) {
          case "multilingual-e5":
            await _runMultilingualE5();
            break;
          case "fugumt-en-ja":
            await _runFuguMT(jaEn: false);
            break;
          case "fugumt-ja-en":
            await _runFuguMT(jaEn: true);
            break;
        }
      });

  Future<void> _runMultilingualE5() async {
    final files = await _session.downloadModelFiles(const [
      ('multilingual-e5', 'multilingual-e5-base.onnx'),
      ('multilingual-e5', 'sentencepiece.bpe.model'),
    ]);
    if (files == null) {
      return;
    }
    NaturalLanguageProcessingMultilingualE5 e5 =
        NaturalLanguageProcessingMultilingualE5();
    e5.open(files[0], files[1], selectedEnvId);
    final query = _e5QueryController.text.trim();
    final references = _e5RefControllers
        .map((c) => c.text.trim())
        .where((t) => t.isNotEmpty)
        .toList();
    int startTime = DateTime.now().millisecondsSinceEpoch;
    final queryEmbedding = e5.textEmbedding(query);
    final scores = [
      for (final reference in references)
        e5.cosSimilarity(queryEmbedding, e5.textEmbedding(reference)),
    ];
    int endTime = DateTime.now().millisecondsSinceEpoch;
    String profileText =
        "processing time : ${endTime - startTime} ms";
    e5.close();
    double best = scores.reduce(math.max);
    final lines = [
      for (int i = 0; i < references.length; i++)
        "${scores[i] == best ? '★' : '　'} ${scores[i].toStringAsFixed(3)}  ${references[i]}",
    ];
    _session.showResult("${lines.join('\n')}\n$profileText");
  }

  Future<void> _runFuguMT({required bool jaEn}) async {
    NaturalLanguageProcessingFuguMT fuguMT = NaturalLanguageProcessingFuguMT();
    List<String> modelList = fuguMT.getModelList(jaEn);
    if (!await _session.downloadModelList(modelList)) {
      return;
    }

    File encoderFile;
    File? decoderFile;
    File sourceFile;
    File targetFile;
    if (jaEn) {
      encoderFile = File(await getModelPath("fugumt-ja-en/encoder_model.onnx"));
      decoderFile = File(await getModelPath("fugumt-ja-en/decoder_model.onnx"));
      sourceFile = File(await getModelPath("fugumt-ja-en/source.spm"));
      targetFile = File(await getModelPath("fugumt-ja-en/target.spm"));
    } else {
      encoderFile =
          File(await getModelPath("fugumt-en-ja/seq2seq-lm-with-past.onnx"));
      decoderFile = null;
      sourceFile = File(await getModelPath("fugumt-en-ja/source.spm"));
      targetFile = File(await getModelPath("fugumt-en-ja/target.spm"));
    }

    int startTime = DateTime.now().millisecondsSinceEpoch;
    String targetText = _translateController.text.trim();
    String outputText = fuguMT.translate(targetText, encoderFile, decoderFile,
        sourceFile, targetFile, jaEn, selectedEnvId);
    int endTime = DateTime.now().millisecondsSinceEpoch;
    String profileText =
        "processing time : ${endTime - startTime} ms";

    _session.showResult("$outputText\n$profileText");
  }

  Widget _buildTranslateField() {
    return DemoPanel(
      child: TextField(
        controller: _translateController,
        decoration: const InputDecoration(
          labelText: 'Text to translate',
          border: OutlineInputBorder(),
        ),
        minLines: 1,
        maxLines: 3,
      ),
    );
  }

  Widget _buildE5Fields() {
    return DemoPanel(
      child: Column(
        children: [
          for (int i = 0; i < _e5RefControllers.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: TextField(
                controller: _e5RefControllers[i],
                decoration: InputDecoration(
                  labelText: 'Reference ${i + 1}',
                  border: const OutlineInputBorder(),
                ),
              ),
            ),
          const SizedBox(height: 16),
          TextField(
            controller: _e5QueryController,
            decoration: const InputDecoration(
              labelText: 'Query',
              border: OutlineInputBorder(),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return DemoPageScaffold(
      model: widget.model,
      session: _session,
      children: [
        _isE5Model ? _buildE5Fields() : _buildTranslateField(),
        DemoRunButton(session: _session, onPressed: _run),
      ],
    );
  }
}

import 'dart:io';

import 'package:ailia/ailia_license.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' show basename;

import '../../backend_state.dart';
import '../../model_catalog.dart';
import '../../utils/download_model.dart';

/// The ailia environment selected in the top bar.
int get selectedEnvId => BackendState.instance.selectedEnvId.value;

/// setState guarded against calls after dispose. Model downloads,
/// audio streams and camera callbacks may complete after the page has
/// been closed.
mixin SafeSetStateMixin<T extends StatefulWidget> on State<T> {
  void safeSetState(VoidCallback fn) {
    if (!mounted) {
      return;
    }
    setState(fn);
  }
}

/// Run state shared by every demo page: the progress status, download
/// progress, error text and the inference result, plus the model file
/// download helpers that report into it. The page scaffold listens and
/// rebuilds the status / error / result panels when any of it changes.
class DemoSession extends ChangeNotifier {
  String status = '';
  double? downloadProgress;
  String? errorText;
  String result = '';

  /// True while a one-shot demo run is in flight (the Run button shows
  /// "Processing...").
  bool processing = false;

  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  @override
  void notifyListeners() {
    // Downloads and streams may report after the page is gone.
    if (!_disposed) {
      super.notifyListeners();
    }
  }

  void setStatus(String text) {
    status = text;
    downloadProgress = null;
    notifyListeners();
  }

  void clearStatus() {
    status = '';
    downloadProgress = null;
    notifyListeners();
  }

  void showResult(String text) {
    result = text;
    notifyListeners();
  }

  void showError(Object error) {
    errorText = "$error";
    status = '';
    downloadProgress = null;
    notifyListeners();
  }

  /// Runs one demo inference guarded by the license check and the
  /// processing flag, reporting failures into the error panel.
  Future<void> run(Future<void> Function() body) async {
    errorText = null;
    processing = true;
    notifyListeners();
    try {
      await AiliaLicense.checkAndDownloadLicense();
      await body();
    } catch (e) {
      showError(e);
    } finally {
      processing = false;
      notifyListeners();
    }
  }

  void _reportDownload(int downloaded, int total, String filename) {
    downloadProgress = total > 0 ? downloaded / total : null;
    final name = filename.isEmpty ? "" : " $filename";
    final mb = "${downloaded ~/ 1024 ~/ 1024} MB";
    status = total > 0
        ? "Downloading$name ($mb / ${total ~/ 1024 ~/ 1024} MB)"
        : "Downloading$name ($mb)";
    notifyListeners();
  }

  /// Downloads a single model file with progress display. Returns null
  /// on failure without showing an error, so the caller can decide how
  /// to report it.
  Future<File?> downloadFile(String url, String filename) async {
    errorText = null;
    setStatus("Downloading...");
    final file = await downloadModel(url, filename, null,
        (int downloaded, int total) => _reportDownload(downloaded, total, ''));
    clearStatus();
    await Future.delayed(const Duration(milliseconds: 100));
    return file;
  }

  /// Downloads the given (remote folder, filename) model files with
  /// progress display. Returns null (and shows an error) on failure.
  Future<List<File>?> downloadModelFiles(List<(String, String)> models) async {
    errorText = null;
    setStatus("Downloading...");
    final files = <File>[];
    for (final (folder, filename) in models) {
      final file = await downloadModel(
          "https://storage.googleapis.com/ailia-models/$folder/$filename",
          filename,
          null,
          (int downloaded, int total) =>
              _reportDownload(downloaded, total, filename));
      if (file == null) {
        showError("Download failed: $filename");
        return null;
      }
      files.add(file);
    }
    clearStatus();
    await Future.delayed(const Duration(milliseconds: 100));
    return files;
  }

  /// Downloads a (remote folder, local path) pair list as produced by
  /// the model classes' getModelList(). Returns false (and shows an
  /// error) when a download fails.
  Future<bool> downloadModelList(List<String> modelList) async {
    for (int i = 0; i < modelList.length; i += 2) {
      final localPath = modelList[i + 1];
      final filename = basename(localPath);
      final url =
          "https://storage.googleapis.com/ailia-models/${modelList[i]}/$filename";
      errorText = null;
      setStatus("Downloading $localPath");
      final file = await downloadModel(
          url,
          localPath,
          null,
          (int downloaded, int total) =>
              _reportDownload(downloaded, total, localPath));
      if (file == null) {
        showError("Download failed: $localPath");
        return false;
      }
    }
    clearStatus();
    return true;
  }
}

/// Width-constrained container used by all demo panels so the layout
/// adapts to narrow windows.
class DemoPanel extends StatelessWidget {
  const DemoPanel({super.key, required this.child, this.margin});

  final Widget child;
  final EdgeInsetsGeometry? margin;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxWidth: 480),
      margin: margin ?? const EdgeInsets.only(top: 8),
      child: child,
    );
  }
}

/// Common chrome shared by the demo pages: the app bar with the
/// backend selector, the category chip, the page content and the
/// status / error / result panels fed from [session].
class DemoPageScaffold extends StatelessWidget {
  const DemoPageScaffold({
    super.key,
    required this.model,
    required this.session,
    required this.children,
    this.trailing = const [],
    this.scrollController,
  });

  final ModelInfo model;
  final DemoSession session;

  /// Page content shown above the status / error / result panels.
  final List<Widget> children;

  /// Content shown below the panels (e.g. the transcript).
  final List<Widget> trailing;

  final ScrollController? scrollController;

  @override
  Widget build(BuildContext context) {
    final color = categoryColor(context, model.category);
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: Text(model.name),
        actions: [
          // ailia LLM uses its own backend list, so switch the selector.
          BackendSelector(forLlm: model.category == 'Large Language Model'),
        ],
      ),
      body: SingleChildScrollView(
        controller: scrollController,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: <Widget>[
                Chip(
                  avatar: Icon(categoryIcon(model.category),
                      size: 18, color: color),
                  label: Text(model.category),
                ),
                const SizedBox(height: 8),
                ...children,
                ListenableBuilder(
                  listenable: session,
                  builder: (context, _) => Column(
                    children: [
                      _buildStatus(),
                      _buildError(context),
                      _buildResult(context),
                    ],
                  ),
                ),
                ...trailing,
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStatus() {
    if (session.status.isEmpty) {
      return const SizedBox.shrink();
    }
    return DemoPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 8),
              Expanded(child: Text(session.status)),
            ],
          ),
          if (session.downloadProgress != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: LinearProgressIndicator(value: session.downloadProgress),
            ),
        ],
      ),
    );
  }

  Widget _buildError(BuildContext context) {
    if (session.errorText == null) {
      return const SizedBox.shrink();
    }
    final scheme = Theme.of(context).colorScheme;
    return DemoPanel(
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: scheme.errorContainer,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.error_outline, color: scheme.error),
            const SizedBox(width: 8),
            Expanded(
              child: SelectableText(
                session.errorText!,
                style: TextStyle(color: scheme.onErrorContainer),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildResult(BuildContext context) {
    if (session.result.isEmpty) {
      return const SizedBox.shrink();
    }
    return DemoPanel(
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.5),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Align(
          alignment: Alignment.centerLeft,
          child: SelectableText(session.result),
        ),
      ),
    );
  }
}

/// The Run / Stop button shared by the demo pages. Disabled while a
/// one-shot run or a download is in flight; [stopMode] switches it to
/// a Stop button while a stoppable mode (realtime inference or
/// microphone recognition) is active.
class DemoRunButton extends StatelessWidget {
  const DemoRunButton({
    super.key,
    required this.session,
    required this.onPressed,
    this.stopMode = false,
  });

  final DemoSession session;
  final VoidCallback onPressed;
  final bool stopMode;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        final busy =
            !stopMode && (session.processing || session.status.isNotEmpty);
        return Padding(
          padding: const EdgeInsets.only(top: 16),
          child: FilledButton.icon(
            style: FilledButton.styleFrom(
              minimumSize: const Size(160, 48),
            ),
            onPressed: busy ? null : onPressed,
            icon: busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(stopMode ? Icons.stop : Icons.play_arrow),
            label: Text(stopMode
                ? 'Stop'
                : busy
                    ? 'Processing...'
                    : 'Run'),
          ),
        );
      },
    );
  }
}

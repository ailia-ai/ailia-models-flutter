// download model

import 'dart:async';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:http/http.dart' as http;

Future<Directory> getDocumentsDirectory(String subFolder) async {
  var doc = await getApplicationDocumentsDirectory();
  var basePath = p.join(doc.path, 'ailia MODELS flutter');
  final docDir = Directory(basePath);
  if (!docDir.existsSync()) {
    docDir.createSync();
  }
  basePath = p.join(basePath, subFolder);
  final subDir = Directory(basePath);
  if (!subDir.existsSync()) {
    subDir.createSync();
  }
  return subDir;
}

Future<String> getModelPath(String path) async {
  Directory tempDir = await getDocumentsDirectory("models");
  String tempPath = tempDir.path;
  var filePath = '$tempPath/$path';
  return filePath;
}

Future<File?> downloadModel(
    String url, String filename, Function(File)? downloadCallback, Function? progressCallback) async {
  var filePath = await getModelPath(filename);
  final file = File(filePath);
  if (file.existsSync()) {
    downloadCallback?.call(file);
    return file;
  }

  // create the folder if not exists.
  final Directory dir = Directory(p.dirname(filePath));
  if (!dir.existsSync()) {
    await dir.create(recursive: true);
  }

  var httpClient = http.Client();
  var request = http.Request('GET', Uri.parse(url));
  var response = httpClient.send(request);

  int downloaded = 0;
  final stopwatch = Stopwatch()..start();

  var tempFilename = '$filePath.tmp';
  File tempFile = File(tempFilename);
  IOSink tempFileSink = tempFile.openWrite();
  bool hasIOError = false;
  dynamic ioError;

  final completer = Completer();

  response.asStream().listen((http.StreamedResponse r) {
    tempFileSink.done.catchError((e) {
      hasIOError = true;
      ioError = e;
    });

    r.stream.listen(
      (List<int> chunk) {
        final speed =
            0; //getDownloadSpeed(bytes: downloaded, stopwatch: stopwatch);

        //progressCallback(filename, speed, chunk.length);

        if (!hasIOError) {
          tempFileSink.add(chunk);
        } else {
          return;
        }
        downloaded += chunk.length;
        progressCallback?.call(downloaded, r.contentLength ?? 0);
      },
      onDone: () async {
        stopwatch.stop();
        final speed =
            0; //getDownloadSpeed(bytes: downloaded, stopwatch: stopwatch);

        await tempFileSink.close();

        if (hasIOError) {
          await tempFile.delete();
          throw Exception("$filename : ${ioError.toString()}");
        }

        if (r.statusCode != 200) {
          await tempFile.delete();
          throw Exception("$filename : ${r.statusCode}");
        }

        try {
          await tempFile.rename(filePath);
        } on FileSystemException catch (e) {
          await tempFile.delete();
          throw Exception("$filename : ${e.toString()}");
        }

        //progressCallback(filename, speed, 0);
        final file = File(filePath);
        downloadCallback?.call(file);
        completer.complete(file);
      },
      onError: (_) {
        stopwatch.stop();
        completer.complete(null);
      },
    );
  });

  return await completer.future;
}

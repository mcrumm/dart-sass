// Copyright 2016 Google Inc. Use of this source code is governed by an
// MIT-style license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import 'dart:async';
import 'dart:convert';
import 'dart:js_util';

import 'package:async/async.dart';
import 'package:js/js.dart';
import 'package:node_interop/fs.dart';
import 'package:node_interop/node_interop.dart';
import 'package:node_interop/stream.dart';
import 'package:path/path.dart' as p;
import 'package:source_span/source_span.dart';
import 'package:watcher/watcher.dart';

import '../exception.dart';
import '../node/chokidar.dart';

class FileSystemException {
  final String message;
  final String path;

  FileSystemException._(this.message, this.path);

  String toString() => "${p.prettyUri(p.toUri(path))}: $message";
}

class Stderr {
  final Writable _stderr;

  Stderr(this._stderr);

  void write(Object object) => _stderr.write(object.toString());

  void writeln([Object? object]) {
    _stderr.write("${object ?? ''}\n");
  }

  void flush() {}
}

String readFile(String path) {
  // TODO(nweiz): explicitly decode the bytes as UTF-8 like we do in the VM when
  // it doesn't cause a substantial performance degradation for large files. See
  // also dart-lang/sdk#25377.
  var contents = _readFile(path, 'utf8') as String;
  if (!contents.contains("�")) return contents;

  var sourceFile = SourceFile.fromString(contents, url: p.toUri(path));
  for (var i = 0; i < contents.length; i++) {
    if (contents.codeUnitAt(i) != 0xFFFD) continue;
    throw SassException("Invalid UTF-8.", sourceFile.location(i).pointSpan());
  }

  // This should be unreachable.
  return contents;
}

/// Wraps `fs.readFileSync` to throw a [FileSystemException].
Object? _readFile(String path, [String? encoding]) =>
    _systemErrorToFileSystemException(() => fs.readFileSync(path, encoding));

void writeFile(String path, String contents) =>
    _systemErrorToFileSystemException(() => fs.writeFileSync(path, contents));

void deleteFile(String path) =>
    _systemErrorToFileSystemException(() => fs.unlinkSync(path));

Future<String> readStdin() async {
  var completer = Completer<String>();
  String contents;
  var innerSink = StringConversionSink.withCallback((String result) {
    contents = result;
    completer.complete(contents);
  });
  // Node defaults all buffers to 'utf8'.
  var sink = utf8.decoder.startChunkedConversion(innerSink);
  process.stdin.on('data', allowInterop(([Object? chunk]) {
    sink.add(chunk as List<int>);
  }));
  process.stdin.on('end', allowInterop(([Object? _]) {
    // Callback for 'end' receives no args.
    assert(_ == null);
    sink.close();
  }));
  process.stdin.on('error', allowInterop(([Object? e]) {
    stderr.writeln('Failed to read from stdin');
    stderr.writeln(e);
    completer.completeError(e!);
  }));
  return completer.future;
}

/// Cleans up a Node system error's message.
String _cleanErrorMessage(JsSystemError error) {
  // The error message is of the form "$code: $text, $syscall '$path'". We just
  // want the text.
  return error.message.substring("${error.code}: ".length,
      error.message.length - ", ${error.syscall} '${error.path}'".length);
}

bool fileExists(String path) {
  return _systemErrorToFileSystemException(() {
    // `existsSync()` is faster than `statSync()`, but it doesn't clarify
    // whether the entity in question is a file or a directory. Since false
    // negatives are much more common than false positives, it works out in our
    // favor to check this first.
    if (!fs.existsSync(path)) return false;

    try {
      return fs.statSync(path).isFile();
    } catch (error) {
      var systemError = error as JsSystemError;
      if (systemError.code == 'ENOENT') return false;
      rethrow;
    }
  });
}

bool dirExists(String path) {
  return _systemErrorToFileSystemException(() {
    // `existsSync()` is faster than `statSync()`, but it doesn't clarify
    // whether the entity in question is a file or a directory. Since false
    // negatives are much more common than false positives, it works out in our
    // favor to check this first.
    if (!fs.existsSync(path)) return false;

    try {
      return fs.statSync(path).isDirectory();
    } catch (error) {
      var systemError = error as JsSystemError;
      if (systemError.code == 'ENOENT') return false;
      rethrow;
    }
  });
}

void ensureDir(String path) {
  return _systemErrorToFileSystemException(() {
    try {
      fs.mkdirSync(path);
    } catch (error) {
      var systemError = error as JsSystemError;
      if (systemError.code == 'EEXIST') return;
      if (systemError.code != 'ENOENT') rethrow;
      ensureDir(p.dirname(path));
      fs.mkdirSync(path);
    }
  });
}

Iterable<String> listDir(String path, {bool recursive = false}) {
  return _systemErrorToFileSystemException(() {
    if (!recursive) {
      return fs
          .readdirSync(path)
          .map((child) => p.join(path, child as String))
          .where((child) => !dirExists(child));
    } else {
      Iterable<String> list(String parent) =>
          fs.readdirSync(parent).expand((child) {
            var path = p.join(parent, child as String);
            return dirExists(path) ? list(path) : [path];
          });

      return list(path);
    }
  });
}

DateTime modificationTime(String path) =>
    _systemErrorToFileSystemException(() =>
        DateTime.fromMillisecondsSinceEpoch(fs.statSync(path).mtime.getTime()));

String? getEnvironmentVariable(String name) =>
    getProperty(process.env as Object, name) as String?;

/// Runs callback and converts any [JsSystemError]s it throws into
/// [FileSystemException]s.
T _systemErrorToFileSystemException<T>(T callback()) {
  try {
    return callback();
  } catch (error) {
    if (error is! JsSystemError) rethrow;
    throw FileSystemException._(_cleanErrorMessage(error), error.path);
  }
}

final stderr = Stderr(process.stderr);

/// We can't use [process.stdout.isTTY] from `node_interop` because of
/// pulyaevskiy/node-interop#93: it declares `isTTY` as always non-nullably
/// available, but in practice it's undefined if stdout isn't a TTY.
@JS('process.stdout.isTTY')
external bool? get isTTY;

@JS('process.stdin.isTTY')
external bool? get isStdinTTY;

bool get hasTerminal => isTTY == true;

bool get isWindows => process.platform == 'win32';

bool get isMacOS => process.platform == 'darwin';

bool get isNode => true;

// Node seems to support ANSI escapes on all terminals.
bool get supportsAnsiEscapes => hasTerminal;

String get currentPath => process.cwd();

int get exitCode => process.exitCode;

set exitCode(int code) => process.exitCode = code;

CancelableOperation<void> onStdinClose() {
  var completer = CancelableCompleter<void>();
  if (isStdinTTY != true) {
    process.stdin.on('end', allowInterop(() => completer.complete()));
  }
  return completer.operation;
}

Future<Stream<WatchEvent>> watchDir(String path, {bool poll = false}) {
  var watcher = chokidar.watch(
      path, ChokidarOptions(disableGlobbing: true, usePolling: poll));

  // Don't assign the controller until after the ready event fires. Otherwise,
  // Chokidar will give us a bunch of add events for files that already exist.
  StreamController<WatchEvent>? controller;
  watcher
    ..on(
        'add',
        allowInterop((String path, [void _]) =>
            controller?.add(WatchEvent(ChangeType.ADD, path))))
    ..on(
        'change',
        allowInterop((String path, [void _]) =>
            controller?.add(WatchEvent(ChangeType.MODIFY, path))))
    ..on(
        'unlink',
        allowInterop((String path) =>
            controller?.add(WatchEvent(ChangeType.REMOVE, path))))
    ..on('error', allowInterop((Object error) => controller?.addError(error)));

  var completer = Completer<Stream<WatchEvent>>();
  watcher.on('ready', allowInterop(() {
    // dart-lang/sdk#45348
    var stream = (controller = StreamController<WatchEvent>(onCancel: () {
      watcher.close();
    }))
        .stream;
    completer.complete(stream);
  }));

  return completer.future;
}

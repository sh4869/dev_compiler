// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dev_compiler.src.codegen.html_codegen;

import 'package:html5lib/dom.dart';
import 'package:html5lib/parser.dart' show parseFragment;
import 'package:logging/logging.dart' show Logger;

import 'package:dev_compiler/src/dependency_graph.dart';
import 'package:dev_compiler/src/options.dart';
import 'package:dev_compiler/src/utils.dart' show colorOf;

import 'js_codegen.dart' show jsLibraryName, jsOutputPath;

/// Emits an entry point HTML file corresponding to [inputFile] that can load
/// the code generated by the dev compiler.
///
/// This internally transforms the given HTML [document]. When compiling to
/// JavaScript, we remove any Dart script tags, add new script tags to load our
/// runtime and the compiled code, and to execute the main method of the
/// application. When compiling to Dart, we ensure that the document contains a
/// single Dart script tag, but otherwise emit the original document
/// unmodified.
String generateEntryHtml(HtmlSourceNode root, CompilerOptions options) {
  var document = root.document.clone(true);
  var scripts = document.querySelectorAll('script[type="application/dart"]');
  if (scripts.isEmpty) {
    _log.severe('No <script type="application/dart"> found in ${root.uri}');
    return null;
  }
  scripts.skip(1).forEach((s) {
    // TODO(sigmund): allow more than one Dart script tags?
    _log.warning(s.sourceSpan.message(
        'unexpected script. Only one Dart script tag allowed '
        '(see https://github.com/dart-lang/dart-dev-compiler/issues/53).',
        color: options.useColors ? colorOf('warning') : false));
    s.remove();
  });

  if (options.outputDart) return '${document.outerHtml}\n';

  var libraries = [];
  visitInPostOrder(root, (n) {
    if (n is DartSourceNode) libraries.add(n);
  }, includeParts: false);

  String mainLibraryName;
  var fragment = _loadRuntimeScripts();
  if (!options.checkSdk) fragment.nodes.add(_miniMockSdk);
  for (var lib in libraries) {
    var info = lib.info;
    if (info == null) continue;
    if (info.isEntry) mainLibraryName = jsLibraryName(info.library);
    fragment.nodes.add(_libraryInclude(jsOutputPath(info, root.uri)));
  }
  fragment.nodes.add(_invokeMain(mainLibraryName));
  scripts[0].replaceWith(fragment);
  return '${document.outerHtml}\n';
}

/// A document fragment with scripts that check for harmony features and that
/// inject our runtime.
Node _loadRuntimeScripts() => parseFragment('''
<script src="dev_compiler/runtime/harmony_feature_check.js"></script>
<script src="dev_compiler/runtime/dart_runtime.js"></script>
''');

/// A script tag that loads the .js code for a compiled library.
Node _libraryInclude(String jsUrl) =>
    parseFragment('<script src="$jsUrl"></script>\n');

/// A script tag that invokes the main function on the entry point library.
Node _invokeMain(String mainLibraryName) =>
    parseFragment('<script>$mainLibraryName.main();</script>\n');

/// A script tag with a tiny mock of the core SDK. This is just used for testing
/// some small samples.
// TODO(sigmund,jmesserly): remove.
Node get _miniMockSdk => parseFragment('''
<script>
  /* placehorder for unimplemented code libraries */
  var math = Math;
  var core = { int: { parse: Number }, print: e => console.log(e) };
  var dom = { document: document };
</script>''');
final _log = new Logger('dev_compiler.src.codegen.html_codegen');

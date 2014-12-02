library codegenerator;

import 'dart:io';

import 'package:analyzer/analyzer.dart';
import 'package:analyzer/src/generated/ast.dart';
import 'package:analyzer/src/generated/element.dart';

import 'src/static_info.dart';
import 'src/type_rules.dart';
import 'typechecker.dart';

class OutWriter {
  IOSink _sink;
  int _indent = 0;
  String _prefix = "";
  bool newline = true;

  OutWriter(String path) {
    var file = new File(path);
    file.createSync();
    _sink = file.openWrite();
  }

  void write(String string, [int indent = 0]) {
    if (indent < 0) inc(indent);
    var lines = string.split('\n');
    var length = lines.length;
    for (var i = 0; i < length - 1; ++i) {
      var prefix = (lines[i].isNotEmpty && (newline || i > 0)) ? _prefix : '';
      _sink.write('$prefix${lines[i]}\n');
    }
    var last = lines.last;
    if (last.isNotEmpty && (newline && length == 1 || length > 1)) {
      _sink.write(_prefix);
    }
    _sink.write(last);
    newline = last.isEmpty;
    if (indent > 0) inc(indent);
  }

  void inc([int n = 2]) {
    _indent = _indent + n;
    assert(_indent >= 0);
    _prefix = "".padRight(_indent);
  }

  void dec([int n = 2]) {
    _indent = _indent - n;
    assert(_indent >= 0);
    _prefix = "".padRight(_indent);
  }

  void close() {
    _sink.close();
  }
}

class UnitGenerator extends GeneralizingAstVisitor {
  final Uri uri;
  final Directory directory;
  final String libName;
  final CompilationUnit unit;
  final Map<AstNode, List<StaticInfo>> infoMap;
  final TypeRules rules;
  OutWriter out = null;

  UnitGenerator(
      this.uri, this.unit, this.directory, this.libName, this.infoMap,
          this.rules);

  DynamicInvoke _processDynamicInvoke(AstNode node) {
    DynamicInvoke result = null;
    if (infoMap.containsKey(node)) {
      var infos = infoMap[node];
      for (var info in infos) {
        if (info is DynamicInvoke) {
          assert(result == null);
          result = info;
        }
      }
      if (result != null) infos.remove(result);
    }
    return result;
  }

  void _reportUnimplementedConversions(AstNode node) {
    if (infoMap.containsKey(node) && infoMap[node].isNotEmpty) {
      out.write('/* Unimplemented: [ ');
      for (var info in infoMap[node]) {
        assert(info is Conversion);
        out.write('${info.description}');
      }
      out.write('] */ ');
    }
  }

  String path() {
    var tail = uri.pathSegments.last;
    return directory.path + Platform.pathSeparator + tail + '.js';
  }

  void generate() {
    out = new OutWriter(path());

    out.write("""
var $libName;
(function ($libName) {
""", 2);
    unit.visitChildren(this);
    out.write("""
})($libName || ($libName = {}));
""", -2);
    out.close();
  }

  bool isPublic(String name) => !name.startsWith('_');

  visitFunctionTypeAlias(FunctionTypeAlias node) {
    // TODO(vsm): Do we need to record type info the generated code for a
    // typedef?
    _reportUnimplementedConversions(node);
    return node;
  }

  void generateInitializer(ClassDeclaration node) {
    // TODO(vsm): Generate one per constructor?
    // TODO(vsm): Ensure _initializer isn't used.
    out.write("""
var _initializer = (function (_this) {
""", 2);
    var members = node.members;
    for (var member in members) {
      if (member is FieldDeclaration) {
        if (!member.isStatic) {
          for (var field in member.fields.variables) {
            var name = field.name.name;
            var initializer = field.initializer;
            if (initializer != null) {
              // TODO(vsm): Check for conversion.
              out.write("_this.$name = ");
              initializer.accept(this);
              out.write(";\n");
            }
          }
        }
      }
    }
    out.write("""
});
""", -2);
  }

  void generateDefaultConstructor(node) {
    var name = node.name.name;
    out.write("""
function $name() {
  _initializer(this);
}
""");
  }

  AstNode visitClassDeclaration(ClassDeclaration node) {
    _reportUnimplementedConversions(node);

    var name = node.name.name;
    out.write("""
// Class $name
var $name = (function () {
""", 2);
    // TODO(vsm): Process constructors, fields, and methods properly.
    // Generate default only when needed.
    generateInitializer(node);
    generateDefaultConstructor(node);
    // TODO(vsm): What should we generate if there is no unnamed constructor
    // for this class?
    out.write("""
  return $name;
})();
""", -2);
    if (isPublic(name)) out.write("$libName.$name = $name;\n");
    out.write("\n");

    return node;
  }

  AstNode visitFunctionDeclaration(FunctionDeclaration node) {
    _reportUnimplementedConversions(node);

    var name = node.name.name;
    assert(node.parent is CompilationUnit);
    out.write("// Function $name: ${node.element.type}\n");
    out.write("function $name(");
    node.functionExpression.parameters.accept(this);
    out.write(") {\n", 2);
    node.functionExpression.body.accept(this);
    out.write("}\n", -2);
    if (isPublic(name)) out.write("$libName.$name = $name;\n");
    out.write("\n");
    return node;
  }

  AstNode visitFunctionExpression(FunctionExpression node) {
    _reportUnimplementedConversions(node);

    // Bind all free variables.
    out.write('/* Unimplemented: bind any free variables. */');

    out.write("function (");
    node.parameters.accept(this);
    out.write(") {\n", 2);
    node.body.accept(this);
    out.write("}\n", -2);
    return node;
  }

  AstNode visitSimpleIdentifier(SimpleIdentifier node) {
    _reportUnimplementedConversions(node);

    out.write(node.name);
    return node;
  }

  AstNode visitExpressionFunctionBody(ExpressionFunctionBody node) {
    _reportUnimplementedConversions(node);

    out.write("return ");
    // TODO(vsm): Check for conversion.
    node.expression.accept(this);
    out.write(";\n");
    return node;
  }

  AstNode visitMethodInvocation(MethodInvocation node) {
    // TODO(vsm): Check dynamic.
    _reportUnimplementedConversions(node);

    writeQualifiedName(node.target, node.methodName);
    out.write('(');
    node.argumentList.accept(this);
    out.write(')');
    return node;
  }

  AstNode visitArgumentList(ArgumentList node) {
    _reportUnimplementedConversions(node);

    // TODO(vsm): Optional parameters.
    var arguments = node.arguments;
    var length = arguments.length;
    if (length > 0) {
      // TODO(vsm): Check for conversion.
      arguments[0].accept(this);
      for (var i = 1; i < length; ++i) {
        out.write(', ');
        // TODO(vsm): Check for conversion.
        arguments[i].accept(this);
      }
    }
    return node;
  }

  AstNode visitFormalParameterList(FormalParameterList node) {
    _reportUnimplementedConversions(node);

    // TODO(vsm): Optional parameters.
    var arguments = node.parameters;
    var length = arguments.length;
    if (length > 0) {
      arguments[0].accept(this);
      for (var i = 1; i < length; ++i) {
        out.write(', ');
        arguments[i].accept(this);
      }
    }
    return node;
  }

  AstNode visitBlockFunctionBody(BlockFunctionBody node) {
    _reportUnimplementedConversions(node);

    var statements = node.block.statements;
    for (var statement in statements) statement.accept(this);
    return node;
  }

  AstNode visitExpressionStatement(ExpressionStatement node) {
    _reportUnimplementedConversions(node);

    node.expression.accept(this);
    out.write(';\n');
    return node;
  }

  void _generateVariableList(VariableDeclarationList list, bool lazy) {
    // TODO(vsm): Detect when we can avoid wrapping in function.
    var prefix = lazy ? 'function () { return ' : '';
    var postfix = lazy ? '; }()' : '';
    var declarations = list.variables;
    for (var declaration in declarations) {
      var name = declaration.name.name;
      var initializer = declaration.initializer;
      if (initializer == null) {
        out.write('var $name;\n');
      } else {
        out.write('var $name = $prefix');
        initializer.accept(this);
        out.write('$postfix;\n');
      }
    }
  }

  AstNode visitTopLevelVariableDeclaration(TopLevelVariableDeclaration node) {
    _reportUnimplementedConversions(node);
    _generateVariableList(node.variables, true);
    return node;
  }

  AstNode visitVariableDeclarationStatement(VariableDeclarationStatement node) {
    _reportUnimplementedConversions(node);
    _generateVariableList(node.variables, false);
    return node;
  }

  AstNode visitConstructorName(ConstructorName node) {
    _reportUnimplementedConversions(node);

    node.type.name.accept(this);
    if (node.name != null) {
      out.write('.');
      node.name.accept(this);
    }
    return node;
  }

  AstNode visitInstanceCreationExpression(InstanceCreationExpression node) {
    _reportUnimplementedConversions(node);

    out.write('new ');
    node.constructorName.accept(this);
    out.write('(');
    node.argumentList.accept(this);
    out.write(')');
    return node;
  }

  AstNode visitBinaryExpression(BinaryExpression node) {
    _reportUnimplementedConversions(node);

    var op = node.operator;
    var lhs = node.leftOperand;
    var rhs = node.rightOperand;

    var dispatchType = rules.getStaticType(lhs);
    if (rules.isPrimitive(dispatchType)) {
      // TODO(vsm): When do Dart ops not map to JS?
      assert(rules.isPrimitive(rules.getStaticType(rhs)));
      lhs.accept(this);
      out.write(' $op ');
      rhs.accept(this);
    } else {
      // TODO(vsm): Figure out operator calling convention / dispatch.
      out.write('/* Unimplemented binary operator: $node */');
    }

    return node;
  }

  AstNode visitParenthesizedExpression(ParenthesizedExpression node) {
    _reportUnimplementedConversions(node);
    out.write('(');
    node.expression.accept(this);
    out.write(')');
    return node;
  }

  AstNode visitSimpleFormalParameter(SimpleFormalParameter node) {
    _reportUnimplementedConversions(node);

    node.identifier.accept(this);
    return node;
  }

  AstNode visitPrefixedIdentifier(PrefixedIdentifier node) {
    var dynamicInvoke = _processDynamicInvoke(node);
    _reportUnimplementedConversions(node);

    if (dynamicInvoke != null) {
      out.write('dart_runtime.dload(');
      node.prefix.accept(this);
      out.write(', "');
      node.identifier.accept(this);
      out.write('")');
    } else {
      node.prefix.accept(this);
      out.write('.');
      node.identifier.accept(this);
    }
    return node;
  }

  AstNode visitIntegerLiteral(IntegerLiteral node) {
    _reportUnimplementedConversions(node);

    out.write('${node.value}');
    return node;
  }

  AstNode visitStringLiteral(StringLiteral node) {
    _reportUnimplementedConversions(node);

    out.write('"${node.stringValue}"');
    return node;
  }

  AstNode visitDirective(Directive node) {
    _reportUnimplementedConversions(node);

    return node;
  }

  AstNode visitNode(AstNode node) {
    _reportUnimplementedConversions(node);
    out.write('/* Unimplemented ${node.runtimeType}: $node */');
    return node;
  }

  static const Map<String, String> _builtins = const <String, String>{
    'dart.core': 'dart_core',
  };

  void writeQualifiedName(Expression target, SimpleIdentifier id) {
    if (target != null) {
      target.accept(this);
      out.write('.');
    } else {
      var element = id.staticElement;
      if (element.enclosingElement is CompilationUnitElement) {
        var library = element.enclosingElement.enclosingElement;
        assert(library is LibraryElement);
        var package = library.name;
        var libname = _builtins.containsKey(package) ?
            _builtins[package] : package;
        out.write('$libname.');
      }
    }
    id.accept(this);
  }
}

class LibraryGenerator {
  final String name;
  final Library library;
  final Directory dir;
  final Map<AstNode, List<StaticInfo>> info;
  final TypeRules rules;

  LibraryGenerator(this.name, this.library, this.dir, this.info, this.rules);

  void generateUnit(Uri uri, CompilationUnit unit) {
    var unitGen = new UnitGenerator(uri, unit, dir, name, info, rules);
    unitGen.generate();
  }

  void generate() {
    generateUnit(library.uri, library.lib);
    library.parts.forEach((Uri uri, CompilationUnit unit) {
      generateUnit(uri, unit);
    });
  }
}

class CodeGenerator {
  final String outDir;
  final Uri root;
  final Map<Uri, Library> libraries;
  final Map<AstNode, List<StaticInfo>> info;
  final TypeRules rules;

  CodeGenerator(this.outDir, this.root, this.libraries, this.info, this.rules);

  String _libName(Library lib) {
    for (var directive in lib.lib.directives) {
      if (directive is LibraryDirective) return directive.name.toString();
    }
    // Fall back on the file name.
    var tail = lib.uri.pathSegments.last;
    if (tail.endsWith('.dart')) tail = tail.substring(0, tail.length - 5);
    return tail;
  }

  void generate() {
    var base = Uri.base;
    var out = base.resolve(outDir + '/');
    var top = new Directory.fromUri(out);
    top.createSync();

    libraries.forEach((Uri uri, Library lib) {
      var name = _libName(lib);
      var dir = new Directory.fromUri(out.resolve(name));
      dir.createSync();

      var libgen = new LibraryGenerator(name, lib, dir, info, rules);
      libgen.generate();
    });
  }
}

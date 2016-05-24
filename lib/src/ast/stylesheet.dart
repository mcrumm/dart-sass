// Copyright 2016 Google Inc. Use of this source code is governed by an
// MIT-style license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import 'package:source_span/source_span.dart';

import '../visitor/statement.dart';
import 'statement.dart';

class StylesheetNode implements Statement {
  final List<Statement> children;

  final SourceSpan span;

  StylesheetNode(Iterable<Statement> children, {this.span})
      : children = new List.unmodifiable(children);

  /*=T*/ visit/*<T>*/(StatementVisitor/*<T>*/ visitor) =>
      visitor.visitStylesheet(this);

  String toString() => children.map((child) => "$child").join(" ");
}
// Copyright (c) 2017, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:mirrors' hide SourceLocation;

import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/constant/value.dart';
import 'package:analyzer/dart/element/element2.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:build/build.dart';
import 'package:source_span/source_span.dart';

import 'utils.dart';

/// An abstraction around doing static type checking at compile/build time.
abstract class TypeChecker {
  const TypeChecker._();

  /// Creates a new [TypeChecker] that delegates to other [checkers].
  ///
  /// This implementation will return `true` for type checks if _any_ of the
  /// provided type checkers return true, which is useful for deprecating an
  /// API:
  /// ```dart
  /// const $Foo = const TypeChecker.fromRuntime(Foo);
  /// const $Bar = const TypeChecker.fromRuntime(Bar);
  ///
  /// // Used until $Foo is deleted.
  /// const $FooOrBar = const TypeChecker.forAny(const [$Foo, $Bar]);
  /// ```
  const factory TypeChecker.any(Iterable<TypeChecker> checkers) = _AnyChecker;

  /// Create a new [TypeChecker] backed by a runtime [type].
  ///
  /// This implementation uses `dart:mirrors` (runtime reflection).
  const factory TypeChecker.fromRuntime(Type type) = _MirrorTypeChecker;

  /// Create a new [TypeChecker] backed by a static [type].
  const factory TypeChecker.fromStatic(DartType type) = _LibraryTypeChecker;

  /// Create a new [TypeChecker] backed by a library [url].
  ///
  /// Example of referring to a `LinkedHashMap` from `dart:collection`:
  /// ```dart
  /// const linkedHashMap = const TypeChecker.fromUrl(
  ///   'dart:collection#LinkedHashMap',
  /// );
  /// ```
  ///
  /// **NOTE**: This is considered a more _brittle_ way of determining the type
  /// because it relies on knowing the _absolute_ path (i.e. after resolved
  /// `export` directives). You should ideally only use `fromUrl` when you know
  /// the full path (likely you own/control the package) or it is in a stable
  /// package like in the `dart:` SDK.
  const factory TypeChecker.fromUrl(dynamic url) = _UriTypeChecker;

  /// Returns the first constant annotating [element] assignable to this type.
  ///
  /// Otherwise returns `null`.
  ///
  /// Throws on unresolved annotations unless [throwOnUnresolved] is `false`.
  DartObject? firstAnnotationOf(
    Object element, {
    bool throwOnUnresolved = true,
  }) {
    if (element case final Annotatable annotatable) {
      final annotations = annotatable.metadata2.annotations;
      if (annotations.isEmpty) {
        return null;
      }
    }
    final results = annotationsOf(
      element,
      throwOnUnresolved: throwOnUnresolved,
    );
    return results.isEmpty ? null : results.first;
  }

  /// Returns if a constant annotating [element] is assignable to this type.
  ///
  /// Throws on unresolved annotations unless [throwOnUnresolved] is `false`.
  bool hasAnnotationOf(Element2 element, {bool throwOnUnresolved = true}) =>
      firstAnnotationOf(element, throwOnUnresolved: throwOnUnresolved) != null;

  /// Returns the first constant annotating [element] that is exactly this type.
  ///
  /// Throws [UnresolvedAnnotationException] on unresolved annotations unless
  /// [throwOnUnresolved] is explicitly set to `false` (default is `true`).
  DartObject? firstAnnotationOfExact(
    Element2 element, {
    bool throwOnUnresolved = true,
  }) {
    if (element case final Annotatable annotatable) {
      final annotations = annotatable.metadata2.annotations;
      if (annotations.isEmpty) {
        return null;
      }
      final results = annotationsOfExact(
        element,
        throwOnUnresolved: throwOnUnresolved,
      );
      return results.isEmpty ? null : results.first;
    }
    return null;
  }

  /// Returns if a constant annotating [element] is exactly this type.
  ///
  /// Throws [UnresolvedAnnotationException] on unresolved annotations unless
  /// [throwOnUnresolved] is explicitly set to `false` (default is `true`).
  bool hasAnnotationOfExact(
    Element2 element, {
    bool throwOnUnresolved = true,
  }) =>
      firstAnnotationOfExact(element, throwOnUnresolved: throwOnUnresolved) !=
      null;

  DartObject? _computeConstantValue(
    Object element,
    ElementAnnotation annotation,
    int annotationIndex, {
    bool throwOnUnresolved = true,
  }) {
    final result = annotation.computeConstantValue();
    if (result == null && throwOnUnresolved && element is Element2) {
      throw UnresolvedAnnotationException._from(element, annotationIndex);
    }
    return result;
  }

  /// Returns annotating constants on [element] assignable to this type.
  ///
  /// Throws [UnresolvedAnnotationException] on unresolved annotations unless
  /// [throwOnUnresolved] is explicitly set to `false` (default is `true`).
  Iterable<DartObject> annotationsOf(
    Object element, {
    bool throwOnUnresolved = true,
  }) => _annotationsWhere(
    element,
    isAssignableFromType,
    throwOnUnresolved: throwOnUnresolved,
  );

  Iterable<DartObject> _annotationsWhere(
    Object element,
    bool Function(DartType) predicate, {
    bool throwOnUnresolved = true,
  }) sync* {
    if (element case final Annotatable annotatable) {
      final annotations = annotatable.metadata2.annotations;
      for (var i = 0; i < annotations.length; i++) {
        final value = _computeConstantValue(
          element,
          annotations[i],
          i,
          throwOnUnresolved: throwOnUnresolved,
        );
        if (value?.type != null && predicate(value!.type!)) {
          yield value;
        }
      }
    }
  }

  /// Returns annotating constants on [element] of exactly this type.
  ///
  /// Throws [UnresolvedAnnotationException] on unresolved annotations unless
  /// [throwOnUnresolved] is explicitly set to `false` (default is `true`).
  Iterable<DartObject> annotationsOfExact(
    Element2 element, {
    bool throwOnUnresolved = true,
  }) => _annotationsWhere(
    element,
    isExactlyType,
    throwOnUnresolved: throwOnUnresolved,
  );

  /// Returns `true` if the type of [element] can be assigned to this type.
  bool isAssignableFrom(Element2 element) =>
      isExactly(element) ||
      (element is InterfaceElement2 &&
          element.allSupertypes.any(isExactlyType));

  /// Returns `true` if [staticType] can be assigned to this type.
  bool isAssignableFromType(DartType staticType) {
    final element = staticType.element3;
    return element != null && isAssignableFrom(element);
  }

  /// Returns `true` if representing the exact same class as [element].
  bool isExactly(Element2 element);

  /// Returns `true` if representing the exact same type as [staticType].
  ///
  /// This will always return false for types without a backingclass such as
  /// `void` or function types.
  bool isExactlyType(DartType staticType) {
    final element = staticType.element3;
    if (element != null) {
      return isExactly(element);
    } else {
      return false;
    }
  }

  /// Returns `true` if representing a super class of [element].
  ///
  /// This check only takes into account the *extends* hierarchy. If you wish
  /// to check mixins and interfaces, use [isAssignableFrom].
  bool isSuperOf(Element2 element) {
    if (element is InterfaceElement2) {
      var theSuper = element.supertype;

      do {
        if (isExactlyType(theSuper!)) {
          return true;
        }

        theSuper = theSuper.superclass;
      } while (theSuper != null);
    }

    return false;
  }

  /// Returns `true` if representing a super type of [staticType].
  ///
  /// This only takes into account the *extends* hierarchy. If you wish
  /// to check mixins and interfaces, use [isAssignableFromType].
  bool isSuperTypeOf(DartType staticType) => isSuperOf(staticType.element3!);
}

// Checks a static type against another static type;
class _LibraryTypeChecker extends TypeChecker {
  final DartType _type;

  const _LibraryTypeChecker(this._type) : super._();

  @override
  bool isExactly(Element2 element) =>
      element is InterfaceElement2 && element == _type.element3;

  @override
  String toString() => urlOfElement(_type.element3!);
}

// Checks a runtime type against a static type.
class _MirrorTypeChecker extends TypeChecker {
  static Uri _uriOf(ClassMirror mirror) => normalizeUrl(
    (mirror.owner as LibraryMirror).uri,
  ).replace(fragment: MirrorSystem.getName(mirror.simpleName));

  // Precomputed type checker for types that already have been used.
  static final _cache = Expando<TypeChecker>();

  final Type _type;

  const _MirrorTypeChecker(this._type) : super._();

  TypeChecker get _computed =>
      _cache[this] ??= TypeChecker.fromUrl(_uriOf(reflectClass(_type)));

  @override
  bool isExactly(Element2 element) => _computed.isExactly(element);

  @override
  String toString() => _computed.toString();
}

// Checks a runtime type against an Uri and Symbol.
class _UriTypeChecker extends TypeChecker {
  final String _url;

  // Precomputed cache of String --> Uri.
  static final _cache = Expando<Uri>();

  const _UriTypeChecker(dynamic url) : _url = '$url', super._();

  @override
  bool operator ==(Object o) => o is _UriTypeChecker && o._url == _url;

  @override
  int get hashCode => _url.hashCode;

  /// Url as a [Uri] object, lazily constructed.
  Uri get uri => _cache[this] ??= normalizeUrl(Uri.parse(_url));

  /// Returns whether this type represents the same as [url].
  bool hasSameUrl(dynamic url) =>
      uri.toString() ==
      (url is String ? url : normalizeUrl(url as Uri).toString());

  @override
  bool isExactly(Element2 element) => hasSameUrl(urlOfElement(element));

  @override
  String toString() => '$uri';
}

class _AnyChecker extends TypeChecker {
  final Iterable<TypeChecker> _checkers;

  const _AnyChecker(this._checkers) : super._();

  @override
  bool isExactly(Element2 element) =>
      _checkers.any((c) => c.isExactly(element));
}

/// Exception thrown when [TypeChecker] fails to resolve a metadata annotation.
///
/// Methods such as [TypeChecker.firstAnnotationOf] may throw this exception
/// when one or more annotations are not resolvable. This is usually a sign that
/// something was misspelled, an import is missing, or a dependency was not
/// defined (for build systems such as Bazel).
class UnresolvedAnnotationException implements Exception {
  /// Element that was annotated with something we could not resolve.
  final Element2 annotatedElement;

  /// Source span of the annotation that was not resolved.
  ///
  /// May be `null` if the import library was not found.
  final SourceSpan? annotationSource;

  static SourceSpan? _findSpan(Element2 annotatedElement, int annotationIndex) {
    try {
      final parsedLibrary =
          annotatedElement.session!.getParsedLibraryByElement2(
                annotatedElement.library2!,
              )
              as ParsedLibraryResult;
      final declaration = parsedLibrary.getFragmentDeclaration(
        annotatedElement.firstFragment,
      );
      if (declaration == null) {
        return null;
      }
      final node = declaration.node;
      final List<Annotation> metadata;
      if (node is AnnotatedNode) {
        metadata = node.metadata;
      } else if (node is FormalParameter) {
        metadata = node.metadata;
      } else {
        throw StateError(
          'Unhandled Annotated AST node type: ${node.runtimeType}',
        );
      }
      final annotation = metadata[annotationIndex];
      final start = annotation.offset;
      final end = start + annotation.length;
      final parsedUnit = declaration.parsedUnit!;
      return SourceSpan(
        SourceLocation(start, sourceUrl: parsedUnit.uri),
        SourceLocation(end, sourceUrl: parsedUnit.uri),
        parsedUnit.content.substring(start, end),
      );
    } catch (e, stack) {
      // Trying to get more information on https://github.com/dart-lang/sdk/issues/45127
      log.warning(
        '''
An unexpected error was thrown trying to get location information on `$annotatedElement` (${annotatedElement.runtimeType}).

Please file an issue at https://github.com/dart-lang/source_gen/issues/new
Include the contents of this warning and the stack trace along with
the version of `package:source_gen`, `package:analyzer` from `pubspec.lock`.
''',
        e,
        stack,
      );
      return null;
    }
  }

  /// Creates an exception from an annotation ([annotationIndex]) that was not
  /// resolvable while traversing `metadata2` on [annotatedElement].
  factory UnresolvedAnnotationException._from(
    Element2 annotatedElement,
    int annotationIndex,
  ) {
    final sourceSpan = _findSpan(annotatedElement, annotationIndex);
    return UnresolvedAnnotationException._(annotatedElement, sourceSpan);
  }

  const UnresolvedAnnotationException._(
    this.annotatedElement,
    this.annotationSource,
  );

  @override
  String toString() {
    final message = 'Could not resolve annotation for `$annotatedElement`.';
    if (annotationSource != null) {
      return annotationSource!.message(message);
    }
    return message;
  }
}

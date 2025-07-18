// Copyright (c) 2017, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analyzer/dart/element/element2.dart';
import 'package:build/build.dart';
import 'package:path/path.dart' as p;

import 'constants/reader.dart';
import 'type_checker.dart';
import 'utils.dart';

/// Result of finding an [annotation] on [directive] through [LibraryReader].
class AnnotatedDirective {
  final ConstantReader annotation;
  final ElementDirective directive;

  const AnnotatedDirective(this.annotation, this.directive);

  Metadata? get metadata2 => directive.metadata2;
}

/// Result of finding an [annotation] on [element] through [LibraryReader].
class AnnotatedElement {
  final ConstantReader annotation;
  final Element2 element;

  const AnnotatedElement(this.annotation, this.element);
}

/// A high-level wrapper API with common functionality for [LibraryElement2].
class LibraryReader {
  final LibraryElement2 element;

  LibraryReader(this.element);

  /// Returns a top-level [ClassElement2] publicly visible in by [name].
  ///
  /// Unlike [LibraryElement2.getClass2], this also correctly traverses
  /// identifiers that are accessible via one or more `export` directives.
  ClassElement2? findType(String name) {
    final type = element.exportNamespace.get2(name);
    return type is ClassElement2 ? type : null;
  }

  /// All of the declarations in this library.
  Iterable<Element2> get allElements => [element, ...element.children2];

  /// All of the declarations in this library annotated with [checker].
  Iterable<AnnotatedElement> annotatedWith(
    TypeChecker checker, {
    bool throwOnUnresolved = true,
  }) sync* {
    for (final element in allElements) {
      final annotation = checker.firstAnnotationOf(
        element,
        throwOnUnresolved: throwOnUnresolved,
      );
      if (annotation != null) {
        yield AnnotatedElement(ConstantReader(annotation), element);
      }
    }
  }

  /// All of the directives in this library annotated with [checker].
  Iterable<AnnotatedDirective> libraryDirectivesAnnotatedWith(
    TypeChecker checker, {
    bool throwOnUnresolved = true,
  }) sync* {
    final firstFragment = element.firstFragment;
    final directives = [
      ...firstFragment.libraryImports2,
      ...firstFragment.libraryExports2,
      ...firstFragment.partIncludes,
    ];

    for (final directive in directives) {
      final annotation = checker.firstAnnotationOf(
        directive,
        throwOnUnresolved: throwOnUnresolved,
      );

      if (annotation != null) {
        yield AnnotatedDirective(ConstantReader(annotation), directive);
      }
    }
  }

  /// All of the declarations in this library annotated with exactly [checker].
  Iterable<AnnotatedElement> annotatedWithExact(
    TypeChecker checker, {
    bool throwOnUnresolved = true,
  }) sync* {
    for (final element in allElements) {
      final annotation = checker.firstAnnotationOfExact(
        element,
        throwOnUnresolved: throwOnUnresolved,
      );
      if (annotation != null) {
        yield AnnotatedElement(ConstantReader(annotation), element);
      }
    }
  }

  /// Returns a [Uri] from the current library to the target [asset].
  ///
  /// This is a typed convenience function for using [pathToUrl], and the same
  /// API restrictions hold around supported schemes and relative paths.
  Uri pathToAsset(AssetId asset) => pathToUrl(asset.uri);

  /// Returns a [Uri] from the current library to the target [element].
  ///
  /// This is a typed convenience function for using [pathToUrl], and the same
  /// API restrictions hold around supported schemes and relative paths.
  Uri pathToElement(Element2 element) => pathToUrl(element.library2!.uri);

  /// Returns a [Uri] from the current library to the one provided.
  ///
  /// If possible, a `package:` or `dart:` URL scheme will be used to reference
  /// the library, falling back to relative paths if required (such as in the
  /// `test` directory).
  ///
  /// The support [Uri.scheme]s are (others throw [ArgumentError]):
  /// * `dart`
  /// * `package`
  /// * `asset`
  ///
  /// May throw [ArgumentError] if it is not possible to resolve a path.
  Uri pathToUrl(dynamic toUrlOrString) {
    // TODO: https://github.com/dart-lang/source_gen/issues/672 - Take Object
    ArgumentError.checkNotNull(toUrlOrString, 'toUrlOrString');
    final to =
        toUrlOrString is Uri
            ? toUrlOrString
            : Uri.parse(toUrlOrString as String);
    if (to.scheme == 'dart') {
      // Convert dart:core/map.dart to dart:core.
      return normalizeDartUrl(to);
    }
    if (to.scheme == 'package') {
      // Identity (no-op).
      return to;
    }
    if (to.scheme == 'asset') {
      // This is the same thing as a package: URL.
      //
      // i.e.
      //   asset:foo/lib/foo.dart ===
      //   package:foo/foo.dart
      if (to.pathSegments.length > 1 && to.pathSegments[1] == 'lib') {
        return assetToPackageUrl(to);
      }
      var from = element.uri;
      // Normalize (convert to an asset: URL).
      from = normalizeUrl(from);
      if (_isRelative(from, to)) {
        if (from == to) {
          // Edge-case: p.relative('a.dart', 'a.dart') == '.', but that is not
          // a valid import URL in Dart source code.
          return Uri(path: to.pathSegments.last);
        }
        final relative = p.toUri(
          p.relative(to.toString(), from: from.toString()),
        );
        // We now have a URL like "../b.dart", but we just want "b.dart".
        return relative.replace(pathSegments: relative.pathSegments.skip(1));
      }
      throw ArgumentError.value(to, 'to', 'Not relative to $from');
    }
    throw ArgumentError.value(to, 'to', 'Cannot use scheme "${to.scheme}"');
  }

  /// Returns whether both [from] and [to] are in the same package and folder.
  ///
  /// For example these are considered relative:
  /// * `asset:foo/test/foo.dart` and `asset:foo/test/bar.dart`.
  ///
  /// But these are not:
  /// * `asset:foo/test/foo.dart` and `asset:foo/bin/bar.dart`.
  /// * `asset:foo/test/foo.dart` and `asset:bar/test/foo.dart`.
  static bool _isRelative(Uri from, Uri to) {
    final fromSegments = from.pathSegments;
    final toSegments = to.pathSegments;
    return fromSegments.length >= 2 &&
        toSegments.length >= 2 &&
        fromSegments[0] == toSegments[0] &&
        fromSegments[1] == toSegments[1];
  }

  /// All of the elements representing classes in this library.
  Iterable<ClassElement2> get classes => element.classes;

  /// All of the elements representing enums in this library.
  Iterable<EnumElement2> get enums => element.enums;
}

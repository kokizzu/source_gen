// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:convert';

import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/element2.dart';
import 'package:build/build.dart';
import 'package:dart_style/dart_style.dart';
import 'package:pub_semver/pub_semver.dart';

import 'generated_output.dart';
import 'generator.dart';
import 'generator_for_annotation.dart';
import 'library.dart';
import 'utils.dart';

/// A [Builder] wrapping on one or more [Generator]s.
class _Builder extends Builder {
  /// Function that determines how the generated code is formatted.
  ///
  /// The `languageVersion` is the version to parse the file with, but it may be
  /// overridden using a language version comment in the file.
  final String Function(String code, Version languageVersion) formatOutput;

  /// The generators run for each targeted library.
  final List<Generator> _generators;

  /// The [buildExtensions] configuration for `.dart`
  final String _generatedExtension;

  /// Whether to emit a standalone (non-`part`) file in this builder.
  bool get _isLibraryBuilder => this is LibraryBuilder;

  final String _header;

  /// Whether to include or emit the gen part descriptions. Defaults to true.
  final bool _writeDescriptions;

  /// Whether to allow syntax errors in input libraries.
  final bool allowSyntaxErrors;

  @override
  final Map<String, List<String>> buildExtensions;

  /// Wrap [_generators] to form a [Builder]-compatible API.
  ///
  /// If available, the `build_extensions` option will be extracted from
  /// [options] to allow output files to be generated into a different directory
  _Builder(
    this._generators, {
    required this.formatOutput,
    String generatedExtension = '.g.dart',
    List<String> additionalOutputExtensions = const [],
    String? header,
    bool? writeDescriptions,
    this.allowSyntaxErrors = false,
    BuilderOptions? options,
  }) : _generatedExtension = generatedExtension,
       buildExtensions = validatedBuildExtensionsFrom(
         options != null ? Map.of(options.config) : null,
         {
           '.dart': [generatedExtension, ...additionalOutputExtensions],
         },
       ),
       _writeDescriptions = writeDescriptions ?? true,
       _header = (header ?? defaultFileHeader).trim() {
    if (_generatedExtension.isEmpty || !_generatedExtension.startsWith('.')) {
      throw ArgumentError.value(
        _generatedExtension,
        'generatedExtension',
        'Extension must be in the format of .*',
      );
    }
    if (_isLibraryBuilder && _generators.length > 1) {
      throw ArgumentError(
        'A standalone file can only be generated from a single Generator.',
      );
    }
    if (options != null && additionalOutputExtensions.isNotEmpty) {
      throw ArgumentError(
        'Either `options` or `additionalOutputExtensions` parameter '
        'can be given. Not both.',
      );
    }
  }

  @override
  Future<void> build(BuildStep buildStep) async {
    final resolver = buildStep.resolver;

    if (!await resolver.isLibrary(buildStep.inputId)) return;

    if (_generators.every((g) => g is GeneratorForAnnotation) &&
        !(await _hasInterestingTopLevelAnnotations(
          buildStep.inputId,
          resolver,
          buildStep,
        ))) {
      return;
    }

    final lib = await buildStep.resolver.libraryFor(
      buildStep.inputId,
      allowSyntaxErrors: allowSyntaxErrors,
    );
    await _generateForLibrary(lib, buildStep);
  }

  Future<void> _generateForLibrary(
    LibraryElement2 library,
    BuildStep buildStep,
  ) async {
    final generatedOutputs =
        await _generate(library, _generators, buildStep).toList();

    // Don't output useless files.
    //
    // NOTE: It is important to do this check _before_ checking for valid
    // library/part definitions because users expect some files to be skipped
    // therefore they do not have "library".
    if (generatedOutputs.isEmpty) return;
    final outputId = buildStep.allowedOutputs.first;
    final contentBuffer = StringBuffer();

    if (_header.isNotEmpty) {
      contentBuffer.writeln(_header);
    }

    if (!_isLibraryBuilder) {
      final asset = buildStep.inputId;
      final partOfUri = uriOfPartial(library, asset, outputId);
      contentBuffer.writeln();

      if (this is PartBuilder) {
        contentBuffer
          ..write(languageOverrideForLibrary(library))
          ..writeln('part of \'$partOfUri\';');
        final part = computePartUrl(buildStep.inputId, outputId);

        final libraryUnit = await buildStep.resolver.compilationUnitFor(
          buildStep.inputId,
        );
        final hasLibraryPartDirectiveWithOutputUri = hasExpectedPartDirective(
          libraryUnit,
          part,
        );
        if (!hasLibraryPartDirectiveWithOutputUri) {
          // TODO: Upgrade to error in a future breaking change?
          log.warning(
            '$part must be included as a part directive in '
            'the input library with:\n    part \'$part\';',
          );
          return;
        }
      } else {
        assert(this is SharedPartBuilder);
        // For shared-part builders, `part` statements will be checked by the
        // combining build step.
      }
    }

    for (var item in generatedOutputs) {
      if (_writeDescriptions) {
        contentBuffer
          ..writeln()
          ..writeln(_headerLine)
          ..writeAll(
            LineSplitter.split(
              item.generatorDescription,
            ).map((line) => '// $line\n'),
          )
          ..writeln(_headerLine)
          ..writeln();
      }

      contentBuffer.writeln(item.output);
    }

    var genPartContent = contentBuffer.toString();

    try {
      genPartContent = formatOutput(
        genPartContent,
        library.languageVersion.effective,
      );
    } catch (e, stack) {
      log.severe(
        '''
An error `${e.runtimeType}` occurred while formatting the generated source for
  `${library.uri}`
which was output to
  `${outputId.path}`.
This may indicate an issue in the generator, the input source code, or in the
source formatter.''',
        e,
        stack,
      );
    }

    await buildStep.writeAsString(outputId, genPartContent);
  }

  @override
  String toString() =>
      'Generating $_generatedExtension: ${_generators.join(', ')}';
}

/// A [Builder] which generates content intended for `part of` files.
///
/// Generated files will be prefixed with a `partId` to ensure multiple
/// [SharedPartBuilder]s can produce non conflicting `part of` files. When the
/// `source_gen|combining_builder` is applied to the primary input these
/// snippets will be concatenated into the final `.g.dart` output.
///
/// This builder can be used when multiple generators may need to output to the
/// same part file but [PartBuilder] can't be used because the generators are
/// not all defined in the same location. As a convention most codegen which
/// generates code should use this approach to get content into a `.g.dart` file
/// instead of having individual outputs for each building package.
class SharedPartBuilder extends _Builder {
  /// Wrap [generators] as a [Builder] that generates `part of` files.
  ///
  /// [partId] indicates what files will be created for each `.dart`
  /// input. This extension should be unique as to not conflict with other
  /// [SharedPartBuilder]s. The resulting file will be of the form
  /// `<generatedExtension>.g.part`. If any generator in [generators] will
  /// create additional outputs through the [BuildStep] they should be indicated
  /// in [additionalOutputExtensions].
  ///
  /// [formatOutput] is called to format the generated code. Defaults to
  /// [DartFormatter.format].
  ///
  /// [allowSyntaxErrors] indicates whether to allow syntax errors in input
  /// libraries.
  ///
  /// [writeDescriptions] adds comments to the output used to separate the
  /// sections of the file generated from different generators, and reveals
  /// which generator produced the following output.
  /// If `null`, [writeDescriptions] is set to true which is the default value.
  /// If [writeDescriptions] is false, no generator descriptions are added.
  SharedPartBuilder(
    super.generators,
    String partId, {
    super.formatOutput = _defaultFormatOutput,
    super.additionalOutputExtensions,
    super.allowSyntaxErrors,
    super.writeDescriptions,
  }) : super(generatedExtension: '.$partId.g.part', header: '') {
    if (!_partIdRegExp.hasMatch(partId)) {
      throw ArgumentError.value(
        partId,
        'partId',
        '`partId` can only contain letters, numbers, `_` and `.`. '
            'It cannot start or end with `.`.',
      );
    }
  }
}

/// A [Builder] which generates `part of` files.
///
/// This builder should be avoided - prefer using [SharedPartBuilder] and
/// generating content that can be merged with output from other builders into a
/// common `.g.dart` part file.
///
/// Each output should correspond to a `part` directive in the primary input,
/// this will be validated.
///
/// Content output by each generator is concatenated and written to the output.
/// A `part of` directive will automatically be included in the output and
/// should not need be written by any of the generators.
class PartBuilder extends _Builder {
  /// Wrap [generators] as a [Builder] that generates `part of` files.
  ///
  /// [generatedExtension] indicates what files will be created for each
  /// `.dart` input. The [generatedExtension] should *not* be `.g.dart`. If you
  /// wish to produce `.g.dart` files please use [SharedPartBuilder].
  ///
  /// If any generator in [generators] will create additional outputs through
  /// the [BuildStep] they should be indicated in [additionalOutputExtensions].
  ///
  /// [formatOutput] is called to format the generated code. Defaults to
  /// [DartFormatter.format].
  ///
  /// [writeDescriptions] adds comments to the output used to separate the
  /// sections of the file generated from different generators, and reveals
  /// which generator produced the following output.
  /// If `null`, [writeDescriptions] is set to true which is the default value.
  /// If [writeDescriptions] is false, no generator descriptions are added.
  ///
  /// [header] is used to specify the content at the top of each generated file.
  /// If `null`, the content of [defaultFileHeader] is used.
  /// If [header] is an empty `String` no header is added.
  ///
  /// [allowSyntaxErrors] indicates whether to allow syntax errors in input
  /// libraries.
  ///
  /// If available, the `build_extensions` option will be extracted from
  /// [options] to allow output files to be generated into a different directory
  PartBuilder(
    super.generators,
    String generatedExtension, {
    super.formatOutput = _defaultFormatUnit,
    super.additionalOutputExtensions,
    super.writeDescriptions,
    super.header,
    super.allowSyntaxErrors,
    super.options,
  }) : super(generatedExtension: generatedExtension);
}

/// A [Builder] which generates standalone Dart library files.
///
/// A single [Generator] is responsible for generating the entirety of the
/// output since it must also output any relevant import directives at the
/// beginning of it's output.
class LibraryBuilder extends _Builder {
  /// Wrap [generator] as a [Builder] that generates Dart library files.
  ///
  /// [generatedExtension] indicates what files will be created for each `.dart`
  /// input.
  /// Defaults to `.g.dart`, however this should usually be changed to
  /// avoid conflicts with outputs from a [SharedPartBuilder].
  /// If [generator] will create additional outputs through the [BuildStep] they
  /// should be indicated in [additionalOutputExtensions].
  ///
  /// [formatOutput] is called to format the generated code. Defaults to
  /// using the standard [DartFormatter] and writing a comment specifying the
  /// default format width of 80..
  ///
  /// [writeDescriptions] adds comments to the output used to separate the
  /// sections of the file generated from different generators, and reveals
  /// which generator produced the following output.
  /// If `null`, [writeDescriptions] is set to true which is the default value.
  /// If [writeDescriptions] is false, no generator descriptions are added.
  ///
  /// [header] is used to specify the content at the top of each generated file.
  /// If `null`, the content of [defaultFileHeader] is used.
  /// If [header] is an empty `String` no header is added.
  ///
  /// [allowSyntaxErrors] indicates whether to allow syntax errors in input
  /// libraries.
  LibraryBuilder(
    Generator generator, {
    super.formatOutput = _defaultFormatUnit,
    super.generatedExtension,
    super.additionalOutputExtensions,
    super.writeDescriptions,
    super.header,
    super.allowSyntaxErrors,
    super.options,
  }) : super([generator]);
}

Stream<GeneratedOutput> _generate(
  LibraryElement2 library,
  List<Generator> generators,
  BuildStep buildStep,
) async* {
  final libraryReader = LibraryReader(library);
  for (var i = 0; i < generators.length; i++) {
    final gen = generators[i];
    var msg = 'Running $gen';
    if (generators.length > 1) {
      msg = '$msg - ${i + 1} of ${generators.length}';
    }
    log.fine(msg);
    var createdUnit = await gen.generate(libraryReader, buildStep);

    if (createdUnit == null) {
      continue;
    }

    createdUnit = createdUnit.trim();
    if (createdUnit.isEmpty) {
      continue;
    }

    yield GeneratedOutput(gen, createdUnit);
  }
}

Future<bool> _hasInterestingTopLevelAnnotations(
  AssetId input,
  Resolver resolver,
  BuildStep buildStep,
) async {
  if (!await buildStep.canRead(input)) return false;
  final parsed = await resolver.compilationUnitFor(input);
  final partIds = <AssetId>[];
  for (var directive in parsed.directives) {
    if (directive.metadata.isNotEmpty) return true;
    if (directive is PartDirective) {
      partIds.add(
        AssetId.resolve(Uri.parse(directive.uri.stringValue!), from: input),
      );
    }
  }
  for (var declaration in parsed.declarations) {
    if (declaration.metadata.any(_isUnknownAnnotation)) {
      return true;
    }
  }
  for (var partId in partIds) {
    if (await _hasInterestingTopLevelAnnotations(partId, resolver, buildStep)) {
      return true;
    }
  }
  return false;
}

bool _isUnknownAnnotation(Annotation annotation) {
  const knownAnnotationNames = {
    // Annotations from dart:core, there is an assumption that people are not
    // overriding these.
    'deprecated',
    'Deprecated',
    'override',
    'pragma',
  };
  return !knownAnnotationNames.contains(annotation.name.name);
}

const defaultFileHeader = '// GENERATED CODE - DO NOT MODIFY BY HAND';

String _defaultFormatOutput(String code, Version version) =>
    DartFormatter(languageVersion: version).format(code);

/// Prefixes a dart format width and formats [code].
String _defaultFormatUnit(String code, Version version) {
  code = '$dartFormatWidth\n$code';
  return _defaultFormatOutput(code, version);
}

final _headerLine = '// '.padRight(77, '*');

const partIdRegExpLiteral = r'[A-Za-z_\d-]+';

final _partIdRegExp = RegExp('^$partIdRegExpLiteral\$');

String languageOverrideForLibrary(LibraryElement2 library) {
  final override = library.languageVersion.override;
  return override == null
      ? ''
      : '// @dart=${override.major}.${override.minor}\n';
}

/// A comment configuring `dart_style` to use the default code width so no
/// configuration discovery is required.
const dartFormatWidth = '// dart format width=80';

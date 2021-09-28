// Copyright (c) 2021, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// @dart=2.10

/// This implements support for dependency-bot style automated upgrades.
/// It is still work in progress - do not rely on the current output.
import 'dart:convert';
import 'dart:io';

import 'package:async/async.dart' show collectBytes;
import 'package:pub_semver/pub_semver.dart';
import 'package:yaml/yaml.dart';
import 'package:yaml_edit/yaml_edit.dart';

import '../command.dart';
import '../entrypoint.dart';
import '../io.dart';
import '../log.dart' as log;
import '../package.dart';
import '../package_name.dart';
import '../pubspec.dart';
import '../pubspec_utils.dart';
import '../solver.dart';
import '../system_cache.dart';

class DependencyServicesCommand extends PubCommand {
  @override
  String get name => '__experimental-dependency-services';
  @override
  bool get hidden => true;

  @override
  String get description => 'Provide support for dependabot-like services.';

  DependencyServicesCommand() {
    addSubcommand(DependencyServicesReportCommand());
    addSubcommand(DependencyServicesListCommand());
    addSubcommand(DependencyServicesApplyCommand());
  }
}

class DependencyServicesReportCommand extends PubCommand {
  @override
  String get name => 'report';
  @override
  String get description =>
      'Output a machine-digestible report of the upgrade options for each dependency.';
  @override
  String get argumentsDescription => '[options]';

  @override
  bool get takesArguments => false;

  DependencyServicesReportCommand() {
    argParser.addOption('directory',
        abbr: 'C', help: 'Run this in the directory<dir>.', valueHelp: 'dir');
  }

  @override
  Future<void> runProtected() async {
    final compatiblePubspec = stripDependencyOverrides(entrypoint.root.pubspec);

    final breakingPubspec = stripVersionUpperBounds(compatiblePubspec);

    final compatiblePackagesResult =
        await _tryResolve(compatiblePubspec, cache);

    final breakingPackagesResult = await _tryResolve(breakingPubspec, cache);

    // This list will be empty if there is no lock file.
    final currentPackages = fileExists(entrypoint.lockFilePath)
        ? Map<String, PackageId>.from(entrypoint.lockFile.packages)
        : Map<String, PackageId>.fromIterable(
            await _tryResolve(entrypoint.root.pubspec, cache),
            key: (e) => e.name);
    currentPackages.remove(entrypoint.root.name);

    final dependencies = <Object>[];
    final result = <String, Object>{'dependencies': dependencies};

    Future<List<Object>> _computeUpgradeSet(
        Pubspec rootPubspec, PackageId package,
        {UpgradeType upgradeType}) async {
      final lockFile = entrypoint.lockFile;
      final pubspec = upgradeType == UpgradeType.multiBreaking
          ? stripVersionUpperBounds(rootPubspec)
          : Pubspec(rootPubspec.name,
              dependencies: rootPubspec.dependencies.values,
              devDependencies: rootPubspec.devDependencies.values,
              sdkConstraints: rootPubspec.sdkConstraints);

      if (upgradeType == UpgradeType.singleBreaking) {
        pubspec.dependencies[package.name] = package
            .toRange()
            .withConstraint(stripUpperBound(package.toRange().constraint));
      } else {
        pubspec.dependencies[package.name] = package.toRange();
      }

      final resolution = await tryResolveVersions(
        SolveType.GET,
        cache,
        Package.inMemory(pubspec),
        lockFile: lockFile,
      );

      return [
        ...resolution.packages.where((r) {
          if (r.name == rootPubspec.name) return false;
          final originalVersion = currentPackages[r.name];
          return originalVersion == null ||
              r.version != originalVersion.version;
        }).map((p) => {
              'name': p.name,
              'version': p.version.toString(),
              'kind': _kindString(pubspec, p.name),
              'constraint': null // TODO: compute new constraint
            }),
        for (final oldPackageName in lockFile.packages.keys)
          if (!resolution.packages
              .any((newPackage) => newPackage.name == oldPackageName))
            {
              'name': oldPackageName,
              'version': null,
              'kind':
                  'transitive', // Only transitive constraints can be removed.
              'constraint': null,
            },
      ];
    }

    for (final package in currentPackages.values) {
      final compatibleVersion = compatiblePackagesResult.firstWhere(
          (element) => element.name == package.name,
          orElse: () => null);
      final multiBreakingVersion = breakingPackagesResult.firstWhere(
          (element) => element.name == package.name,
          orElse: () => null);
      final singleBreakingPubspec = Pubspec(
        compatiblePubspec.name,
        version: compatiblePubspec.version,
        sdkConstraints: compatiblePubspec.sdkConstraints,
        dependencies: compatiblePubspec.dependencies.values,
        devDependencies: compatiblePubspec.devDependencies.values,
      );
      singleBreakingPubspec.dependencies[package.name] = package
          .toRange()
          .withConstraint(stripUpperBound(package.toRange().constraint));
      final singleBreakingPackagesResult =
          await _tryResolve(singleBreakingPubspec, cache);
      final singleBreakingVersion = singleBreakingPackagesResult.firstWhere(
          (element) => element.name == package.name,
          orElse: () => null);

      dependencies.add({
        'name': package.name,
        'version': package.version.toString(),
        'kind': _kindString(compatiblePubspec, package.name),
        'latest': (await cache.getLatest(package)).version.toString(),
        'constraint': _constraintOf(compatiblePubspec, package.name).toString(),
        if (compatibleVersion != null)
          'compatible': await _computeUpgradeSet(
              compatiblePubspec, compatibleVersion,
              upgradeType: UpgradeType.compatible),
        'single-breaking': await _computeUpgradeSet(
            singleBreakingPubspec, singleBreakingVersion,
            upgradeType: UpgradeType.singleBreaking),
        if (multiBreakingVersion != null)
          'multi-breaking': await _computeUpgradeSet(
              breakingPubspec, multiBreakingVersion,
              upgradeType: UpgradeType.multiBreaking),
      });
    }
    log.message(JsonEncoder.withIndent('  ').convert(result));
  }
}

VersionConstraint _constraintOf(Pubspec pubspec, String packageName) {
  return (pubspec.dependencies[packageName] ??
          pubspec.devDependencies[packageName])
      ?.constraint;
}

String _kindString(Pubspec pubspec, String packageName) {
  return pubspec.dependencies.containsKey(packageName)
      ? 'direct'
      : pubspec.devDependencies.containsKey(packageName)
          ? 'dev'
          : 'transitive';
}

/// Try to solve [pubspec] return [PackageId]s in the resolution or `null` if no
/// resolution was found.
Future<List<PackageId>> _tryResolve(Pubspec pubspec, SystemCache cache) async {
  final solveResult = await tryResolveVersions(
    SolveType.UPGRADE,
    cache,
    Package.inMemory(pubspec),
  );

  return solveResult?.packages;
}

class DependencyServicesListCommand extends PubCommand {
  @override
  String get name => 'list';

  @override
  String get description =>
      'Output a machine digestible listing of all dependencies';

  @override
  bool get takesArguments => false;

  DependencyServicesListCommand() {
    argParser.addOption('directory',
        abbr: 'C', help: 'Run this in the directory<dir>.', valueHelp: 'dir');
  }

  @override
  Future<void> runProtected() async {
    final pubspec = entrypoint.root.pubspec;

    // This list will be empty if there is no lock file.
    final currentPackages = entrypoint.lockFile.packages.values;

    final dependencies = <Object>[];
    final result = <String, Object>{'dependencies': dependencies};

    for (final package in currentPackages) {
      dependencies.add({
        'name': package.name,
        'version': package.version.toString(),
        'kind': _kindString(pubspec, package.name),
        'constraint': _constraintOf(pubspec, package.name).toString(),
      });
    }
    log.message(JsonEncoder.withIndent('  ').convert(result));
  }
}

enum UpgradeType {
  compatible,
  singleBreaking,
  multiBreaking,
}

class DependencyServicesApplyCommand extends PubCommand {
  @override
  String get name => 'apply';

  @override
  String get description =>
      'Output a machine digestible listing of all dependencies';

  @override
  bool get takesArguments => true;

  DependencyServicesApplyCommand() {
    argParser.addOption('directory',
        abbr: 'C', help: 'Run this in the directory <dir>.', valueHelp: 'dir');
  }

  @override
  Future<void> runProtected() async {
    YamlEditor(readTextFile(entrypoint.pubspecPath));
    final toApply = <_PackageVersion>[];
    final input = json.decode(utf8.decode(await collectBytes(stdin)));
    for (final change in input['dependencyChanges']) {
      toApply.add(_PackageVersion(
        change['name'],
        change['version'] != null ? Version.parse(change['version']) : null,
      ));
    }

    final pubspec = entrypoint.root.pubspec;
    final pubspecEditor = YamlEditor(readTextFile(entrypoint.pubspecPath));
    final lockFile = readTextFile(entrypoint.lockFilePath);
    final lockFileYaml = loadYaml(lockFile);
    final lockFileEditor = YamlEditor(lockFile);
    for (final p in toApply) {
      final targetPackage = p.name;
      final targetVersion = p.version;

      if (targetVersion != null) {
        final constraint = _constraintOf(pubspec, targetPackage);
        if (constraint != null && !constraint.allows(targetVersion)) {
          final section = pubspec.dependencies[targetPackage] != null
              ? 'dependencies'
              : 'dev_dependencies';
          pubspecEditor.update([section, targetPackage],
              VersionConstraint.compatibleWith(targetVersion).toString());
        }

        if (lockFileYaml['packages'].containsKey(targetPackage)) {
          lockFileEditor.update(
              ['packages', targetPackage, 'version'], targetVersion.toString());
        }
      }
    }
    if (pubspecEditor.edits.isNotEmpty) {
      writeTextFile(entrypoint.pubspecPath, pubspecEditor.toString());
    }
    if (lockFileEditor.edits.isNotEmpty) {
      writeTextFile(entrypoint.lockFilePath, lockFileEditor.toString());
    }
    await log.warningsOnlyUnlessTerminal(
      () => () async {
        // This will fail if the new configuration does not resolve.
        await Entrypoint(directory, cache)
            .acquireDependencies(SolveType.GET, dryRun: true);
      },
    );
  }
}

class _PackageVersion {
  String name;
  Version version;
  _PackageVersion(this.name, this.version);
}
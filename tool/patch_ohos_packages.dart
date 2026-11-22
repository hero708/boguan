// Patches `material_ui` and `cupertino_ui` so their switches understand
// `TargetPlatform.ohos`.
//
// Why this exists: since Flutter 3.47 the Material and Cupertino widgets live in
// two pub packages (`material_ui`, `cupertino_ui`). Both enumerate
// `TargetPlatform` in exhaustive switches, and the enum in the HarmonyOS Flutter
// fork has an extra `ohos` member. A pristine pub cache therefore fails the Dart
// kernel build with ~77 "not exhaustively matched" errors, which means a fresh
// clone cannot build until the two packages are patched.
//
// Run it right after `flutter pub get` (and after any pub cache refresh):
//
//     dart run tool/patch_ohos_packages.dart
//
// It is idempotent and prints what it changed. Pass `--check` to only report
// whether a patch is missing (exit code 1 when it is), which is what CI does.
//
// When upstream ships ohos-aware versions this file can go away: delete the
// two `hosted` patch targets and the call in the build scripts.
import 'dart:io';

const _packages = <String>['material_ui', 'cupertino_ui'];

/// `case TargetPlatform.android:` → the same label for ohos, right above it.
final _casePattern = RegExp(r'^(\s*)case TargetPlatform\.android:\s*$');

/// `TargetPlatform.android ||` → `TargetPlatform.ohos || TargetPlatform.android ||`.
final _orPattern = RegExp(r'TargetPlatform\.android \|\|');

/// Switch-expression arm `TargetPlatform.android => value,` → an ohos arm too.
final _armPattern = RegExp(r'^(\s*)TargetPlatform\.android => (.+)$');

Future<void> main(List<String> args) async {
  final checkOnly = args.contains('--check');
  final rootArg = _option(args, '--root');
  final hosted = Directory(rootArg ?? _pubHostedDir());

  if (!hosted.existsSync()) {
    _fail('找不到 pub 缓存目录：${hosted.path}');
  }
  stdout.writeln('pub 缓存：${hosted.path}');

  var changedFiles = 0;
  var changedSites = 0;
  var missing = 0;

  for (final package in _packages) {
    final dirs = hosted
        .listSync()
        .whereType<Directory>()
        .where((d) => d.path.split(Platform.pathSeparator).last.startsWith('$package-'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    if (dirs.isEmpty) {
      stdout.writeln('· $package：缓存中没有安装，跳过');
      continue;
    }
    for (final dir in dirs) {
      final lib = Directory('${dir.path}${Platform.pathSeparator}lib');
      if (!lib.existsSync()) continue;
      final name = dir.path.split(Platform.pathSeparator).last;
      var packageSites = 0;
      for (final file in lib.listSync(recursive: true).whereType<File>()) {
        if (!file.path.endsWith('.dart')) continue;
        final result = _patch(file.readAsStringSync());
        if (result.sites == 0) continue;
        if (checkOnly) {
          packageSites += result.sites;
          continue;
        }
        if (result.sites > 0) file.writeAsStringSync(result.source);
        changedFiles++;
        changedSites += result.sites;
        packageSites += result.sites;
      }
      if (packageSites == 0) {
        stdout.writeln('· $name：已是最新（无需补丁）');
      } else if (checkOnly) {
        missing += packageSites;
        stdout.writeln('· $name：缺少 $packageSites 处 ohos 分支');
      } else {
        stdout.writeln('· $name：补丁 $packageSites 处');
      }
    }
  }

  if (checkOnly) {
    if (missing > 0) {
      _fail('有 $missing 处尚未补丁，请运行：dart run tool/patch_ohos_packages.dart');
    }
    stdout.writeln('检查通过：material_ui / cupertino_ui 已支持 TargetPlatform.ohos');
    return;
  }
  stdout.writeln('完成：$changedFiles 个文件，共 $changedSites 处');
}

class _PatchResult {
  const _PatchResult(this.source, this.sites);

  final String source;
  final int sites;
}

/// Applies the three rewrites to one file, returning the new source and how
/// many sites changed. Already-patched files yield zero sites.
_PatchResult _patch(String source) {
  final lines = source.split('\n');
  final patched = <String>[];
  var sites = 0;

  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];

    // 1) Case label: mirror `case TargetPlatform.android:` for ohos.
    // A neighbouring ohos label (either side) means this site is already done;
    // labels fall through, so placement above or below is equivalent.
    final caseMatch = _casePattern.firstMatch(line);
    if (caseMatch != null) {
      final indent = caseMatch.group(1)!;
      final already = (patched.isNotEmpty &&
              patched.last.trim() == 'case TargetPlatform.ohos:') ||
          (i + 1 < lines.length &&
              lines[i + 1].trim() == 'case TargetPlatform.ohos:');
      if (!already) {
        patched.add('${indent}case TargetPlatform.ohos:');
        sites++;
      }
      patched.add(line);
      continue;
    }

    // 2) Switch-expression arm: mirror `TargetPlatform.android => value,`.
    final armMatch = _armPattern.firstMatch(line);
    if (armMatch != null) {
      final indent = armMatch.group(1)!;
      final already = (patched.isNotEmpty &&
              patched.last.trim().startsWith('TargetPlatform.ohos =>')) ||
          (i + 1 < lines.length &&
              lines[i + 1].trim().startsWith('TargetPlatform.ohos =>'));
      if (!already) {
        patched.add('${indent}TargetPlatform.ohos => ${armMatch.group(2)}');
        sites++;
      }
      patched.add(line);
      continue;
    }

    // 3) `||` chains: ohos behaves like android here, so widen the test.
    if (_orPattern.hasMatch(line) &&
        !line.contains('TargetPlatform.ohos ||')) {
      patched.add(
        line.replaceAll(
          _orPattern,
          'TargetPlatform.ohos || TargetPlatform.android ||',
        ),
      );
      sites++;
      continue;
    }

    patched.add(line);
  }

  return _PatchResult(patched.join('\n'), sites);
}

/// Hosted pub cache: `PUB_CACHE` wins, then the platform default.
String _pubHostedDir() {
  final env = Platform.environment['PUB_CACHE'];
  if (env != null && env.isNotEmpty) {
    final hosted = Directory('$env${Platform.pathSeparator}hosted');
    if (hosted.existsSync()) {
      for (final child in hosted.listSync().whereType<Directory>()) {
        return child.path;
      }
    }
    return hosted.path;
  }
  final home = Platform.environment['HOME'] ??
      Platform.environment['USERPROFILE'] ??
      '';
  final localAppData = Platform.environment['LOCALAPPDATA'];
  final root = localAppData != null && localAppData.isNotEmpty
      ? '$localAppData${Platform.pathSeparator}Pub${Platform.pathSeparator}Cache'
      : '$home${Platform.pathSeparator}.pub-cache';
  final hosted = Directory('$root${Platform.pathSeparator}hosted');
  if (hosted.existsSync()) {
    // Mirror layouts put one directory per host (pub.flutter-io.cn, pub.dev…).
    for (final child in hosted.listSync().whereType<Directory>()) {
      if (child.listSync().any((e) => e is Directory && e.path.contains('material_ui-'))) {
        return child.path;
      }
    }
  }
  return hosted.path;
}

String? _option(List<String> args, String name) {
  for (final arg in args) {
    if (arg.startsWith('$name=')) return arg.substring(name.length + 1);
  }
  return null;
}

Never _fail(String message) {
  stderr.writeln('错误：$message');
  exit(1);
}
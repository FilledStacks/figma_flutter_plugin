import 'dart:convert';
import 'dart:io';

void main() async {
  final baseUrl = 'https://rodydavis.github.io/figma_flutter_plugin';
  final generatedDir = 'lib/src/generated';

  Future<void> build() async {
    await run('flutter', [
      'build',
      'web',
      '--csp',
      '--pwa-strategy=none',
      '--web-renderer=html',
      '--base-href=/figma_flutter_plugin/',
      // '--dart2js-optimization=O1',
    ]);
  }

  // Inline all font assets as bytes
  {
    print('Inline assets...');
    final jsonFile = File('build/web/assets/FontManifest.json');
    if (!jsonFile.existsSync()) {
      await build();
    }
    if (!Directory(generatedDir).existsSync()) {
      Directory(generatedDir).createSync(recursive: true);
    }
    final json = await jsonFile.readAsString();
    final jsonData = jsonDecode(json) as List<dynamic>;
    final sb = StringBuffer();
    sb.writeln('import \'dart:ui\';');
    sb.writeln('import \'dart:typed_data\';');
    sb.writeln('import \'package:flutter/services.dart\';');
    sb.writeln('');
    sb.writeln('Future<void> loadFonts() async {');
    for (final group in jsonData) {
      final family = group['family'] as String;
      final fonts = group['fonts'] as List<dynamic>;
      for (final font in fonts) {
        final asset = font['asset'] as String;
        final file = File('build/web/assets/$asset');
        final bytes = await file.readAsBytes();
        sb.writeln('  {');
        sb.writeln('    final family = \'$family\';');
        sb.writeln(
            '    final buffer = Uint8List.fromList([${bytes.join(',')}]);');
        sb.writeln('    await loadFontFromList(buffer, fontFamily: family);');
        sb.writeln('  }');
      }
    }
    sb.writeln('}');
    final outFile = File('$generatedDir/fonts.dart');
    await outFile.writeAsString(sb.toString());

    // Update main.dart
    final mainFile = File('lib/main.dart');
    String main = await mainFile.readAsString();
    // Check for import
    if (!main.contains(
        "import '${generatedDir.replaceAll('lib/', '')}/fonts.dart';")) {
      // Add import
      main = main.replaceFirst(
        'import \'package:flutter/material.dart\';',
        'import \'package:flutter/material.dart\';\nimport \'${generatedDir.replaceAll('lib/', '')}/fonts.dart\';',
      );
    }
    // Check for loadFonts
    if (!main.contains('loadFonts();')) {
      // Add loadFonts
      if (main.contains('main() {')) {
        main = main.replaceFirst(
          'main() {',
          'main() async  {\n  await loadFonts();',
        );
      } else if (main.contains('main() async {')) {
        main = main.replaceFirst(
          'main() async {',
          'main() async {\n  await loadFonts();',
        );
      }
    }
    await mainFile.writeAsString(main);
  }

  {
    print('Building for production...');
    await build();
  }
  {
    print('Building for Figma...');
    final indexFile = File('build/web/index.html');
    if (!indexFile.existsSync()) {
      print('Error: build/web/index.html not found');
      exit(1);
    }

    final figmaDir = Directory('figma');
    if (!figmaDir.existsSync()) {
      print('Error: figma/ not found');
      exit(1);
    }
    final outDir = Directory('build/figma');
    if (!outDir.existsSync()) {
      outDir.createSync(recursive: true);
    }

    for (final file in figmaDir.listSync()) {
      if (file is File) {
        String content = await file.readAsString();
        content = content.replaceAll('\$BASE_URL', baseUrl);
        final outFile = File('${outDir.path}/${file.path.split('/').last}');
        await outFile.writeAsString(content);
      }
    }

    // Replace script tag with inline script
    final htmlFile = File('${outDir.path}/ui.html');
    String html = await htmlFile.readAsString();
    {
      final jsFile = File('build/web/flutter.js');
      final js = await jsFile.readAsString();
      final sb = StringBuffer();
      sb.writeln('<script>');
      sb.writeln(js);
      sb.writeln('</script>');
      html = html.replaceAll(
        '<script src="flutter.js" defer></script>',
        sb.toString(),
      );
    }
    {
      final jsFile = File('build/web/main.dart.js');
      String js = await jsFile.readAsString();
      final sb = StringBuffer();
      sb.writeln('<script id="app">');
      js = js.replaceAll('self.window.fetch', 'FETCH');
      sb.writeln(js);
      sb.writeln(OVERRIDES);
      sb.writeln('</script>');
      html = html.replaceAll(
        '<script id="app" src="main.dart.js" defer></script>',
        sb.toString(),
      );
    }
    final outFile = File('${outDir.path}/ui.html');
    await outFile.writeAsString(html);
  }

  print('Build complete: build/figma');
  exit(0);
}

// Run a command and exit if it fails
Future<void> run(String command, [List<String> args = const []]) async {
  final result = await Process.run(command, args, runInShell: true);
  if (result.exitCode != 0) {
    print(result.stderr);
    exit(result.exitCode);
  }
}

const OVERRIDES = r'''
// Fix for fetch
function FETCH(url, options = {}) {
  return new Promise(function (resolve, reject) {
    const id = Math.random().toString(36).substring(2, 15);
    const message = {
      pluginMessage: {
        msg_type: 'fetch',
        id: id,
        url: url,
        options: options,
      },
    };
    window.parent.postMessage(message, '*');
    window.addEventListener('message', function (event) {
      const msg = event.data.pluginMessage;
      if (msg.msg_type === 'fetch' && msg.id === id) {
        if (msg.error) {
          reject(msg.error);
        } else {
          const raw = msg.result; // Array buffer
          resolve(new Response(raw, {
            status: msg.status,
            statusText: msg.statusText,
            headers: msg.headers,
          }));
        }
      }
    });
  });
};

// Override window fetch
window.fetch = FETCH;

// Polyfill history.replaceState
function replaceState(state, title, url) {
  console.log('replaceState', state, title, url);
  return undefined;
}
window.history = window.history || {};
window.history.replaceState = replaceState;
''';

const FONTS_FIX = r'''
function loadFonts() {
  const assets = ASSETS;

  for (const { family, fonts } of assets) {
    for (const { asset } of fonts) {
      window.fetch(`${baseUrl}assets/${asset}`).then((res) => {
        return res.arrayBuffer();
      }).then((arrayBuffer) => {
        const bytes = new Uint8Array(arrayBuffer);
        const event = new CustomEvent('font', {
          detail: { family, buffer: bytes },
        });
        output.dispatchEvent(event);
      });
    }
  }
}
''';

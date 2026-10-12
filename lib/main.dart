import 'dart:ui' show AppExitResponse;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'src/persistence/store.dart';
import 'src/schema/proto_loader.dart';
import 'src/transport/engine.dart';
import 'src/transport/smoke.dart';
import 'src/presentation/controller.dart';
import 'src/presentation/design.dart';
export 'src/presentation/design.dart' show deskTheme;
import 'src/presentation/workspace.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  LicenseRegistry.addLicense(() async* {
    for (final asset in [
      'assets/protoc/LICENSE',
      'assets/fonts/LICENSE.txt',
      'assets/fonts/RobotoMono-OFL.txt',
    ]) {
      yield LicenseEntryWithLineBreaks([
        asset.contains('RobotoMono')
            ? 'Roboto Mono'
            : asset.contains('fonts')
            ? 'Satoshi'
            : 'Protocol Buffers compiler',
      ], await rootBundle.loadString(asset));
    }
  });
  try {
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final directory = await Directory.systemTemp.createTemp('protodesk-tools-');
    for (final asset in manifest.listAssets().where(
      (a) => a.startsWith('assets/protoc/'),
    )) {
      final file = File(
        p.join(directory.path, asset.substring('assets/protoc/'.length)),
      );
      await file.parent.create(recursive: true);
      final bytes = await rootBundle.load(asset);
      await file.writeAsBytes(
        bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
      );
    }
    final compiler = Platform.isMacOS
        ? p.join(
            p.dirname(p.dirname(Platform.resolvedExecutable)),
            'Helpers',
            'protoc',
          )
        : p.join(
            directory.path,
            'bin',
            Platform.isWindows ? 'protoc.exe' : 'protoc',
          );
    if (!Platform.isWindows && !Platform.isMacOS) {
      await Process.run('chmod', ['700', compiler]);
    }
    final dataPath = Platform.isMacOS
        ? await const MethodChannel('dev.apitools.protodesk/storage')
              .invokeMethod<String>('dataPath')
        : WorkspaceStore.defaultPath();
    final smokeEndpoint = Platform.environment['PROTODESK_SMOKE_ENDPOINT'];
    if (smokeEndpoint != null) {
      await releaseSmoke(
        ProtoLoader(
          compiler: compiler,
          standardRoot: p.join(directory.path, 'include'),
        ),
        directory,
        smokeEndpoint,
        nativeDataPath: Platform.isMacOS ? dataPath : null,
      );
      exit(0);
    }
    final store = WorkspaceStore.open(dataPath!);
    final desk = DeskController(
      store,
      GrpcEngine(
        ProtoLoader(
          compiler: compiler,
          standardRoot: p.join(directory.path, 'include'),
        ),
      ),
    );
    runApp(ProtoDeskApp(desk: desk, tools: directory));
  } catch (e) {
    if (Platform.environment.containsKey('PROTODESK_SMOKE_ENDPOINT')) {
      stderr.writeln('Release smoke failed: $e');
      exit(1);
    }
    runApp(
      MaterialApp(
        theme: deskTheme,
        home: Scaffold(
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(40),
              child: SelectableText(
                'ProtoDesk could not start. Your existing data has been preserved.\n\n$e',
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class ProtoDeskApp extends StatefulWidget {
  final DeskController desk;
  final Directory? tools;
  const ProtoDeskApp({super.key, required this.desk, this.tools});
  @override
  State<ProtoDeskApp> createState() => _ProtoDeskAppState();
}

class _ProtoDeskAppState extends State<ProtoDeskApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  Future<AppExitResponse> didRequestAppExit() async {
    await widget.desk.engine.disconnect();
    widget.tools?.delete(recursive: true);
    return AppExitResponse.exit;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.desk.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'ProtoDesk',
    debugShowCheckedModeBanner: false,
    theme: deskTheme,
    home: DeskWorkspace(desk: widget.desk),
  );
}

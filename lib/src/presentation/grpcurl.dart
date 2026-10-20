import 'dart:io';
import 'dart:math';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../interchange/export.dart';
import '../interchange/grpcurl.dart';
import '../interchange/shell.dart';
import '../request_options.dart';
import '../sources/configuration.dart';
import '../sources/discovery.dart';
import 'controller.dart';
import 'design.dart';

Future<void> showGrpcurl(BuildContext context, DeskController desk) =>
    showDialog<void>(context: context, builder: (_) => _GrpcurlDialog(desk));

class _GrpcurlDialog extends StatefulWidget {
  final DeskController desk;
  const _GrpcurlDialog(this.desk);
  @override
  State<_GrpcurlDialog> createState() => _GrpcurlDialogState();
}

class _GrpcurlDialogState extends State<_GrpcurlDialog> {
  final input = TextEditingController(),
      output = TextEditingController(),
      name = TextEditingController(),
      collection = TextEditingController(text: 'Imported grpcurl commands');
  CommandShell shell = Platform.isWindows
      ? CommandShell.powershell
      : CommandShell.posix;
  bool importing = false,
      includeBody = false,
      includeLiterals = false,
      includeProtected = false,
      busy = false;
  String sourcePolicy = 'profile', status = '', error = '';
  String? baseDirectory, collectionId;
  int generation = 0;
  SourceOperation? operation;
  GrpcurlCommand? parsed;
  GrpcurlPreview? preview;
  DeskController get desk => widget.desk;
  @override
  void dispose() {
    generation++;
    operation?.cancel();
    for (final controller in [input, output, name, collection]) {
      controller.dispose();
    }
    super.dispose();
  }

  void invalidate(VoidCallback update) {
    generation++;
    operation?.cancel();
    setState(() {
      update();
      preview = null;
      parsed = null;
      output.clear();
      error = '';
      status = '';
      busy = false;
    });
  }

  Future<void> generate() async {
    if (desk.server == null || desk.method == null) {
      setState(
        () => error = 'Select a method before exporting. Import does not require a connection.',
      );
      return;
    }
    final profile = {...desk.server!};
    if (sourcePolicy != 'profile') {
      profile['reflectionEnabled'] = sourcePolicy == 'reflection';
    }
    final method = desk.method!,
        body = desk.body,
        metadata = desk.metadata,
        references = desk.requestCredentials,
        authority = desk.authority;
    final timeout = desk.timeoutMs,
        selectedShell = shell,
        withBody = includeBody,
        withLiterals = includeLiterals,
        withProtected = includeProtected;
    final includeSources = sourcePolicy != 'reflection';
    final current = ++generation;
    final task = operation = SourceOperation(
      onProgress: (value) {
        if (mounted && current == generation) setState(() => status = value);
      },
    );
    setState(() {
      busy = true;
      error = '';
      preview = null;
      output.clear();
      status = 'Preparing offline command references…';
    });
    try {
      SourceManifest? manifest;
      final config = SourceConfiguration.fromRecord(profile);
      if (includeSources && !config.isEmpty) {
        manifest = await commandSourceManifest(
          desk.engine.loader,
          desk.store.path,
          config,
          task,
          expectedMethod: profile['reflectionEnabled'] == false ? method : null,
          requestBody: profile['reflectionEnabled'] == false && withBody
              ? body
              : null,
        );
      }
      task.check();
      final result = await exportGrpcurl(
        server: profile,
        method: method,
        body: body,
        requestMetadata: metadata,
        requestReferences: references,
        authority: authority,
        timeoutMs: timeout,
        shell: selectedShell,
        credentials: desk.credentials,
        sources: manifest,
        includeBody: withBody,
        includeLiteralHeaders: withLiterals,
        includeProtectedHeaders: withProtected,
      );
      if (!mounted || current != generation) return;
      setState(() {
        preview = result;
        output.text = result.command;
        status = result.redacted
            ? 'Redacted preview · replace omitted values before running/importing'
            : result.sensitive
            ? 'Contains included request data / credentials · review before copying'
            : 'Command ready';
      });
    } catch (e) {
      if (mounted && current == generation) {
        setState(() => error = e.toString());
      }
    } finally {
      if (mounted && current == generation) setState(() => busy = false);
    }
  }

  Future<void> parse() async {
    final text = input.text, selectedShell = shell;
    final current = ++generation;
    setState(() {
      busy = true;
      parsed = null;
      error = '';
      status = 'Parsing literal configuration; no shell is run…';
    });
    try {
      final result = await parseGrpcurlCommand(text, selectedShell);
      if (!mounted || current != generation) return;
      setState(() {
        parsed = result;
        name.text = 'Imported ${result.address}';
        status = 'Review configuration below. Import creates records; it does not connect or invoke.';
      });
    } catch (e) {
      if (mounted && current == generation) {
        setState(
          () => error = e is CommandSyntax
              ? e.toString()
              : 'Command parsing failed; sensitive contents omitted.',
        );
      }
    } finally {
      if (mounted && current == generation) setState(() => busy = false);
    }
  }

  Future<void> importRequest() async {
    final command = parsed;
    if (command == null) return;
    final current = ++generation;
    final task = operation = SourceOperation();
    final profileName = name.text.trim(),
        collectionName = collection.text.trim(),
        selectedCollection = collectionId,
        workingDirectory = baseDirectory;
    final options = RequestOptions(
      command.timeoutMs ?? desk.timeoutMs,
      command.authority,
    );
    setState(() {
      busy = true;
      error = '';
      status = 'Resolving local references…';
    });
    try {
      if (desk.invoking || desk.connecting) {
        throw const CommandSyntax(
          'Finish or cancel the active operation before importing.',
        );
      }
      if (profileName.isEmpty ||
          (selectedCollection == null && collectionName.isEmpty)) {
        throw const CommandSyntax('Server and collection names are required.');
      }
      final record = await commandServerRecord(
        command,
        profileName,
        task,
        baseDirectory: workingDirectory,
      );
      task.check();
      if (!mounted || current != generation) return;
      if (desk.invoking || desk.connecting) {
        throw const CommandSyntax(
          'An operation started while preparing the import. Finish it and retry.',
        );
      }
      final (profile, request) = desk.store.transaction(() {
        final profile = desk.store.save('servers', record);
        final target =
            selectedCollection ??
            desk.store.save('collections', {'name': collectionName})['id']
                as String;
        final segments = command.fullMethod.substring(1).split('/');
        final request = desk.store.save('collection_requests', {
          'name': '${segments.last} (grpcurl)',
          'collectionId': target,
          'serverId': profile['id'],
          'serverName': profile['name'],
          'serverAddress': profile['address'],
          'serviceName': segments.first,
          'methodName': segments.last,
          'fullMethod': command.fullMethod,
          'requestJson': command.body,
          'requestMetadataJson': '{}',
          'requestOptionsJson': options.encode(),
        });
        return (profile, request);
      });
      desk.refresh();
      await desk.loadImportedRequest(profile, request, options);
      if (!mounted || current != generation) return;
      Navigator.pop(context);
    } catch (e) {
      if (mounted && current == generation) {
        setState(() => error = e.toString());
      }
    } finally {
      if (mounted && current == generation) setState(() => busy = false);
    }
  }

  Future<void> chooseBase() async {
    try {
      final path = await getDirectoryPath();
      if (!mounted || path == null) return;
      if (Platform.isMacOS) {
        await const MethodChannel('dev.apitools.protodesk/storage')
            .invokeMethod<void>('rememberPath', path);
      }
      if (!mounted) return;
      setState(() => baseDirectory = path);
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    }
  }

  Widget option(String text, bool value, ValueChanged<bool> update) =>
      CheckboxListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        title: Text(text, style: DeskType.body),
        value: value,
        onChanged: busy ? null : (v) => invalidate(() => update(v!)),
      );
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('grpcurl interchange'),
    content: SizedBox(
      width: min(820, MediaQuery.sizeOf(context).width - 96),
      height: min(560, MediaQuery.sizeOf(context).height - 190),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              TextButton(
                onPressed: () => invalidate(() => importing = false),
                child: Text(
                  'Export',
                  style: importing ? DeskType.body : DeskType.heading,
                ),
              ),
              TextButton(
                onPressed: () => invalidate(() => importing = true),
                child: Text(
                  'Import',
                  style: importing ? DeskType.heading : DeskType.body,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: DeskDropdown<CommandShell>(
                  value: shell,
                  items: const [
                    DropdownMenuItem(
                      value: CommandShell.posix,
                      child: Text('POSIX shell'),
                    ),
                    DropdownMenuItem(
                      value: CommandShell.powershell,
                      child: Text('PowerShell 7.3+'),
                    ),
                  ],
                  onChanged: busy ? null : (v) => invalidate(() => shell = v!),
                  decoration: const InputDecoration(labelText: 'Shell syntax'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (!importing) ...[
                    const Text(
                      'Unary and server-stream requests only. No command is executed. Source paths use local files or validated Git caches; no repository is fetched.',
                      style: DeskType.secondary,
                    ),
                    const SizedBox(height: 12),
                    DeskDropdown<String>(
                      value: sourcePolicy,
                      items: const [
                        DropdownMenuItem(
                          value: 'profile',
                          child: Text('Configured schema sources'),
                        ),
                        DropdownMenuItem(
                          value: 'reflection',
                          child: Text('Reflection only'),
                        ),
                        DropdownMenuItem(
                          value: 'local',
                          child: Text('Local / cached proto definitions only'),
                        ),
                      ],
                      onChanged: busy
                          ? null
                          : (v) => invalidate(() => sourcePolicy = v!),
                      decoration: const InputDecoration(
                        labelText: 'Command schema source',
                      ),
                    ),
                    option(
                      'Include request JSON (may contain sensitive payloads)',
                      includeBody,
                      (v) => includeBody = v,
                    ),
                    option(
                      'Include stored literal headers (may contain reusable tokens)',
                      includeLiterals,
                      (v) => includeLiterals = v,
                    ),
                    option(
                      'Resolve and include protected headers (reads OS store; contains reusable credentials)',
                      includeProtected,
                      (v) => includeProtected = v,
                    ),
                    TextField(
                      controller: output,
                      readOnly: true,
                      style: DeskType.code,
                      minLines: 6,
                      maxLines: 12,
                      decoration: const InputDecoration(
                        labelText: 'Command / redacted preview',
                        alignLabelWithHint: true,
                      ),
                    ),
                    if (preview != null)
                      for (final note in preview!.notes)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(note, style: DeskType.secondary),
                        ),
                  ] else ...[
                    const Text(
                      'Paste one supported grpcurl command. Shell expansions/operators, stdin/file bodies, insecure TLS and unsupported flags are rejected. Imported headers remain literals until you migrate them.',
                      style: DeskType.secondary,
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: input,
                      style: DeskType.code,
                      minLines: 6,
                      maxLines: 12,
                      decoration: const InputDecoration(
                        labelText: 'grpcurl command',
                        alignLabelWithHint: true,
                      ),
                      onChanged: (_) => invalidate(() {}),
                    ),
                    if (parsed != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        '${parsed!.address} · ${parsed!.tls ? 'TLS' : 'Plaintext'} · ${parsed!.fullMethod}',
                        style: DeskType.heading,
                      ),
                      Text(
                        '${parsed!.files.length} proto entries · ${parsed!.roots.length} import roots · ${parsed!.rpcHeaders.length} RPC / ${parsed!.reflectionHeaders.length} reflection literal headers',
                        style: DeskType.secondary,
                      ),
                      for (final note in parsed!.warnings)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(note, style: DeskType.secondary),
                        ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: name,
                        decoration: const InputDecoration(
                          labelText: 'New server profile name',
                        ),
                      ),
                      const SizedBox(height: 12),
                      DeskDropdown<String>(
                        value: collectionId ?? '',
                        items: [
                          const DropdownMenuItem(
                            value: '',
                            child: Text('Create a new collection'),
                          ),
                          for (final record in desk.collections)
                            DropdownMenuItem(
                              value: record['id'] as String,
                              child: Text(record['name'] as String),
                            ),
                        ],
                        onChanged: busy
                            ? null
                            : (v) => setState(
                                () => collectionId = v!.isEmpty ? null : v,
                              ),
                        decoration: const InputDecoration(
                          labelText: 'Save imported request in',
                        ),
                      ),
                      if (collectionId == null) ...[
                        const SizedBox(height: 12),
                        TextField(
                          controller: collection,
                          decoration: const InputDecoration(
                            labelText: 'New collection name',
                          ),
                        ),
                      ],
                      const SizedBox(height: 8),
                      Text(
                        baseDirectory ?? 'No working directory selected. Choose one for relative paths that import roots cannot resolve.',
                        style: DeskType.secondary,
                      ),
                      TextButton(
                        onPressed: busy ? null : chooseBase,
                        child: const Text('Choose command working directory'),
                      ),
                    ],
                  ],
                  if (status.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(status, style: DeskType.secondary),
                    ),
                  if (error.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(
                        error,
                        style: DeskType.body.copyWith(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Close'),
      ),
      if (busy)
        TextButton(
          onPressed: () => invalidate(() {}),
          child: const Text('Cancel operation'),
        ),
      if (!importing) ...[
        TextButton(
          onPressed: busy ? null : generate,
          child: const Text('Generate'),
        ),
        FilledButton(
          onPressed: busy || preview == null
              ? null
              : () async {
                  final value = preview!;
                  await Clipboard.setData(ClipboardData(text: value.command));
                  if (mounted) {
                    setState(
                      () => status = value.redacted
                          ? 'Redacted preview copied; replace omitted values before running.'
                          : 'Copied included data. Clipboard may contain reusable credentials.',
                    );
                  }
                },
          child: Text(
            preview?.redacted == true
                ? 'Copy redacted preview'
                : 'Copy included data',
          ),
        ),
      ] else ...[
        TextButton(
          onPressed: busy ? null : parse,
          child: const Text('Parse and review'),
        ),
        FilledButton(
          onPressed: busy || parsed == null ? null : importRequest,
          child: const Text('Import server and saved request'),
        ),
      ],
    ],
  );
}

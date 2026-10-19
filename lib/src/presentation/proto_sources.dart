import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

import '../sources/configuration.dart';
import '../sources/manager.dart';
import '../schema/proto_loader.dart';
import 'design.dart';

class ProtoSourcesEditor extends StatefulWidget {
  final Map<String, Object?> initial;
  final SourceManager manager;
  final ValueChanged<Map<String, Object?>> onChanged;
  const ProtoSourcesEditor({
    super.key,
    required this.initial,
    required this.manager,
    required this.onChanged,
  });
  @override
  State<ProtoSourcesEditor> createState() => _ProtoSourcesEditorState();
}

class _ProtoSourcesEditorState extends State<ProtoSourcesEditor> {
  static const ids = Uuid();
  late Map<String, Object?> extensions;
  late List<Map<String, Object?>> sources;
  late List<Map<String, String>> roots;
  Map<int, List<String>> discovered = {};
  SchemaValidation? validation;
  SourceOperation? operation;
  String message = '';
  List<String> suggestions = [];
  bool get busy => operation != null;
  @override
  void initState() {
    super.initState();
    extensions = {...widget.initial};
    sources = (widget.initial['sources'] as List)
        .map(
          (s) => <String, Object?>{
            ...Map<String, Object?>.from(s as Map),
            'id': (s)['id'] ?? ids.v4(),
          },
        )
        .toList();
    roots = SourceConfiguration.strings(widget.initial['importRoots'])
        .map((r) => {'id': ids.v4(), 'path': r})
        .toList();
  }

  Map<String, Object?> get data => {
    ...extensions,
    'version': 1,
    'sources': sources,
    'importRoots': roots.map((r) => r['path']!).toList(),
  };
  void changed() {
    validation = null;
    extensions['validationStale'] = true;
    discovered = {};
    widget.onChanged(data);
  }

  @override
  void dispose() {
    operation?.cancel();
    super.dispose();
  }

  Future<void> remember(String path) async {
    if (Platform.isMacOS) {
      await const MethodChannel('dev.apitools.protodesk/storage')
          .invokeMethod<void>('rememberPath', path);
    }
  }

  Future<void> pick(String kind, {int? replace}) async {
    try {
      if (kind == 'file') {
        final picked = await openFiles(
          acceptedTypeGroups: [
            const XTypeGroup(label: 'Protocol Buffers', extensions: ['proto']),
          ],
        );
        if (!mounted) return;
        for (final file in picked) {
          await remember(file.path);
          if (!mounted) return;
        }
        setState(() {
          for (final file in picked) {
            if (!sources.any(
              (s) => s['type'] == 'file' && s['path'] == file.path,
            )) {
              sources.add({'id': ids.v4(), 'type': 'file', 'path': file.path});
            }
          }
          changed();
        });
      } else {
        final path = await getDirectoryPath();
        if (!mounted || path == null) return;
        await remember(path);
        if (!mounted) return;
        setState(() {
          if (kind == 'root') {
            roots.add({'id': ids.v4(), 'path': path});
          } else if (replace != null) {
            sources[replace] = {
              ...sources[replace],
              'path': path,
              'entries': null,
            };
          } else {
            sources.add({'id': ids.v4(), 'type': 'directory', 'path': path});
          }
          changed();
        });
      }
    } catch (e) {
      if (mounted) setState(() => message = e.toString());
    }
  }

  Future<void> run({bool compile = false, bool refresh = false}) async {
    if (busy) return;
    final op = SourceOperation(
      onProgress: (text) {
        if (mounted) setState(() => message = text);
      },
    );
    setState(() {
      operation = op;
      message = 'Discovering…';
    });
    try {
      final config = SourceConfiguration(data);
      if (compile) {
        final (result, manifest) = await widget.manager.validate(
          config,
          op,
          refresh: refresh,
        );
        if (!mounted) return;
        setState(() {
          validation = result;
          discovered = manifest.discovered;
          extensions = {
            ...manifest.configuration.data,
            'validationStale': false,
          };
          sources = manifest.configuration.sources;
          message =
              'Valid · ${result.schema.files.length} proto files · ${result.dependencies} dependencies · ${result.schema.services.length} services · ${result.schema.methods.length} RPC methods · ${result.metadata['warnings']} warnings';
          widget.onChanged(data);
        });
      } else {
        final manifest = await widget.manager.discover(config, op);
        if (!mounted) return;
        setState(() {
          discovered = manifest.discovered;
          message =
              '${manifest.entries.length} entry points discovered. Select files, then validate.';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          message = e.toString();
          suggestions = e is SchemaDiagnostic ? e.suggestions : [];
        });
      }
    } finally {
      if (mounted) setState(() => operation = null);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text('Proto sources', style: DeskType.heading),
      const Text(
        'Entry points define the services to compile. Import roots resolve dependencies and do not select files for compilation.',
        style: DeskType.secondary,
      ),
      Wrap(
        spacing: 8,
        children: [
          TextButton.icon(
            onPressed: busy ? null : () => pick('file'),
            icon: const Icon(Icons.note_add_outlined),
            label: const Text('Add files'),
          ),
          TextButton.icon(
            onPressed: busy ? null : () => pick('directory'),
            icon: const Icon(Icons.create_new_folder_outlined),
            label: const Text('Add folder'),
          ),
          TextButton.icon(
            onPressed: busy
                ? null
                : () => setState(() {
                    sources.add({
                      'id': ids.v4(),
                      'type': 'git',
                      'url': '',
                      'ref': 'main',
                      'directory': '',
                      'roots': [''],
                    });
                    changed();
                  }),
            icon: const Icon(Icons.cloud_download_outlined),
            label: const Text('Add Git repository'),
          ),
        ],
      ),
      if (sources.isEmpty)
        const Text(
          'No configured sources. Reflection can discover schemas from a connected server.',
          style: DeskType.secondary,
        ),
      for (var i = 0; i < sources.length; i++)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      sources[i]['type'] == 'git'
                          ? 'Git repository'
                          : sources[i]['type'] == 'file'
                          ? 'Local file'
                          : 'Local directory',
                      style: DeskType.label,
                    ),
                  ),
                  if (sources[i]['type'] == 'directory')
                    IconButton(
                      tooltip: 'Edit directory',
                      onPressed: busy
                          ? null
                          : () => pick('directory', replace: i),
                      icon: const Icon(Icons.folder_open_outlined, size: 16),
                    ),
                  IconButton(
                    tooltip: 'Remove source',
                    onPressed: busy
                        ? null
                        : () => setState(() {
                            sources.removeAt(i);
                            changed();
                          }),
                    icon: const Icon(Icons.close, size: 16),
                  ),
                ],
              ),
              if (sources[i]['type'] != 'git')
                SelectableText(
                  sources[i]['path'] as String,
                  style: DeskType.secondary,
                ),
              if (sources[i]['type'] == 'git')
                _GitFields(
                  key: ValueKey(sources[i]['id']),
                  source: sources[i],
                  enabled: !busy,
                  onChanged: (source) {
                    setState(() {
                      sources[i] = source;
                      changed();
                    });
                  },
                ),
              if (sources[i]['commit'] != null)
                SelectableText(
                  'Active revision: ${sources[i]['commit']}',
                  style: DeskType.code,
                ),
              if (discovered[i] != null)
                ExpansionTile(
                  key: ValueKey('discovery-${sources[i]['id']}'),
                  title: Text(
                    '${discovered[i]!.length} discovered files',
                    style: DeskType.body,
                  ),
                  tilePadding: EdgeInsets.zero,
                  children: [
                    if (sources[i]['type'] != 'file')
                      Row(
                        children: [
                          TextButton(
                            onPressed: busy
                                ? null
                                : () => setState(() {
                                    sources[i].remove('entries');
                                    widget.onChanged(data);
                                  }),
                            child: const Text('Select all'),
                          ),
                          TextButton(
                            onPressed: busy
                                ? null
                                : () => setState(() {
                                    sources[i]['entries'] = <String>[];
                                    widget.onChanged(data);
                                  }),
                            child: const Text('Select none'),
                          ),
                        ],
                      ),
                    SizedBox(
                      height: discovered[i]!.length > 6
                          ? 210
                          : discovered[i]!.length * 32.0,
                      child: ListView.builder(
                        itemCount: discovered[i]!.length,
                        itemBuilder: (context, index) {
                          final name = discovered[i]![index];
                          final selected =
                              sources[i]['entries'] == null ||
                              SourceConfiguration.strings(sources[i]['entries'])
                                  .contains(name);
                          return Row(
                            children: [
                              SizedBox(
                                height: 32,
                                width: 32,
                                child: Checkbox(
                                  value: selected,
                                  onChanged:
                                      busy || sources[i]['type'] == 'file'
                                      ? null
                                      : (value) => setState(() {
                                          final entries =
                                              sources[i]['entries'] == null
                                              ? [...discovered[i]!]
                                              : SourceConfiguration.strings(
                                                  sources[i]['entries'],
                                                );
                                          if (value == true) {
                                            if (!entries.contains(name)) {
                                              entries.add(name);
                                            }
                                          } else {
                                            entries.remove(name);
                                          }
                                          sources[i]['entries'] = entries;
                                          validation = null;
                                          widget.onChanged(data);
                                        }),
                                ),
                              ),
                              Expanded(child: Text(name, style: DeskType.code)),
                            ],
                          );
                        },
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
      for (final suggestion in suggestions)
        TextButton(
          onPressed: busy
              ? null
              : () async {
                  // Native folder selection grants access; never silently request access to an ancestor.
                  await pick('root');
                },
          child: Text(
            'Suggested import root: $suggestion — select folder to grant access',
          ),
        ),
      const Text('Import roots', style: DeskType.heading),
      for (var i = 0; i < roots.length; i++)
        Row(
          children: [
            Expanded(
              child: _RootField(
                key: ValueKey(roots[i]['id']),
                initial: roots[i]['path']!,
                enabled: !busy,
                onChanged: (v) {
                  setState(() {
                    roots[i]['path'] = v;
                    changed();
                  });
                },
              ),
            ),
            IconButton(
              tooltip: 'Remove import root',
              onPressed: busy
                  ? null
                  : () => setState(() {
                      roots.removeAt(i);
                      changed();
                    }),
              icon: const Icon(Icons.close, size: 16),
            ),
          ],
        ),
      TextButton.icon(
        onPressed: busy ? null : () => pick('root'),
        icon: const Icon(Icons.folder_open_outlined),
        label: const Text('Add import root'),
      ),
      if (sources.any((s) => s['type'] == 'file'))
        TextButton(
          onPressed: busy
              ? null
              : () => setState(() {
                  for (final source in sources.where(
                    (s) => s['type'] == 'file',
                  )) {
                    final parent = File(source['path'] as String).parent.path;
                    if (!roots.any((r) => r['path'] == parent)) {
                      roots.add({'id': ids.v4(), 'path': parent});
                    }
                  }
                  changed();
                }),
          child: const Text('Use suggested file-parent roots'),
        ),
      Wrap(
        spacing: 8,
        children: [
          TextButton(
            onPressed: busy ? null : () => run(),
            child: const Text('Discover files'),
          ),
          TextButton(
            onPressed: busy ? null : () => run(compile: true),
            child: const Text('Validate'),
          ),
          if (sources.any((s) => s['type'] == 'git'))
            TextButton(
              onPressed: busy ? null : () => run(compile: true, refresh: true),
              child: const Text('Refresh'),
            ),
          if (busy)
            TextButton(
              onPressed: () => operation?.cancel(),
              child: const Text('Cancel operation'),
            ),
        ],
      ),
      if (busy) const LinearProgressIndicator(),
      if (message.isNotEmpty)
        SelectableText(message, style: DeskType.secondary),
      if (extensions['validation'] is Map)
        Text(
          'Last successful validation: ${(extensions['validation'] as Map)['at']}${extensions['validationStale'] == true ? ' (configuration changed; validate again)' : ''}',
          style: DeskType.secondary,
        ),
      if (validation != null)
        ExpansionTile(
          title: const Text(
            'Services, methods and import resolution',
            style: DeskType.body,
          ),
          children: [
            for (final method in validation!.schema.methods.values)
              SelectableText(method.path, style: DeskType.code),
            for (final entry in validation!.resolved.entries)
              SelectableText(
                '${entry.key}\n  → ${entry.value}',
                style: DeskType.secondary,
              ),
            if (validation!.output.isNotEmpty)
              SelectableText(validation!.output, style: DeskType.code),
          ],
        ),
    ],
  );
}

class _RootField extends StatefulWidget {
  final String initial;
  final bool enabled;
  final ValueChanged<String> onChanged;
  const _RootField({
    super.key,
    required this.initial,
    required this.enabled,
    required this.onChanged,
  });
  @override
  State<_RootField> createState() => _RootFieldState();
}

class _RootFieldState extends State<_RootField> {
  late final controller = TextEditingController(text: widget.initial);
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(
    controller: controller,
    enabled: widget.enabled,
    onChanged: widget.onChanged,
    style: DeskType.body,
    decoration: const InputDecoration(labelText: 'Import root path'),
  );
}

class _GitFields extends StatefulWidget {
  final Map<String, Object?> source;
  final bool enabled;
  final ValueChanged<Map<String, Object?>> onChanged;
  const _GitFields({
    super.key,
    required this.source,
    required this.enabled,
    required this.onChanged,
  });
  @override
  State<_GitFields> createState() => _GitFieldsState();
}

class _GitFieldsState extends State<_GitFields> {
  late final fields = {
    for (final key in ['url', 'ref', 'directory', 'roots'])
      key: TextEditingController(
        text: key == 'roots'
            ? SourceConfiguration.strings(widget.source[key]).join('\n')
            : widget.source[key]?.toString() ?? '',
      ),
  };
  @override
  void dispose() {
    for (final field in fields.values) {
      field.dispose();
    }
    super.dispose();
  }

  void update() {
    final value = {
      ...widget.source,
      for (final field in fields.entries)
        field.key: field.key == 'roots'
            ? field.value.text.split('\n').map((s) => s.trim()).toList()
            : field.value.text.trim(),
    };
    value.remove('commit');
    value.remove('cachedAt');
    widget.onChanged(value);
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      for (final key in fields.keys)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: TextField(
            controller: fields[key],
            enabled: widget.enabled,
            style: DeskType.body,
            onChanged: (_) => update(),
            maxLines: key == 'roots' ? 3 : 1,
            decoration: InputDecoration(
              labelText: {
                'url': 'Repository URL (public GitHub HTTPS)',
                'ref': 'Branch / tag / commit',
                'directory': 'Proto directory (repository relative)',
                'roots': 'Repository import roots (one per line; blank = repository root)',
              }[key],
            ),
          ),
        ),
    ],
  );
}

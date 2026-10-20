import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../persistence/store.dart';
import '../transport/engine.dart';
import 'controller.dart';
import 'design.dart';
import 'proto_sources.dart';
import '../sources/configuration.dart';
import '../sources/manager.dart';

Future<Record?> editRecord(
  BuildContext context,
  DeskController desk,
  String table, [
  Record? record,
]) => showDialog<Record>(
  context: context,
  builder: (_) => _EditRecordDialog(desk: desk, table: table, record: record),
);

class _EditRecordDialog extends StatefulWidget {
  final DeskController desk;
  final String table;
  final Record? record;
  const _EditRecordDialog({
    required this.desk,
    required this.table,
    this.record,
  });
  @override
  State<_EditRecordDialog> createState() => _EditRecordDialogState();
}

class _EditRecordDialogState extends State<_EditRecordDialog> {
  DeskController get desk => widget.desk;
  String get table => widget.table;
  Record? get record => widget.record;
  late final Map<String, TextEditingController> fields;
  late final List<String> files, folders;
  late bool tls, reflection;
  late String caFile, clientCertificateFile, clientKeyFile;
  String? error;
  late Map<String, Object?> sourceData;
  String? sourceError;

  @override
  void initState() {
    super.initState();
    final keys = table == 'servers'
        ? [
            'name',
            'address',
            'metadataJson',
            'reflectionMetadataJson',
            'tlsServerName',
          ]
        : table == 'collections'
        ? ['name', 'description']
        : ['name', 'requestJson', 'requestStreamJson', 'requestMetadataJson'];
    fields = {
      for (final key in keys)
        key: TextEditingController(
          text:
              record?[key]?.toString() ??
              (key == 'reflectionMetadataJson'
                  ? ''
                  : key.endsWith('Json')
                  ? (key == 'requestStreamJson' ? '[]' : '{}')
                  : ''),
        ),
    };
    tls = record?['tlsEnabled'] == true;
    reflection = record?['reflectionEnabled'] != false;
    files = (record?['protoFiles'] as List? ?? []).cast<String>().toList();
    folders = (record?['protoFolders'] as List? ?? []).cast<String>().toList();
    caFile = record?['tlsCaFile'] as String? ?? '';
    clientCertificateFile =
        record?['tlsClientCertificateFile'] as String? ?? '';
    clientKeyFile = record?['tlsClientKeyFile'] as String? ?? '';
    try {
      sourceData = SourceConfiguration.fromRecord(record ?? {}).data;
    } catch (e) {
      sourceError = e.toString();
      sourceData = SourceConfiguration.legacy(files, folders).data;
    }
  }

  @override
  void dispose() {
    for (final field in fields.values) {
      field.dispose();
    }
    super.dispose();
  }

  Widget identityFile(
    String label,
    String path,
    void Function(String) update,
  ) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SelectableText(
        path.isEmpty ? '$label: not configured' : path,
        style: DeskType.secondary,
      ),
      Wrap(
        spacing: 8,
        children: [
          TextButton(
            onPressed: () async {
              try {
                final file = await openFile(
                  acceptedTypeGroups: [
                    const XTypeGroup(
                      label: 'PEM',
                      extensions: ['pem', 'crt', 'key'],
                    ),
                  ],
                );
                if (!mounted || file == null) return;
                if (Platform.isMacOS) {
                  await const MethodChannel('dev.apitools.protodesk/storage')
                      .invokeMethod<void>('rememberPath', file.path);
                }
                if (!mounted) return;
                setState(() => update(file.path));
              } catch (_) {
                if (mounted) {
                  setState(
                    () => error =
                        'Could not access $label. Reselect the file and grant access.',
                  );
                }
              }
            },
            child: Text('Choose $label'),
          ),
          if (path.isNotEmpty)
            TextButton(
              onPressed: () => setState(() => update('')),
              child: Text('Clear $label'),
            ),
        ],
      ),
    ],
  );

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      '${record == null ? 'Create' : 'Edit'} ${table == 'servers'
          ? 'server'
          : table == 'collections'
          ? 'collection'
          : 'saved request'}',
    ),
    content: SizedBox(
      width: table == 'servers' ? 820 : 620,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final key in fields.keys)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: TextField(
                  controller: fields[key],
                  style: key.endsWith('Json') ? DeskType.code : DeskType.body,
                  decoration: InputDecoration(
                    helperMaxLines: 2,
                    helperText: switch (key) {
                      'reflectionMetadataJson' => 'Blank inherits RPC metadata. {} sends no reflection metadata.',
                      'tlsServerName' => 'Set to separate TLS certificate verification from call authority. Blank preserves legacy behavior.',
                      _ => null,
                    },
                    labelText: switch (key) {
                      'reflectionMetadataJson' => 'Reflection metadata JSON',
                      'tlsServerName' => 'TLS server name / SNI',
                      _ => key,
                    },
                  ),
                  minLines: key.endsWith('Json') ? 3 : 1,
                  maxLines: key.endsWith('Json') ? 5 : 1,
                ),
              ),
            if (table == 'servers') ...[
              SwitchListTile(
                dense: true,
                visualDensity: VisualDensity.compact,
                contentPadding: EdgeInsets.zero,
                title: const Text('TLS'),
                value: tls,
                onChanged: (v) => setState(() => tls = v),
              ),
              if (!tls &&
                  (clientCertificateFile.isNotEmpty ||
                      clientKeyFile.isNotEmpty)) ...[
                const Text(
                  'Configured client identity requires TLS. Enable TLS or explicitly clear the identity.',
                  style: DeskType.secondary,
                ),
                TextButton(
                  onPressed: () => setState(() {
                    clientCertificateFile = '';
                    clientKeyFile = '';
                  }),
                  child: const Text('Clear client identity'),
                ),
              ],
              if (tls) ...[
                const Text('Client identity (mTLS)', style: DeskType.heading),
                const Text(
                  'Optional PEM chain and matching unencrypted PEM key. Only file references are saved.',
                  style: DeskType.secondary,
                ),
                identityFile(
                  'client certificate',
                  clientCertificateFile,
                  (v) => clientCertificateFile = v,
                ),
                identityFile(
                  'client private key',
                  clientKeyFile,
                  (v) => clientKeyFile = v,
                ),
                const Text('TLS trust', style: DeskType.heading),
                SelectableText(
                  caFile.isEmpty ? 'System trust roots' : caFile,
                  style: DeskType.secondary,
                ),
                Wrap(
                  spacing: 8,
                  children: [
                    TextButton.icon(
                      icon: const Icon(Icons.file_open_outlined),
                      label: const Text('Choose CA certificate'),
                      onPressed: () async {
                        final picked = await openFile(
                          acceptedTypeGroups: [
                            const XTypeGroup(
                              label: 'CA certificate',
                              extensions: ['pem', 'crt', 'cer'],
                            ),
                          ],
                        );
                        if (!mounted || picked == null) return;
                        if (Platform.isMacOS) {
                          await const MethodChannel(
                            'dev.apitools.protodesk/storage',
                          ).invokeMethod<void>('rememberPath', picked.path);
                        }
                        if (!mounted) return;
                        setState(() => caFile = picked.path);
                      },
                    ),
                    if (caFile.isNotEmpty)
                      TextButton(
                        onPressed: () => setState(() => caFile = ''),
                        child: const Text('Use system roots'),
                      ),
                  ],
                ),
              ],
              SwitchListTile(
                dense: true,
                visualDensity: VisualDensity.compact,
                contentPadding: EdgeInsets.zero,
                title: const Text('Server reflection'),
                value: reflection,
                onChanged: (v) => setState(() => reflection = v),
              ),
              if (sourceError != null) ...[
                SelectableText(sourceError!, style: DeskType.secondary),
                TextButton(
                  onPressed: () => setState(() => sourceError = null),
                  child: const Text(
                    'Replace invalid sources (saved only when you click Save)',
                  ),
                ),
              ] else
                ProtoSourcesEditor(
                  initial: sourceData,
                  manager: SourceManager.forWorkspace(
                    desk.engine.loader,
                    desk.store.path,
                  ),
                  onChanged: (value) => sourceData = value,
                ),
            ],
            if (error != null)
              Text(error!, style: const TextStyle(color: Colors.redAccent)),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () {
          try {
            final value = <String, Object?>{
              ...?record,
              for (final e in fields.entries) e.key: e.value.text,
              if (table == 'servers') ...{
                'tlsEnabled': tls,
                'tlsCaFile': caFile,
                'tlsClientCertificateFile': clientCertificateFile,
                'tlsClientKeyFile': clientKeyFile,
                'reflectionEnabled': reflection,
                'protoSources': SourceConfiguration(sourceData).data,
                'protoFiles': (sourceData['sources'] as List)
                    .where((s) => s['type'] == 'file')
                    .map((s) => s['path'] as String)
                    .toList(),
                'protoFolders': (sourceData['sources'] as List)
                    .where((s) => s['type'] == 'directory')
                    .map((s) => s['path'] as String)
                    .toList(),
              },
            };
            if (table == 'servers') {
              if (sourceError != null) throw FormatException(sourceError!);
              value.remove('sourceError');
              value.remove('protoSourcesJson');
              value.remove('protoFilesJson');
              value.remove('protoFoldersJson');
              ConnectionConfig(value['address'] as String).endpoint;
              DeskController.parseMetadata(value['metadataJson'] as String);
              final reflection = value['reflectionMetadataJson'] as String;
              if (reflection.trim().isNotEmpty) {
                DeskController.parseMetadata(reflection);
              }
              if (tls &&
                  clientCertificateFile.isEmpty != clientKeyFile.isEmpty) {
                throw const FormatException(
                  'Select both client certificate and private key, or clear both',
                );
              }
            }
            if (table == 'collection_requests') {
              jsonDecode(value['requestJson'] as String);
              DeskController.parseMetadata(
                value['requestMetadataJson'] as String,
              );
            }
            if (fields['name']!.text.trim().isEmpty) {
              throw const FormatException('Name is required');
            }
            Navigator.pop(context, value);
          } catch (e) {
            setState(() => error = e.toString());
          }
        },
        child: const Text('Save'),
      ),
    ],
  );
}

Future<void> showServers(BuildContext context, DeskController desk) async {
  await showDialog<void>(
    context: context,
    builder: (context) => AnimatedBuilder(
      animation: desk,
      builder: (context, _) => AlertDialog(
        title: const Text('Saved servers'),
        content: SizedBox(
          width: 760,
          height: 420,
          child: ListView(
            children: [
              if (desk.servers.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'No saved servers. Choose New server to add your endpoint.',
                  ),
                ),
              for (final s in desk.servers)
                ListTile(
                  title: Text(s['name'] as String),
                  subtitle: Text(
                    '${s['address']} · ${s['tlsEnabled'] == true ? 'TLS' : 'Plaintext'}',
                  ),
                  leading: Icon(
                    s['id'] == desk.server?['id']
                        ? Icons.check_circle
                        : Icons.dns_outlined,
                  ),
                  onTap: () {
                    desk.selectServer(s);
                    Navigator.pop(context);
                  },
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: 'Edit server',
                        onPressed: () async {
                          final edited = await editRecord(
                            context,
                            desk,
                            'servers',
                            s,
                          );
                          if (edited != null) {
                            desk.store.save('servers', edited);
                            if (desk.server?['id'] == s['id']) {
                              desk.server = edited;
                            }
                            desk.refresh();
                          }
                        },
                        icon: const Icon(Icons.edit_outlined),
                      ),
                      IconButton(
                        tooltip: 'Delete server',
                        onPressed: () {
                          desk.store.delete('servers', s['id'] as String);
                          if (desk.server?['id'] == s['id']) desk.server = null;
                          desk.refresh();
                        },
                        icon: const Icon(Icons.delete_outline),
                      ),
                    ],
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
          FilledButton.icon(
            onPressed: () async {
              final created = await editRecord(context, desk, 'servers');
              if (created != null) {
                final saved = desk.store.save('servers', created);
                desk.server = saved;
                desk.refresh();
              }
            },
            icon: const Icon(Icons.add),
            label: const Text('New server'),
          ),
        ],
      ),
    ),
  );
}

Future<void> saveExample(
  BuildContext context,
  DeskController desk, [
  Record? snapshot,
]) async {
  final data = snapshot ?? desk.requestSnapshot();
  if ((data['fullMethod'] ?? '') == '') {
    desk.status = 'Select a method before saving an example';
    desk.emit();
    return;
  }
  if (desk.collections.isEmpty) {
    desk.store.save('collections', {'name': 'Personal', 'description': ''});
    desk.refresh();
  }
  final selection = await showDialog<Record>(
    context: context,
    builder: (_) => _SaveExampleDialog(desk: desk, data: data),
  );
  if (selection != null) {
    desk.store.save('collection_requests', {
      for (final key in [
        'serverId',
        'serverName',
        'serverAddress',
        'serviceName',
        'methodName',
        'fullMethod',
        'requestJson',
        'requestStreamJson',
        'requestMetadataJson',
      ])
        key: data[key],
      ...selection,
    });
    desk.refresh();
  }
}

class _SaveExampleDialog extends StatefulWidget {
  final DeskController desk;
  final Record data;
  const _SaveExampleDialog({required this.desk, required this.data});
  @override
  State<_SaveExampleDialog> createState() => _SaveExampleDialogState();
}

class _SaveExampleDialogState extends State<_SaveExampleDialog> {
  late final TextEditingController name;
  late String collection;
  @override
  void initState() {
    super.initState();
    collection = widget.desk.collections.first['id'] as String;
    name = TextEditingController(
      text: widget.data['methodName'] as String? ?? 'Request',
    );
  }

  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Save request example'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        DeskDropdown<String>(
          value: collection,
          decoration: const InputDecoration(),
          items: [
            for (final c in widget.desk.collections)
              DropdownMenuItem(
                value: c['id'] as String,
                child: Text(c['name'] as String),
              ),
          ],
          onChanged: (v) => setState(() => collection = v!),
        ),
        const SizedBox(height: DeskSpace.panel),
        TextField(
          controller: name,
          decoration: const InputDecoration(labelText: 'Name'),
        ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, <String, Object?>{
          'collectionId': collection,
          'name': name.text,
        }),
        child: const Text('Save'),
      ),
    ],
  );
}

Future<void> showCollections(BuildContext context, DeskController desk) async {
  await showDialog<void>(
    context: context,
    builder: (context) => AnimatedBuilder(
      animation: desk,
      builder: (context, _) => AlertDialog(
        title: const Text('Collections'),
        content: SizedBox(
          width: 840,
          height: 500,
          child: ListView(
            children: [
              if (desk.collections.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'Create a collection to keep reusable request examples.',
                  ),
                ),
              for (final c in desk.collections)
                ExpansionTile(
                  initiallyExpanded: true,
                  title: Text(c['name'] as String),
                  subtitle: Text(c['description'] as String? ?? ''),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: 'Edit collection',
                        onPressed: () async {
                          final value = await editRecord(
                            context,
                            desk,
                            'collections',
                            c,
                          );
                          if (value != null) {
                            desk.store.save('collections', value);
                            desk.refresh();
                          }
                        },
                        icon: const Icon(Icons.edit_outlined),
                      ),
                      IconButton(
                        tooltip: 'Delete collection',
                        onPressed: () {
                          desk.store.delete('collections', c['id'] as String);
                          desk.refresh();
                        },
                        icon: const Icon(Icons.delete_outline),
                      ),
                    ],
                  ),
                  children: [
                    for (final item in (c['requests'] as List).cast<Record>())
                      ListTile(
                        title: Text(item['name'] as String),
                        subtitle: Text(item['fullMethod'] as String),
                        onTap: () => previewRequest(context, desk, item, false),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              tooltip: 'Load example',
                              onPressed: () {
                                desk.loadRequest(item);
                                Navigator.pop(context);
                              },
                              icon: const Icon(Icons.play_arrow),
                            ),
                            IconButton(
                              tooltip: 'Edit example',
                              onPressed: () async {
                                final value = await editRecord(
                                  context,
                                  desk,
                                  'collection_requests',
                                  item,
                                );
                                if (value != null) {
                                  desk.store.save('collection_requests', value);
                                  desk.refresh();
                                }
                              },
                              icon: const Icon(Icons.edit_outlined),
                            ),
                            IconButton(
                              tooltip: 'Delete example',
                              onPressed: () {
                                desk.store.delete(
                                  'collection_requests',
                                  item['id'] as String,
                                );
                                desk.refresh();
                              },
                              icon: const Icon(Icons.delete_outline),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
          TextButton(
            onPressed: desk.method == null
                ? null
                : () => saveExample(context, desk),
            child: const Text('Save current request'),
          ),
          FilledButton.icon(
            onPressed: () async {
              final value = await editRecord(context, desk, 'collections');
              if (value != null) {
                desk.store.save('collections', value);
                desk.refresh();
              }
            },
            icon: const Icon(Icons.add),
            label: const Text('New collection'),
          ),
        ],
      ),
    ),
  );
}

Future<void> showHistory(BuildContext context, DeskController desk) async {
  await showDialog<void>(
    context: context,
    builder: (context) => AnimatedBuilder(
      animation: desk,
      builder: (context, _) => AlertDialog(
        title: const Text('Invocation history'),
        content: SizedBox(
          width: 850,
          height: 500,
          child: ListView(
            children: [
              if (desk.history.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'Completed calls appear here. History stays on this computer.',
                  ),
                ),
              for (final item in desk.history)
                ListTile(
                  title: Text(
                    '${item['methodName']} · ${item['statusCode']} · ${item['durationMs']} ms',
                  ),
                  subtitle: Text(
                    '${item['serverAddress']} · ${item['createdAt']}',
                  ),
                  onTap: () => previewRequest(context, desk, item, true),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: 'Reuse request',
                        onPressed: () {
                          desk.loadRequest(item);
                          Navigator.pop(context);
                        },
                        icon: const Icon(Icons.replay),
                      ),
                      IconButton(
                        tooltip: 'Save to collection',
                        onPressed: () => saveExample(context, desk, item),
                        icon: const Icon(Icons.bookmark_add_outlined),
                      ),
                      IconButton(
                        tooltip: 'Delete history item',
                        onPressed: () {
                          desk.store.delete(
                            'history_items',
                            item['id'] as String,
                          );
                          desk.refresh();
                        },
                        icon: const Icon(Icons.delete_outline),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              desk.store.clearHistory();
              desk.refresh();
            },
            child: const Text('Clear history'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    ),
  );
}

Future<void> previewRequest(
  BuildContext context,
  DeskController desk,
  Record item,
  bool history,
) async {
  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(item['fullMethod'] as String),
      content: SizedBox(
        width: 740,
        height: 430,
        child: SingleChildScrollView(
          child: SelectionArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('REQUEST'),
                Text(item['requestJson'] as String, style: DeskType.code),
                const SizedBox(height: DeskSpace.panel),
                if ((item['requestStreamJson'] as String? ?? '[]') != '[]') ...[
                  const Text('REQUEST STREAM'),
                  Text(
                    item['requestStreamJson'] as String,
                    style: DeskType.code,
                  ),
                  const SizedBox(height: DeskSpace.panel),
                ],
                const Text('METADATA'),
                Text(
                  item['requestMetadataJson'] as String,
                  style: DeskType.code,
                ),
                if (history) ...[
                  const SizedBox(height: DeskSpace.panel),
                  Text('RESPONSE · ${item['statusCode']}'),
                  Text(item['responseJson'] as String, style: DeskType.code),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        if ((item['requestStreamJson'] as String? ?? '[]') != '[]')
          TextButton(
            onPressed: () => Clipboard.setData(
              ClipboardData(text: item['requestStreamJson'] as String),
            ),
            child: const Text('Copy request stream'),
          ),
        TextButton(
          onPressed: () => Clipboard.setData(
            ClipboardData(
              text: item[history ? 'responseJson' : 'requestJson'] as String,
            ),
          ),
          child: const Text('Copy'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
        FilledButton(
          onPressed: () {
            desk.loadRequest(item);
            Navigator.pop(context);
          },
          child: const Text('Reuse request'),
        ),
      ],
    ),
  );
}

Future<void> showWorkspace(BuildContext context, DeskController desk) async {
  String message =
      'Version 2 export · Version 1/2 import · Servers, proto references, collections, and examples. History is excluded. Imports create new records.';
  await showDialog<void>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: const Text('Workspace transfer'),
        content: SizedBox(width: 560, child: SelectableText(message)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
          TextButton.icon(
            onPressed: () async {
              try {
                final file = await openFile(
                  acceptedTypeGroups: [
                    const XTypeGroup(
                      label: 'Workspace JSON',
                      extensions: ['json'],
                    ),
                  ],
                );
                if (!context.mounted || file == null) return;
                if (await File(file.path).length() > 32 * 1024 * 1024) {
                  throw const FormatException('Workspace exceeds 32 MiB');
                }
                final contents = await file.readAsString();
                if (!context.mounted) return;
                final counts = desk.store.importWorkspace(jsonDecode(contents));
                desk.refresh();
                if (!context.mounted) return;
                setState(
                  () => message =
                      'Imported ${counts['serverCount']} servers, ${counts['collectionCount']} collections, ${counts['savedRequestCount']} examples.',
                );
              } catch (e) {
                if (!context.mounted) return;
                setState(() => message = e.toString());
              }
            },
            icon: const Icon(Icons.file_open_outlined),
            label: const Text('Import'),
          ),
          FilledButton.icon(
            onPressed: () async {
              try {
                final location = await getSaveLocation(
                  suggestedName: 'protodesk-workspace.json',
                  acceptedTypeGroups: [
                    const XTypeGroup(
                      label: 'Workspace JSON',
                      extensions: ['json'],
                    ),
                  ],
                );
                if (!context.mounted || location == null) return;
                await XFile.fromData(
                  utf8.encode(
                    '${pretty.convert(desk.store.exportWorkspace())}\n',
                  ),
                  mimeType: 'application/json',
                ).saveTo(location.path);
                if (!Platform.isWindows) {
                  await Process.run('chmod', ['600', location.path]);
                }
                if (!context.mounted) return;
                setState(
                  () => message = 'Exported workspace to ${location.path}',
                );
              } catch (e) {
                if (!context.mounted) return;
                setState(() => message = e.toString());
              }
            },
            icon: const Icon(Icons.save_alt),
            label: const Text('Export'),
          ),
        ],
      ),
    ),
  );
}

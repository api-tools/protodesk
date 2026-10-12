import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../persistence/store.dart';
import '../transport/engine.dart';
import 'controller.dart';
import 'design.dart';

Future<Record?> editRecord(
  BuildContext context,
  DeskController desk,
  String table, [
  Record? record,
]) async {
  final keys = table == 'servers'
      ? ['name', 'address', 'metadataJson']
      : table == 'collections'
      ? ['name', 'description']
      : ['name', 'requestJson', 'requestMetadataJson'];
  final fields = {
    for (final key in keys)
      key: TextEditingController(
        text:
            record?[key]?.toString() ??
            (key.endsWith('Json')
                ? '{}'
                : key == 'address'
                ? 'localhost:50051'
                : ''),
      ),
  };
  var tls = record?['tlsEnabled'] == true,
      reflection = record?['reflectionEnabled'] != false;
  final files = (record?['protoFiles'] as List? ?? []).cast<String>().toList();
  final folders = (record?['protoFolders'] as List? ?? [])
      .cast<String>()
      .toList();
  String? error;
  var validation = '';
  final result = await showDialog<Record>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text(
          '${record == null ? 'Create' : 'Edit'} ${table == 'servers'
              ? 'server'
              : table == 'collections'
              ? 'collection'
              : 'saved request'}',
        ),
        content: SizedBox(
          width: 620,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final key in keys)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: TextField(
                      controller: fields[key],
                      style: key.endsWith('Json')
                          ? DeskType.code
                          : DeskType.body,
                      decoration: InputDecoration(labelText: key),
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
                  SwitchListTile(
                    dense: true,
                    visualDensity: VisualDensity.compact,
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Server reflection'),
                    value: reflection,
                    onChanged: (v) => setState(() => reflection = v),
                  ),
                  const Text('Proto sources', style: DeskType.heading),
                  for (final file in [...files, ...folders])
                    Row(
                      children: [
                        Expanded(
                          child: SelectableText(
                            file,
                            style: DeskType.secondary,
                          ),
                        ),
                        IconButton(
                          tooltip: 'Remove source',
                          onPressed: () => setState(() {
                            files.remove(file);
                            folders.remove(file);
                          }),
                          icon: const Icon(Icons.close, size: 16),
                        ),
                      ],
                    ),
                  Wrap(
                    spacing: 8,
                    children: [
                      TextButton.icon(
                        onPressed: () async {
                          final picked = await openFiles(
                            acceptedTypeGroups: [
                              const XTypeGroup(
                                label: 'Protocol Buffers',
                                extensions: ['proto'],
                              ),
                            ],
                          );
                          for (final file in picked) {
                            if (Platform.isMacOS) {
                              await const MethodChannel(
                                'dev.apitools.protodesk/storage',
                              ).invokeMethod<void>('rememberPath', file.path);
                            }
                          }
                          setState(() {
                            for (final f in picked) {
                              if (!files.contains(f.path)) files.add(f.path);
                            }
                          });
                        },
                        icon: const Icon(Icons.note_add_outlined),
                        label: const Text('Add files'),
                      ),
                      TextButton.icon(
                        onPressed: () async {
                          final path = await getDirectoryPath();
                          if (path != null) {
                            if (Platform.isMacOS) {
                              await const MethodChannel(
                                'dev.apitools.protodesk/storage',
                              ).invokeMethod<void>('rememberPath', path);
                            }
                            setState(() {
                              if (!folders.contains(path)) folders.add(path);
                            });
                          }
                        },
                        icon: const Icon(Icons.create_new_folder_outlined),
                        label: const Text('Add folder'),
                      ),
                      TextButton(
                        onPressed: () async {
                          setState(() => validation = 'Validating…');
                          try {
                            final schema = await desk.engine.loader.load(
                              files,
                              folders,
                            );
                            setState(
                              () => validation =
                                  'Valid · ${schema.files.length} files · ${schema.services.length} services',
                            );
                          } catch (e) {
                            setState(() => validation = e.toString());
                          }
                        },
                        child: const Text('Validate'),
                      ),
                    ],
                  ),
                  if (validation.isNotEmpty) SelectableText(validation),
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
                    'reflectionEnabled': reflection,
                    'protoFiles': files,
                    'protoFolders': folders,
                  },
                };
                if (table == 'servers') {
                  ConnectionConfig(value['address'] as String).endpoint;
                  DeskController.parseMetadata(value['metadataJson'] as String);
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
      ),
    ),
  );
  for (final field in fields.values) {
    field.dispose();
  }
  return result;
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
  var collection = desk.collections.first['id'] as String;
  final name = TextEditingController(
    text: data['methodName'] as String? ?? 'Request',
  );
  final accepted = await showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: const Text('Save request example'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DeskDropdown<String>(
              value: collection,
              decoration: const InputDecoration(),
              items: [
                for (final c in desk.collections)
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
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Save'),
          ),
        ],
      ),
    ),
  );
  if (accepted == true) {
    desk.store.save('collection_requests', {
      for (final key in [
        'serverId',
        'serverName',
        'serverAddress',
        'serviceName',
        'methodName',
        'fullMethod',
        'requestJson',
        'requestMetadataJson',
      ])
        key: data[key],
      'collectionId': collection,
      'name': name.text,
    });
    desk.refresh();
  }
  name.dispose();
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
      'Version 1 · Servers, proto references, collections, and examples. History is excluded. Imports create new records.';
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
                if (file == null) return;
                if (await File(file.path).length() > 32 * 1024 * 1024) {
                  throw const FormatException('Workspace exceeds 32 MiB');
                }
                final counts = desk.store.importWorkspace(
                  jsonDecode(await file.readAsString()),
                );
                desk.refresh();
                setState(
                  () => message =
                      'Imported ${counts['serverCount']} servers, ${counts['collectionCount']} collections, ${counts['savedRequestCount']} examples.',
                );
              } catch (e) {
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
                if (location == null) return;
                await XFile.fromData(
                  utf8.encode(
                    '${pretty.convert(desk.store.exportWorkspace())}\n',
                  ),
                  mimeType: 'application/json',
                ).saveTo(location.path);
                if (!Platform.isWindows) {
                  await Process.run('chmod', ['600', location.path]);
                }
                setState(
                  () => message = 'Exported workspace to ${location.path}',
                );
              } catch (e) {
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

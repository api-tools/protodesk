import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'controller.dart';
import 'dialogs.dart';
import 'field_editor.dart';
import 'response_tree.dart';

class DeskWorkspace extends StatefulWidget {
  final DeskController desk;
  const DeskWorkspace({super.key, required this.desk});
  @override
  State<DeskWorkspace> createState() => _DeskWorkspaceState();
}

class _DeskWorkspaceState extends State<DeskWorkspace> {
  final request = TextEditingController(),
      timeout = TextEditingController(text: '5000'),
      authority = TextEditingController(),
      search = TextEditingController(),
      responseSearch = TextEditingController();
  double navigationWidth = 260, requestFraction = .5;
  bool jsonMode = false, treeMode = true;
  final collapsed = <String>{};
  DeskController get desk => widget.desk;
  @override
  void initState() {
    super.initState();
    desk.addListener(sync);
    sync();
  }

  void sync() {
    if (request.text != desk.body) request.text = desk.body;
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    desk.removeListener(sync);
    for (final c in [request, timeout, authority, search, responseSearch]) {
      c.dispose();
    }
    super.dispose();
  }

  Widget button(String text, IconData icon, VoidCallback action) =>
      TextButton.icon(
        onPressed: action,
        icon: Icon(icon, size: 17),
        label: Text(text),
      );
  Widget panel(Widget child) => Material(
    color: const Color(0xff171e26),
    shape: RoundedRectangleBorder(
      side: const BorderSide(color: Color(0xff303b47)),
      borderRadius: BorderRadius.circular(9),
    ),
    clipBehavior: Clip.antiAlias,
    child: child,
  );
  Widget title(String text, [Widget? trailing]) => Container(
    height: 52,
    padding: const EdgeInsets.symmetric(horizontal: 16),
    decoration: const BoxDecoration(
      border: Border(bottom: BorderSide(color: Color(0xff303b47))),
    ),
    child: Row(
      children: [
        Text(
          text,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
        const Spacer(),
        ?trailing,
      ],
    ),
  );
  Widget divider(String label, ValueChanged<double> drag) => Semantics(
    label: label,
    child: MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: (d) => drag(d.delta.dx),
        child: const SizedBox(
          width: 12,
          child: Center(
            child: Icon(Icons.more_vert, size: 13, color: Colors.grey),
          ),
        ),
      ),
    ),
  );
  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            child: Wrap(
              spacing: 12,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.hub_outlined,
                      color: Color(0xff55d6b0),
                      size: 25,
                    ),
                    SizedBox(width: 9),
                    Text(
                      'ProtoDesk',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
                SizedBox(
                  width: 290,
                  child: DropdownButtonFormField<String>(
                    isExpanded: true,
                    key: ValueKey(desk.server?['id']),
                    initialValue:
                        desk.servers.any((s) => s['id'] == desk.server?['id'])
                        ? (desk.server?['id'] as String?)
                        : null,
                    decoration: const InputDecoration(
                      isDense: true,
                      labelText: 'Server',
                    ),
                    items: [
                      for (final s in desk.servers)
                        DropdownMenuItem(
                          value: s['id'] as String,
                          child: Text(
                            '${s['name']} · ${s['address']}',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: desk.connecting
                        ? null
                        : (id) {
                            desk.selectServer(
                              desk.servers.firstWhere((s) => s['id'] == id),
                            );
                          },
                  ),
                ),
                FilledButton.icon(
                  onPressed: desk.connecting
                      ? null
                      : desk.connected
                      ? desk.disconnect
                      : desk.connect,
                  icon: Icon(
                    desk.connected ? Icons.link_off : Icons.bolt,
                    size: 18,
                  ),
                  label: Text(
                    desk.connecting
                        ? 'Connecting…'
                        : desk.connected
                        ? 'Disconnect'
                        : 'Connect',
                  ),
                ),
                button(
                  'Servers',
                  Icons.dns_outlined,
                  () => showServers(context, desk),
                ),
                button(
                  'Collections',
                  Icons.folder_outlined,
                  () => showCollections(context, desk),
                ),
                button(
                  'History',
                  Icons.history,
                  () => showHistory(context, desk),
                ),
                button(
                  'Workspace',
                  Icons.import_export,
                  () => showWorkspace(context, desk),
                ),
                IconButton(
                  tooltip: 'About ProtoDesk',
                  icon: const Icon(Icons.info_outline, size: 18),
                  onPressed: () => showAboutDialog(
                    context: context,
                    applicationName: 'ProtoDesk',
                    applicationVersion: '1.0.0',
                    applicationLegalese:
                        'MIT License · © 2026 ProtoDesk contributors',
                  ),
                ),
              ],
            ),
          ),
          if (desk.warning.isNotEmpty)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              padding: const EdgeInsets.all(10),
              color: const Color(0xff433623),
              child: SelectableText(
                desk.warning,
                style: const TextStyle(color: Color(0xffffd38a), fontSize: 12),
              ),
            ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, bounds) {
                final width = bounds.maxWidth - 32;
                final nav = min(navigationWidth, width * .3);
                final rest = max(200.0, width - nav - 24);
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(width: nav, child: navigation()),
                      divider(
                        'Resize service navigation',
                        (dx) => setState(
                          () => navigationWidth = (navigationWidth + dx).clamp(
                            180,
                            450,
                          ),
                        ),
                      ),
                      SizedBox(
                        width: rest * requestFraction,
                        child: requestPanel(),
                      ),
                      divider(
                        'Resize request and response panes',
                        (dx) => setState(
                          () => requestFraction = (requestFraction + dx / rest)
                              .clamp(.25, .75),
                        ),
                      ),
                      Expanded(child: responsePanel()),
                    ],
                  ),
                );
              },
            ),
          ),
          Container(
            height: 44,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                Icon(
                  desk.connected ? Icons.circle : Icons.circle_outlined,
                  size: 8,
                  color: desk.connected ? const Color(0xff55d6b0) : Colors.grey,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: SelectableText(
                    desk.status,
                    style: const TextStyle(fontSize: 12),
                    maxLines: 1,
                  ),
                ),
                Text(
                  '${desk.schema.services.length} services · ${desk.schema.methods.length} methods',
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
  Widget navigation() => panel(
    Column(
      children: [
        title('SERVICES'),
        Padding(
          padding: const EdgeInsets.all(12),
          child: TextField(
            controller: search,
            decoration: const InputDecoration(
              hintText: 'Filter services or methods',
              prefixIcon: Icon(Icons.search, size: 18),
              isDense: true,
            ),
            onChanged: (_) => setState(() {}),
          ),
        ),
        Expanded(
          child: desk.schema.services.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Text(
                      desk.connected
                          ? 'No services found. Enable reflection or configure proto sources in Servers.'
                          : 'Connect to a server to discover its APIs.',
                      style: const TextStyle(color: Colors.grey, fontSize: 13),
                    ),
                  ),
                )
              : ListView(
                  children: [
                    for (final service in desk.schema.services)
                      if (desk.schema.methods.values.any(
                        (m) =>
                            m.service == service &&
                            '${m.service} ${m.name}'.toLowerCase().contains(
                              search.text.toLowerCase(),
                            ),
                      )) ...[
                        ListTile(
                          dense: true,
                          title: Text(
                            service,
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          leading: Icon(
                            collapsed.contains(service)
                                ? Icons.chevron_right
                                : Icons.expand_more,
                            size: 18,
                          ),
                          onTap: () => setState(() {
                            if (!collapsed.add(service)) {
                              collapsed.remove(service);
                            }
                          }),
                        ),
                        if (!collapsed.contains(service))
                          for (final m in desk.schema.methods.values.where(
                            (m) =>
                                m.service == service &&
                                '${m.service} ${m.name}'.toLowerCase().contains(
                                  search.text.toLowerCase(),
                                ),
                          ))
                            ListTile(
                              dense: true,
                              contentPadding: const EdgeInsets.only(
                                left: 28,
                                right: 8,
                              ),
                              selected: desk.method?.path == m.path,
                              selectedTileColor: const Color(0xff254438),
                              leading: Icon(
                                m.serverStreaming
                                    ? Icons.waves
                                    : Icons.arrow_forward,
                                size: 16,
                                color: m.clientStreaming
                                    ? Colors.grey
                                    : const Color(0xff55d6b0),
                              ),
                              title: Text(
                                m.name,
                                style: const TextStyle(fontSize: 13),
                              ),
                              subtitle: m.clientStreaming
                                  ? const Text(
                                      'Unsupported streaming',
                                      style: TextStyle(fontSize: 10),
                                    )
                                  : m.serverStreaming
                                  ? const Text(
                                      'Server stream',
                                      style: TextStyle(fontSize: 10),
                                    )
                                  : null,
                              onTap: () => desk.selectMethod(m),
                            ),
                      ],
                  ],
                ),
        ),
      ],
    ),
  );
  Widget requestPanel() => panel(
    Column(
      children: [
        title(
          'REQUEST',
          Row(
            children: [
              IconButton(
                tooltip: 'Save example',
                onPressed: desk.method == null
                    ? null
                    : () => saveExample(context, desk),
                icon: const Icon(Icons.bookmark_add_outlined, size: 18),
              ),
              FilledButton(
                onPressed: desk.invoking
                    ? desk.cancel
                    : desk.connected &&
                          desk.method != null &&
                          !desk.method!.clientStreaming
                    ? desk.invoke
                    : null,
                child: Text(desk.invoking ? 'Cancel' : 'Invoke'),
              ),
            ],
          ),
        ),
        Expanded(
          child: desk.method == null
              ? const Center(
                  child: Text(
                    'Select a method',
                    style: TextStyle(color: Colors.grey),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    SelectableText(
                      desk.method!.path,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xff55d6b0),
                      ),
                    ),
                    const SizedBox(height: 16),
                    SegmentedButton<bool>(
                      segments: const [
                        ButtonSegment(
                          value: false,
                          label: Text('Form'),
                          icon: Icon(Icons.list_alt, size: 16),
                        ),
                        ButtonSegment(
                          value: true,
                          label: Text('JSON'),
                          icon: Icon(Icons.code, size: 16),
                        ),
                      ],
                      selected: {jsonMode},
                      onSelectionChanged: (value) {
                        if (!value.first &&
                            desk.validateBody(desk.body) != null) {
                          desk.status =
                              'Fix the JSON request before switching to Form';
                          desk.emit();
                          return;
                        }
                        setState(() => jsonMode = value.first);
                      },
                    ),
                    const SizedBox(height: 16),
                    if (jsonMode)
                      TextField(
                        controller: request,
                        minLines: 12,
                        maxLines: 24,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 13,
                        ),
                        decoration: InputDecoration(
                          labelText: 'Protobuf JSON',
                          alignLabelWithHint: true,
                          errorText: desk.validateBody(desk.body),
                        ),
                        onChanged: desk.setBody,
                      )
                    else
                      ...formFields(),
                    const SizedBox(height: 20),
                    ExpansionTile(
                      tilePadding: EdgeInsets.zero,
                      title: const Text(
                        'Metadata & call options',
                        style: TextStyle(fontSize: 13),
                      ),
                      children: [
                        MetadataEditor(
                          key: ValueKey(
                            '${desk.method?.path}-${desk.metadata}',
                          ),
                          text: desk.metadata,
                          onChanged: (v) {
                            desk.metadata = v;
                          },
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: timeout,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'Timeout (ms)',
                          ),
                          onChanged: (v) =>
                              desk.timeoutMs = int.tryParse(v) ?? 5000,
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: authority,
                          decoration: const InputDecoration(
                            labelText: 'Authority override (optional)',
                          ),
                          onChanged: (v) => desk.authority = v,
                        ),
                        const SizedBox(height: 12),
                      ],
                    ),
                  ],
                ),
        ),
      ],
    ),
  );
  List<Widget> formFields() {
    Object? parsed;
    try {
      parsed = jsonDecode(desk.body);
    } catch (_) {
      return [const Text('Invalid JSON. Switch to JSON to repair it.')];
    }
    final descriptor = desk.schema.messages[desk.method!.input]!;
    if (parsed is! Map || descriptor.name.startsWith('google.protobuf.')) {
      return [
        TextField(
          controller: request,
          minLines: 3,
          maxLines: 12,
          decoration: const InputDecoration(labelText: 'Protobuf JSON value'),
          onChanged: desk.setBody,
        ),
      ];
    }
    final body = Map<String, Object?>.from(parsed);
    return [
      if (descriptor.fields.isEmpty)
        const Text(
          'This request has no fields.',
          style: TextStyle(color: Colors.grey),
        ),
      for (final f in descriptor.fields)
        Padding(
          padding: const EdgeInsets.only(bottom: 15),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      f.jsonName,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Text(
                    '${f.repeated ? 'repeated ' : ''}${f.typeName.isEmpty ? typeLabel(f.type) : f.typeName.split('.').last}',
                    style: const TextStyle(fontSize: 11, color: Colors.grey),
                  ),
                  IconButton(
                    tooltip: 'Unset ${f.jsonName}',
                    visualDensity: VisualDensity.compact,
                    onPressed: () {
                      body.remove(f.jsonName);
                      body.remove(f.name);
                      desk.setBody(pretty.convert(body));
                    },
                    icon: const Icon(Icons.close, size: 14),
                  ),
                ],
              ),
              FieldEditor(
                key: ValueKey('${desk.method!.path}-${f.name}'),
                field: f,
                schema: desk.schema,
                value: body[f.jsonName] ?? body[f.name],
                ancestors: {descriptor.name},
                onChanged: (v) {
                  body.remove(f.name);
                  if (v == null) {
                    body.remove(f.jsonName);
                  } else {
                    if (f.oneof != null) {
                      for (final sibling in descriptor.fields.where(
                        (s) => s.oneof == f.oneof,
                      )) {
                        body.remove(sibling.jsonName);
                        body.remove(sibling.name);
                      }
                    }
                    body[f.jsonName] = v;
                  }
                  desk.setBody(pretty.convert(body));
                },
              ),
            ],
          ),
        ),
    ];
  }

  Widget responsePanel() => panel(
    Column(
      children: [
        title(
          'RESPONSE',
          IconButton(
            tooltip: 'Copy response JSON',
            onPressed: () =>
                Clipboard.setData(ClipboardData(text: desk.responseJson)),
            icon: const Icon(Icons.copy, size: 17),
          ),
        ),
        if (desk.invoking) const LinearProgressIndicator(minHeight: 2),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: responseSearch,
                  decoration: const InputDecoration(
                    hintText: 'Search response',
                    prefixIcon: Icon(Icons.search, size: 17),
                    isDense: true,
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              IconButton(
                tooltip: treeMode ? 'Show JSON' : 'Show tree',
                onPressed: () => setState(() => treeMode = !treeMode),
                icon: Icon(
                  treeMode ? Icons.code : Icons.account_tree_outlined,
                  size: 18,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: desk.messages.isEmpty
              ? Center(
                  child: Text(
                    desk.invoking
                        ? 'Waiting for response…'
                        : desk.result?.error ?? 'Responses appear here',
                    style: const TextStyle(color: Colors.grey),
                  ),
                )
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(8),
                  child: treeMode
                      ? ResponseTree(
                          value: desk.method?.serverStreaming == true
                              ? desk.messages
                              : desk.messages.first,
                          filter: responseSearch.text,
                        )
                      : SelectableText(
                          desk.responseJson,
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 12,
                          ),
                        ),
                ),
        ),
        if (desk.result != null)
          ExpansionTile(
            title: Text(
              '${desk.result!.code} · ${desk.result!.durationMs} ms · ${desk.messages.length} messages',
              style: const TextStyle(fontSize: 11),
            ),
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: SelectableText(
                  'Headers\n${pretty.convert(desk.result!.headers)}\n\nTrailers\n${pretty.convert(desk.result!.trailers)}',
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                ),
              ),
            ],
          ),
      ],
    ),
  );
}

class MetadataEditor extends StatefulWidget {
  final String text;
  final ValueChanged<String> onChanged;
  const MetadataEditor({
    super.key,
    required this.text,
    required this.onChanged,
  });
  @override
  State<MetadataEditor> createState() => _MetadataEditorState();
}

class _MetadataEditorState extends State<MetadataEditor> {
  final rows =
      <
        ({TextEditingController key, TextEditingController value, bool enabled})
      >[];
  late String lastSent;
  void send() {
    lastSent = jsonEncode({
      for (final row in rows)
        if (row.enabled &&
            row.key.text.trim().isNotEmpty &&
            row.value.text.trim().isNotEmpty)
          row.key.text: row.value.text,
    });
    widget.onChanged(lastSent);
  }

  @override
  void initState() {
    super.initState();
    lastSent = widget.text;
    try {
      for (final entry in DeskController.parseMetadata(widget.text).entries) {
        rows.add((
          key: TextEditingController(text: entry.key),
          value: TextEditingController(text: entry.value),
          enabled: true,
        ));
      }
    } catch (_) {}
  }

  @override
  void didUpdateWidget(covariant MetadataEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.text != lastSent) {
      for (final row in rows) {
        row.key.dispose();
        row.value.dispose();
      }
      rows.clear();
      lastSent = widget.text;
      for (final entry in DeskController.parseMetadata(widget.text).entries) {
        rows.add((
          key: TextEditingController(text: entry.key),
          value: TextEditingController(text: entry.value),
          enabled: true,
        ));
      }
    }
  }

  @override
  void dispose() {
    for (final row in rows) {
      row.key.dispose();
      row.value.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      for (var i = 0; i < rows.length; i++)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(
            children: [
              Checkbox(
                value: rows[i].enabled,
                onChanged: (v) {
                  setState(
                    () => rows[i] = (
                      key: rows[i].key,
                      value: rows[i].value,
                      enabled: v!,
                    ),
                  );
                  send();
                },
              ),
              Expanded(
                child: TextField(
                  controller: rows[i].key,
                  decoration: const InputDecoration(
                    hintText: 'Header key',
                    isDense: true,
                  ),
                  onChanged: (_) => send(),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: TextField(
                  controller: rows[i].value,
                  decoration: const InputDecoration(
                    hintText: 'Value',
                    isDense: true,
                  ),
                  onChanged: (_) => send(),
                ),
              ),
              IconButton(
                tooltip: 'Remove header',
                onPressed: () {
                  final row = rows.removeAt(i);
                  row.key.dispose();
                  row.value.dispose();
                  setState(() {});
                  send();
                },
                icon: const Icon(Icons.close, size: 16),
              ),
            ],
          ),
        ),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: () => setState(
            () => rows.add((
              key: TextEditingController(),
              value: TextEditingController(),
              enabled: true,
            )),
          ),
          icon: const Icon(Icons.add, size: 16),
          label: const Text('Add header'),
        ),
      ),
    ],
  );
}

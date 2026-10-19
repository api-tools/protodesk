import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'controller.dart';
import 'dialogs.dart';
import 'field_editor.dart';
import 'response_tree.dart';
import 'design.dart';
import 'call_status.dart';

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
  double? navigationWidth;
  double requestFraction = .5;
  bool jsonMode = false;
  final requestForm = GlobalKey<FormState>();
  bool validForm() {
    if (jsonMode || requestForm.currentState?.validate() != false) return true;
    desk.status = 'Fix invalid form fields before sending or switching to JSON';
    desk.emit();
    return false;
  }

  final responseTree = GlobalKey<ResponseTreeState>();
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
    height: DeskSpace.header,
    padding: const EdgeInsets.symmetric(horizontal: 16),
    decoration: const BoxDecoration(
      border: Border(bottom: BorderSide(color: Color(0xff303b47))),
    ),
    child: Row(
      children: [
        Expanded(
          child: Text(
            text,
            style: DeskType.heading,
            overflow: TextOverflow.ellipsis,
          ),
        ),
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
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: DeskSpace.panel,
              vertical: DeskSpace.inset,
            ),
            child: LayoutBuilder(
              builder: (context, bounds) {
                final connection = Row(
                  mainAxisSize: MainAxisSize.min,
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
                        Text('ProtoDesk', style: DeskType.title),
                      ],
                    ),
                    const SizedBox(width: DeskSpace.inset),
                    SizedBox(
                      width: bounds.maxWidth < 600 ? 160 : 260,
                      child: DeskDropdown<String>(
                        key: ValueKey(desk.server?['id']),
                        value:
                            desk.servers.any(
                              (s) => s['id'] == desk.server?['id'],
                            )
                            ? (desk.server?['id'] as String?)
                            : null,
                        decoration: const InputDecoration(
                          hintText: 'Select server',
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
                    const SizedBox(width: DeskSpace.gap),
                    FilledButton(
                      onPressed: desk.connecting
                          ? desk.cancelDiscovery
                          : desk.connected
                          ? desk.disconnect
                          : desk.connect,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            desk.connected ? Icons.link_off : Icons.bolt,
                            size: 18,
                          ),
                          const SizedBox(width: DeskSpace.gap),
                          Text(
                            desk.connecting
                                ? 'Cancel'
                                : desk.connected
                                ? 'Disconnect'
                                : 'Connect',
                          ),
                        ],
                      ),
                    ),
                  ],
                );
                final management = Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
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
                        applicationVersion: '1.0.4',
                        applicationLegalese:
                            'MIT License · © 2026 ProtoDesk contributors',
                      ),
                    ),
                  ],
                );
                if (bounds.maxWidth < 1120) {
                  return Column(
                    children: [
                      Align(alignment: Alignment.centerLeft, child: connection),
                      const SizedBox(height: DeskSpace.small),
                      Align(
                        alignment: Alignment.centerRight,
                        child: management,
                      ),
                    ],
                  );
                }
                return Row(children: [connection, const Spacer(), management]);
              },
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
                style: DeskType.secondary.copyWith(
                  color: const Color(0xffffd38a),
                ),
              ),
            ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, bounds) {
                final width = bounds.maxWidth - 32;
                final usable = width - 24;
                final nav = (navigationWidth ?? usable / 3)
                    .clamp(
                      min(180.0, usable / 3),
                      max(usable / 3, usable - 2 * DeskSpace.minimumPane),
                    )
                    .toDouble();
                final rest = max(200.0, width - nav - 24);
                final minimum = min(.5, DeskSpace.minimumPane / rest);
                final maximum = max(.5, 1 - DeskSpace.minimumPane / rest);
                final fraction = requestFraction.clamp(minimum, maximum);
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(
                        key: const ValueKey('services-pane'),
                        width: nav,
                        child: navigation(),
                      ),
                      divider(
                        'Resize service navigation',
                        (dx) => setState(
                          () => navigationWidth = (nav + dx).clamp(
                            min(180.0, usable / 3),
                            max(usable / 3, usable - 2 * DeskSpace.minimumPane),
                          ),
                        ),
                      ),
                      SizedBox(
                        key: const ValueKey('request-pane'),
                        width: rest * fraction,
                        child: requestPanel(),
                      ),
                      divider(
                        'Resize request and response panes',
                        (dx) => setState(
                          () => requestFraction = (fraction + dx / rest).clamp(
                            minimum,
                            maximum,
                          ),
                        ),
                      ),
                      Expanded(
                        child: SizedBox(
                          key: const ValueKey('response-pane'),
                          child: responsePanel(),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          CallStatusBar(
            desk: desk,
            onMetadata: () => showResponseMetadata(context, desk.result),
          ),
        ],
      ),
    ),
  );
  Widget navigation() => panel(
    Column(
      children: [
        title('SERVICES'),
        TextButton.icon(
          onPressed: desk.server == null || desk.connecting
              ? null
              : desk.browseSources,
          icon: const Icon(Icons.schema_outlined, size: 16),
          label: const Text('Browse proto sources'),
        ),
        Padding(
          padding: const EdgeInsets.all(DeskSpace.inset),
          child: TextField(
            controller: search,
            decoration: const InputDecoration(
              hintText: 'Filter services or methods',
              prefixIcon: Icon(Icons.search, size: 18),
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
                          : desk.servers.isEmpty
                          ? 'Add a server in Servers to discover its APIs.'
                          : 'Connect or browse configured proto sources offline.',
                      style: DeskType.body.copyWith(color: Colors.grey),
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
                        _navigationRow(
                          service,
                          service: true,
                          expanded: !collapsed.contains(service),
                          action: () => setState(() {
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
                            _navigationRow(
                              m.name,
                              selected: desk.method?.path == m.path,
                              action: () => desk.selectMethod(m),
                            ),
                      ],
                  ],
                ),
        ),
      ],
    ),
  );
  Widget _navigationRow(
    String text, {
    bool service = false,
    bool expanded = false,
    bool selected = false,
    required VoidCallback action,
  }) => Tooltip(
    message: text,
    child: InkWell(
      onTap: action,
      child: Ink(
        color: selected ? const Color(0xff254438) : Colors.transparent,
        child: SizedBox(
          height: DeskSpace.row,
          child: Padding(
            padding: EdgeInsets.only(
              left: service ? DeskSpace.inset : DeskSpace.inset + 24,
              right: DeskSpace.inset,
            ),
            child: Row(
              children: [
                if (service) ...[
                  Icon(
                    expanded
                        ? Icons.keyboard_arrow_down
                        : Icons.keyboard_arrow_right,
                    size: 16,
                  ),
                  const SizedBox(width: DeskSpace.gap),
                ],
                Expanded(
                  child: Text(
                    text,
                    style: service ? DeskType.heading : DeskType.body,
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
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
                    : desk.connected && desk.method != null
                    ? () {
                        if (validForm()) desk.invoke();
                      }
                    : null,
                child: Text(
                  desk.invoking
                      ? 'Cancel'
                      : desk.method?.clientStreaming == true
                      ? 'Start'
                      : 'Invoke',
                ),
              ),
            ],
          ),
        ),
        if (desk.method?.clientStreaming == true) requestStreamControls(),
        Expanded(
          child: desk.method == null
              ? const Center(
                  child: Text(
                    'Select a method',
                    style: TextStyle(color: Colors.grey),
                  ),
                )
              : Form(
                  key: requestForm,
                  child: ListView(
                    padding: const EdgeInsets.all(DeskSpace.panel),
                    children: [
                      SelectableText(
                        desk.method!.path,
                        style: DeskType.code.copyWith(
                          color: const Color(0xff55d6b0),
                        ),
                      ),
                      const SizedBox(height: DeskSpace.panel),
                      if (jsonMode)
                        TextField(
                          controller: request,
                          minLines: 12,
                          maxLines: 24,
                          style: DeskType.code,
                          decoration: InputDecoration(
                            labelText: 'Protobuf JSON',
                            contentPadding: const EdgeInsets.all(
                              DeskSpace.inset,
                            ),
                            alignLabelWithHint: true,
                            errorText: desk.validateBody(desk.body),
                          ),
                          onChanged: desk.setBody,
                        )
                      else
                        ...formFields(),
                      const SizedBox(height: 20),
                      ExpansionTile(
                        minTileHeight: DeskSpace.control,
                        dense: true,
                        tilePadding: EdgeInsets.zero,
                        title: const Text(
                          'Metadata & call options',
                          style: DeskType.label,
                        ),
                        children: [
                          MetadataEditor(
                            key: ValueKey(desk.method?.path),
                            text: desk.metadata,
                            onChanged: (v) {
                              desk.metadata = v;
                            },
                          ),
                          const SizedBox(height: DeskSpace.inset),
                          TextField(
                            controller: timeout,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: 'Timeout (ms)',
                            ),
                            onChanged: (v) =>
                                desk.timeoutMs = int.tryParse(v) ?? 5000,
                          ),
                          const SizedBox(height: DeskSpace.inset),
                          TextField(
                            controller: authority,
                            decoration: const InputDecoration(
                              labelText: 'Authority override (optional)',
                            ),
                            onChanged: (v) => desk.authority = v,
                          ),
                          const SizedBox(height: DeskSpace.inset),
                        ],
                      ),
                    ],
                  ),
                ),
        ),
        if (desk.method != null)
          Container(
            key: const ValueKey('request-mode-bar'),
            height: DeskSpace.modeFooter,
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: DeskSpace.gap),
            decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: Color(0xff303b47))),
            ),
            child: Align(
              alignment: Alignment.centerRight,
              child: DeskModeSwitch(
                json: jsonMode,
                onChanged: (value) {
                  if (!jsonMode && value && !validForm()) return;
                  if (!value && desk.validateBody(desk.body) != null) {
                    desk.status =
                        'Fix the JSON request before switching to Form';
                    desk.emit();
                    return;
                  }
                  setState(() => jsonMode = value);
                },
              ),
            ),
          ),
      ],
    ),
  );
  Widget requestStreamControls() => Container(
    key: const ValueKey('request-stream-controls'),
    padding: const EdgeInsets.symmetric(
      horizontal: DeskSpace.inset,
      vertical: DeskSpace.small,
    ),
    decoration: const BoxDecoration(
      border: Border(bottom: BorderSide(color: Color(0xff303b47))),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                desk.invoking
                    ? '${desk.sentRequests.length} sent · ${desk.sendingFinished ? 'send side closed' : 'send side open'}'
                    : '${desk.queuedRequests.length} messages queued',
                style: DeskType.secondary,
              ),
            ),
            IconButton(
              tooltip: 'Review send queue',
              onPressed: desk.invoking
                  ? null
                  : () => showDialog<void>(
                      context: context,
                      builder: (context) => AnimatedBuilder(
                        animation: desk,
                        builder: (context, _) => AlertDialog(
                          title: const Text('Request send queue'),
                          content: SizedBox(
                            width: 540,
                            height: 300,
                            child: desk.queuedRequests.isEmpty
                                ? const Center(
                                    child: Text(
                                      'No messages queued. Compose a message and choose Queue message.',
                                    ),
                                  )
                                : ListView.builder(
                                    itemCount: desk.queuedRequests.length,
                                    itemBuilder: (context, index) => Row(
                                      children: [
                                        Expanded(
                                          child: Tooltip(
                                            message: pretty.convert(
                                              desk.queuedRequests[index],
                                            ),
                                            child: Text(
                                              '${index + 1}. ${jsonEncode(desk.queuedRequests[index])}',
                                              style: DeskType.code,
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                        ),
                                        IconButton(
                                          tooltip:
                                              'Load queued message ${index + 1}',
                                          onPressed: desk.invoking
                                              ? null
                                              : () {
                                                  desk.setBody(
                                                    pretty.convert(
                                                      desk.queuedRequests[index],
                                                    ),
                                                  );
                                                  Navigator.pop(context);
                                                },
                                          icon: const Icon(Icons.edit_outlined),
                                        ),
                                        IconButton(
                                          tooltip:
                                              'Remove queued message ${index + 1}',
                                          onPressed: desk.invoking
                                              ? null
                                              : () => desk.removeQueuedRequest(
                                                  index,
                                                ),
                                          icon: const Icon(Icons.close),
                                        ),
                                      ],
                                    ),
                                  ),
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(context),
                              child: const Text('Close'),
                            ),
                          ],
                        ),
                      ),
                    ),
              icon: const Icon(Icons.playlist_play),
            ),
          ],
        ),
        Wrap(
          spacing: DeskSpace.gap,
          runSpacing: DeskSpace.small,
          children: [
            TextButton(
              onPressed: desk.invoking
                  ? (desk.canSend
                        ? () {
                            if (validForm()) desk.sendDraft();
                          }
                        : null)
                  : () {
                      if (validForm()) desk.queueDraft();
                    },
              child: Text(desk.invoking ? 'Send message' : 'Queue message'),
            ),
            if (desk.invoking)
              OutlinedButton(
                onPressed: desk.canSend ? desk.finishSending : null,
                child: const Text('Finish sending'),
              ),
          ],
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
          style: DeskType.code,
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
          padding: const EdgeInsets.only(bottom: DeskSpace.inset),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              FieldHeading(
                field: f,
                action: IconButton(
                  tooltip: 'Unset ${f.jsonName}',
                  visualDensity: VisualDensity.compact,
                  onPressed: () {
                    body.remove(f.jsonName);
                    body.remove(f.name);
                    desk.setBody(pretty.convert(body));
                  },
                  icon: const Icon(Icons.close, size: 14),
                ),
              ),
              const SizedBox(height: DeskSpace.small),
              FieldEditor(
                key: ValueKey('${desk.method!.path}-${f.name}'),
                field: f,
                schema: desk.schema,
                value: body.containsKey(f.jsonName)
                    ? body[f.jsonName]
                    : body[f.name],
                present:
                    body.containsKey(f.jsonName) || body.containsKey(f.name),
                ancestors: {descriptor.name},
                onChanged: (v) {
                  body.remove(f.name);
                  if (identical(v, unsetFieldValue) ||
                      (v == null && f.typeName != 'google.protobuf.Value')) {
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

  Widget responseControls() => Padding(
    padding: const EdgeInsets.all(DeskSpace.inset),
    child: LayoutBuilder(
      builder: (context, bounds) {
        final search = TextField(
          controller: responseSearch,
          decoration: InputDecoration(
            hintText: 'Search JSON',
            prefixIcon: const Icon(Icons.search, size: 16),
            suffixIcon: responseSearch.text.isEmpty
                ? null
                : IconButton(
                    tooltip: 'Clear JSON search',
                    icon: const Icon(Icons.close, size: 16),
                    onPressed: () => setState(responseSearch.clear),
                  ),
          ),
          onChanged: (_) => setState(() {}),
        );
        final actions = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: 'Expand all',
              onPressed: () => responseTree.currentState?.expandAll(),
              icon: const Icon(Icons.unfold_more, size: 16),
            ),
            IconButton(
              tooltip: 'Collapse all',
              onPressed: () => responseTree.currentState?.collapseAll(),
              icon: const Icon(Icons.unfold_less, size: 16),
            ),
          ],
        );
        if (bounds.maxWidth < 300) {
          return Column(
            children: [
              search,
              const SizedBox(height: DeskSpace.small),
              Align(alignment: Alignment.centerRight, child: actions),
            ],
          );
        }
        return Row(
          children: [
            Expanded(child: search),
            actions,
          ],
        );
      },
    ),
  );

  Widget responsePanel() => panel(
    Column(
      children: [
        title(
          'RESPONSE',
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: 'Response headers and trailers',
                onPressed: () => showResponseMetadata(context, desk.result),
                icon: const Icon(Icons.info_outline, size: 16),
              ),
              IconButton(
                tooltip: 'Copy response JSON',
                onPressed: () =>
                    Clipboard.setData(ClipboardData(text: desk.responseJson)),
                icon: const Icon(Icons.copy, size: 16),
              ),
            ],
          ),
        ),
        responseControls(),
        Expanded(
          child: desk.messages.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(DeskSpace.inset),
                    child: Text(
                      desk.invoking
                          ? 'Waiting for response…'
                          : (desk.result?.error.isNotEmpty == true
                                ? desk.result!.error
                                : 'Responses appear here'),
                      style: DeskType.secondary,
                    ),
                  ),
                )
              : ResponseTree(
                  key: responseTree,
                  value: desk.method?.serverStreaming == true
                      ? List<Object?>.of(desk.messages)
                      : desk.messages.first,
                  responseId: desk.responseRevision,
                  filter: responseSearch.text,
                ),
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

  Widget removeHeader(int i) => IconButton(
    tooltip: 'Remove header',
    onPressed: () {
      final row = rows.removeAt(i);
      row.key.dispose();
      row.value.dispose();
      setState(() {});
      send();
    },
    icon: const Icon(Icons.close, size: 16),
  );
  Widget enabledHeader(int i) => Checkbox(
    value: rows[i].enabled,
    onChanged: (v) {
      setState(
        () => rows[i] = (key: rows[i].key, value: rows[i].value, enabled: v!),
      );
      send();
    },
  );
  @override
  Widget build(BuildContext context) => Column(
    children: [
      for (var i = 0; i < rows.length; i++)
        Padding(
          padding: const EdgeInsets.only(bottom: DeskSpace.gap),
          child: LayoutBuilder(
            builder: (context, bounds) {
              final key = TextField(
                key: ValueKey('metadata-key:$i'),
                controller: rows[i].key,
                decoration: const InputDecoration(hintText: 'Header key'),
                onChanged: (_) => send(),
              );
              final value = TextField(
                key: ValueKey('metadata-value:$i'),
                controller: rows[i].value,
                decoration: const InputDecoration(hintText: 'Value'),
                onChanged: (_) => send(),
              );
              if (bounds.maxWidth < 400) {
                return Column(
                  children: [
                    Row(
                      children: [
                        enabledHeader(i),
                        Expanded(child: key),
                        removeHeader(i),
                      ],
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        DeskSpace.control,
                        DeskSpace.small,
                        DeskSpace.control,
                        0,
                      ),
                      child: value,
                    ),
                  ],
                );
              }
              return Row(
                children: [
                  enabledHeader(i),
                  Expanded(child: key),
                  const SizedBox(width: DeskSpace.gap),
                  Expanded(child: value),
                  removeHeader(i),
                ],
              );
            },
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

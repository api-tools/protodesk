import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import '../persistence/store.dart';
import '../workflow/storage.dart';
import 'controller.dart';
import 'design.dart';
import 'dialogs.dart' show previewRequest, saveExample;

Future<void> showHistoryBrowser(BuildContext context, DeskController desk) =>
    showDialog<void>(context: context, builder: (_) => _History(desk));

class _History extends StatefulWidget {
  final DeskController desk;
  const _History(this.desk);
  @override
  State<_History> createState() => _HistoryState();
}

class _HistoryState extends State<_History> {
  final search = TextEditingController(),
      from = TextEditingController(),
      until = TextEditingController();
  String serverId = '', status = '', error = '';
  int offset = 0;
  HistoryPage page = HistoryPage([], false);
  @override
  void initState() {
    super.initState();
    widget.desk.addListener(onDeskChanged);
    refresh();
  }

  @override
  void dispose() {
    widget.desk.removeListener(onDeskChanged);
    search.dispose();
    from.dispose();
    until.dispose();
    super.dispose();
  }

  Object? previousHistory;
  void onDeskChanged() {
    if (identical(previousHistory, widget.desk.history)) return;
    previousHistory = widget.desk.history;
    refresh();
  }

  void refresh() {
    if (!mounted) return;
    try {
      DateTime? date(String text) {
        if (text.trim().isEmpty) return null;
        if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(text)) {
          throw const FormatException('Dates must use YYYY-MM-DD in UTC');
        }
        final value = DateTime.tryParse('${text}T00:00:00Z');
        if (value == null || value.toIso8601String().substring(0, 10) != text) {
          throw const FormatException('Invalid date');
        }
        return value;
      }

      final start = date(from.text),
          end = date(until.text)?.add(const Duration(days: 1));
      if (start != null && end != null && !start.isBefore(end)) {
        throw const FormatException('From date must not follow the until date');
      }
      final filter = HistoryFilter(
        text: search.text,
        serverId: serverId,
        status: status,
        from: start,
        until: end,
      );
      page = queryHistory(widget.desk.store, filter: filter, offset: offset);
      if (page.rows.isEmpty && offset > 0) {
        offset = max(0, offset - 50);
        page = queryHistory(widget.desk.store, filter: filter, offset: offset);
      }
      error = '';
    } catch (e) {
      error = e.toString();
      page = HistoryPage([], false);
    }
    setState(() {});
  }

  void changed() {
    offset = 0;
    refresh();
  }

  Future<void> useRecord(
    Record item,
    FutureOr<void> Function(Record) action,
  ) async {
    try {
      await action(item is HistoryRecord ? item.full() : item);
    } catch (_) {
      if (mounted) {
        refresh();
        setState(
          () => error =
              'History item is no longer available. Refresh filters and retry.',
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Invocation history'),
    content: SizedBox(
      width: min(850, MediaQuery.sizeOf(context).width - 96),
      height: min(500, MediaQuery.sizeOf(context).height - 190),
      child: Column(
        children: [
          TextField(
            controller: search,
            decoration: const InputDecoration(
              labelText: 'Search server or method',
            ),
            onChanged: (_) => changed(),
          ),
          const SizedBox(height: DeskSpace.small),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              SizedBox(
                width: 180,
                child: DeskDropdown<String>(
                  value: serverId,
                  items: [
                    const DropdownMenuItem(
                      value: '',
                      child: Text('All servers'),
                    ),
                    for (final server in widget.desk.servers)
                      DropdownMenuItem(
                        value: server['id'] as String,
                        child: Text(
                          server['name'] as String,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (value) {
                    serverId = value!;
                    changed();
                  },
                ),
              ),
              SizedBox(
                width: 180,
                child: DeskDropdown<String>(
                  value: status,
                  items: [
                    for (final code in [
                      '',
                      'OK',
                      'CANCELLED',
                      'UNKNOWN',
                      'INVALID_ARGUMENT',
                      'DEADLINE_EXCEEDED',
                      'NOT_FOUND',
                      'ALREADY_EXISTS',
                      'PERMISSION_DENIED',
                      'RESOURCE_EXHAUSTED',
                      'FAILED_PRECONDITION',
                      'ABORTED',
                      'OUT_OF_RANGE',
                      'UNIMPLEMENTED',
                      'INTERNAL',
                      'UNAVAILABLE',
                      'DATA_LOSS',
                      'UNAUTHENTICATED',
                    ])
                      DropdownMenuItem(
                        value: code,
                        child: Text(
                          code.isEmpty ? 'All statuses' : code,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (value) {
                    status = value!;
                    changed();
                  },
                ),
              ),
              SizedBox(
                width: 180,
                child: TextField(
                  controller: from,
                  decoration: const InputDecoration(
                    labelText: 'From (UTC)',
                    hintText: 'YYYY-MM-DD',
                  ),
                  onSubmitted: (_) => changed(),
                ),
              ),
              SizedBox(
                width: 180,
                child: TextField(
                  controller: until,
                  decoration: const InputDecoration(
                    labelText: 'Until (UTC)',
                    hintText: 'YYYY-MM-DD',
                  ),
                  onSubmitted: (_) => changed(),
                ),
              ),
              TextButton(onPressed: changed, child: const Text('Apply dates')),
            ],
          ),
          if (error.isNotEmpty) Text(error, style: DeskType.secondary),
          const SizedBox(height: DeskSpace.small),
          Expanded(
            child: page.rows.isEmpty
                ? Center(
                    child: Text(
                      search.text.isEmpty &&
                              serverId.isEmpty &&
                              status.isEmpty &&
                              from.text.isEmpty &&
                              until.text.isEmpty
                          ? 'Completed calls appear here. History stays on this computer.'
                          : 'No matching calls. History stays on this computer.',
                      style: DeskType.secondary,
                    ),
                  )
                : ListView.builder(
                    itemCount: page.rows.length,
                    itemBuilder: (context, index) {
                      final item = page.rows[index];
                      return ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                          '${item['methodName']} · ${item['statusCode']} · ${item['durationMs']} ms',
                          style: DeskType.body,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          '${item['serverAddress']} · ${item['createdAt']}',
                          style: DeskType.secondary,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onTap: () => useRecord(
                          item,
                          (record) => previewRequest(
                            context,
                            widget.desk,
                            record,
                            true,
                          ),
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              tooltip: 'Reuse request',
                              icon: const Icon(Icons.replay, size: 16),
                              onPressed: () => useRecord(item, (record) {
                                widget.desk.loadRequest(record);
                                Navigator.pop(context);
                              }),
                            ),
                            IconButton(
                              tooltip: 'Save to collection',
                              icon: const Icon(
                                Icons.bookmark_add_outlined,
                                size: 16,
                              ),
                              onPressed: () => useRecord(
                                item,
                                (record) =>
                                    saveExample(context, widget.desk, record),
                              ),
                            ),
                            IconButton(
                              tooltip: 'Delete history item',
                              icon: const Icon(Icons.delete_outline, size: 16),
                              onPressed: () {
                                widget.desk.store.delete(
                                  'history_items',
                                  item['id'] as String,
                                );
                                widget.desk.refresh();
                              },
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
          Row(
            children: [
              Text(
                'Page ${offset ~/ 50 + 1} · ${page.rows.length} calls',
                style: DeskType.secondary,
              ),
              const Spacer(),
              IconButton(
                tooltip: 'Previous page',
                onPressed: offset == 0
                    ? null
                    : () {
                        offset = max(0, offset - 50);
                        refresh();
                      },
                icon: const Icon(Icons.chevron_left),
              ),
              IconButton(
                tooltip: 'Next page',
                onPressed: page.hasNext
                    ? () {
                        offset += 50;
                        refresh();
                      }
                    : null,
                icon: const Icon(Icons.chevron_right),
              ),
            ],
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () {
          widget.desk.store.clearHistory();
          widget.desk.refresh();
        },
        child: const Text('Clear history'),
      ),
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Close'),
      ),
    ],
  );
}

import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';

import 'design.dart';

class JsonNode {
  final String path, prefix, literal;
  final int depth;
  final bool comma, object;
  final Object? value;
  final List<JsonNode> children;
  JsonNode(
    this.path,
    this.prefix,
    this.literal,
    this.depth,
    this.comma,
    this.object,
    this.value,
    this.children,
  );
  bool get container => value is Map || value is List;
  String get open => object ? '{' : '[';
  String get close => object ? '}' : ']';
}

class JsonRow {
  final JsonNode node;
  final bool closing, expanded;
  JsonRow(this.node, {this.closing = false, this.expanded = false});
  String get text {
    final n = node;
    final comma = n.comma ? ',' : '';
    if (closing) return '${n.close}$comma';
    if (!n.container) return '${n.prefix}${n.literal}$comma';
    if (n.children.isEmpty) return '${n.prefix}${n.open}${n.close}$comma';
    return expanded
        ? '${n.prefix}${n.open}'
        : '${n.prefix}${n.open} … ${n.close}$comma';
  }
}

/// JSON-pointer identities avoid collisions between equal keys at different depths.
/// Search expansion never mutates the user's normal expansion set.
class JsonTreeModel {
  late JsonNode root;
  final expanded = <String>{};
  final _searchCollapsed = <String>{};
  final _visible = <String>{};
  String query = '';
  int matches = 0, maxDepth = 0;
  Object? _responseId;
  bool _initialized = false;
  int _autoDepth = 2;
  Set<String> _paths = {};
  void update(Object? value, {Object? responseId}) {
    final id = responseId ?? value;
    final reset = !_initialized || id != _responseId;
    _initialized = true;
    _responseId = id;
    maxDepth = 0;
    JsonNode build(
      Object? v,
      String path,
      String prefix,
      int depth,
      bool comma,
    ) {
      maxDepth = max(maxDepth, depth);
      final entries = v is Map
          ? v.entries.map((e) => MapEntry(e.key.toString(), e.value)).toList()
          : v is List
          ? v
                .asMap()
                .entries
                .map((e) => MapEntry(e.key.toString(), e.value))
                .toList()
          : <MapEntry<String, Object?>>[];
      final children = <JsonNode>[];
      for (var i = 0; i < entries.length; i++) {
        final e = entries[i];
        final token = e.key.replaceAll('~', '~0').replaceAll('/', '~1');
        children.add(
          build(
            e.value,
            '$path/$token',
            v is Map ? '${jsonEncode(e.key)}: ' : '',
            depth + 1,
            i < entries.length - 1,
          ),
        );
      }
      return JsonNode(
        path,
        prefix,
        v is Map || v is List ? '' : jsonEncode(v),
        depth,
        comma,
        v is Map,
        v,
        children,
      );
    }

    root = build(value, '', '', 0, false);
    final paths = <String>{}, containers = <String>{};
    if (reset) {
      expanded.clear();
      _searchCollapsed.clear();
      _autoDepth = 2;
    }
    void defaults(JsonNode n) {
      paths.add(n.path);
      if (n.container) {
        containers.add(n.path);
        if ((reset || !_paths.contains(n.path)) && n.depth < _autoDepth) {
          expanded.add(n.path);
        }
      }
      for (final child in n.children) {
        defaults(child);
      }
    }

    defaults(root);
    expanded.retainAll(containers);
    _searchCollapsed.retainAll(containers);
    _paths = paths;
    _indexSearch();
  }

  void search(String text) {
    if (query == text) return;
    query = text;
    _searchCollapsed.clear();
    _indexSearch();
  }

  void _indexSearch() {
    _visible.clear();
    matches = 0;
    if (query.isEmpty) return;
    final needle = query.toLowerCase();
    bool visit(JsonNode n, bool inherited) {
      final text = '${n.prefix}${n.literal}'.toLowerCase();
      var offset = 0, found = false;
      while ((offset = text.indexOf(needle, offset)) >= 0) {
        matches++;
        found = true;
        offset += needle.length;
      }
      var visible = inherited || found;
      for (final child in n.children) {
        visible = visit(child, inherited || found) || visible;
      }
      if (visible) _visible.add(n.path);
      return visible;
    }

    visit(root, false);
  }

  bool isExpanded(JsonNode n) => query.isEmpty
      ? expanded.contains(n.path)
      : !_searchCollapsed.contains(n.path);
  void toggle(String path) {
    final set = query.isEmpty ? expanded : _searchCollapsed;
    if (!set.add(path)) set.remove(path);
  }

  void expandAll() {
    if (query.isNotEmpty) {
      _searchCollapsed.clear();
      return;
    }
    _autoDepth = 100;
    void visit(JsonNode n) {
      if (n.container) expanded.add(n.path);
      for (final child in n.children) {
        visit(child);
      }
    }

    visit(root);
  }

  void collapseAll() {
    if (query.isEmpty) {
      _autoDepth = 0;
      expanded.clear();
    } else {
      void visit(JsonNode n) {
        if (n.container) _searchCollapsed.add(n.path);
        for (final child in n.children) {
          visit(child);
        }
      }

      visit(root);
    }
  }

  List<JsonRow> get rows {
    final result = <JsonRow>[];
    void visit(JsonNode n) {
      if (query.isNotEmpty && !_visible.contains(n.path)) return;
      final open = n.container && n.children.isNotEmpty && isExpanded(n);
      result.add(JsonRow(n, expanded: open));
      if (open) {
        for (final child in n.children) {
          visit(child);
        }
        result.add(JsonRow(n, closing: true));
      }
    }

    visit(root);
    return result;
  }
}

class ResponseTree extends StatefulWidget {
  final Object? value, responseId;
  final String filter;
  const ResponseTree({
    super.key,
    required this.value,
    this.responseId,
    this.filter = '',
  });
  @override
  State<ResponseTree> createState() => ResponseTreeState();
}

class ResponseTreeState extends State<ResponseTree> {
  final model = JsonTreeModel();
  final vertical = ScrollController(), horizontal = ScrollController();
  @override
  void initState() {
    super.initState();
    _update();
  }

  void _update() {
    model.update(widget.value, responseId: widget.responseId);
    model.search(widget.filter);
  }

  @override
  void didUpdateWidget(covariant ResponseTree oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.responseId != widget.responseId ||
        !identical(oldWidget.value, widget.value)) {
      model.update(widget.value, responseId: widget.responseId);
    }
    model.search(widget.filter);
    if (oldWidget.responseId != widget.responseId) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (vertical.hasClients) vertical.jumpTo(0);
        if (horizontal.hasClients) horizontal.jumpTo(0);
      });
    }
  }

  void expandAll() => setState(model.expandAll);
  void collapseAll() => setState(model.collapseAll);
  @override
  void dispose() {
    vertical.dispose();
    horizontal.dispose();
    super.dispose();
  }

  TextSpan highlight(String text, Color color) {
    final spans = <TextSpan>[];
    final query = widget.filter.toLowerCase();
    var from = 0;
    if (query.isNotEmpty) {
      final lower = text.toLowerCase();
      var at = lower.indexOf(query);
      while (at >= 0) {
        if (at > from) spans.add(TextSpan(text: text.substring(from, at)));
        spans.add(
          TextSpan(
            text: text.substring(at, at + query.length),
            style: const TextStyle(
              backgroundColor: Color(0xff755c22),
              color: Color(0xffffe29a),
            ),
          ),
        );
        from = at + query.length;
        at = lower.indexOf(query, from);
      }
    }
    spans.add(TextSpan(text: text.substring(from)));
    return TextSpan(
      style: DeskType.code.copyWith(color: color),
      children: spans,
    );
  }

  @override
  Widget build(BuildContext context) {
    final rows = model.rows;
    if (rows.isEmpty) {
      return const Center(child: Text('No matches', style: DeskType.secondary));
    }
    return LayoutBuilder(
      builder: (context, bounds) {
        final width = max(
          bounds.maxWidth,
          model.maxDepth * DeskSpace.indent + 240,
        );
        return Scrollbar(
          controller: horizontal,
          notificationPredicate: (n) => n.metrics.axis == Axis.horizontal,
          child: SingleChildScrollView(
            controller: horizontal,
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: width,
              height: bounds.maxHeight,
              child: Scrollbar(
                controller: vertical,
                child: SelectionArea(
                  child: ListView.builder(
                    controller: vertical,
                    padding: const EdgeInsets.all(DeskSpace.gap),
                    itemCount: rows.length,
                    itemBuilder: (context, i) {
                      final row = rows[i], n = row.node;
                      final disclosure =
                          !row.closing && n.container && n.children.isNotEmpty;
                      final color = n.value is String && !n.container
                          ? const Color(0xff9dd5b3)
                          : const Color(0xffced9e5);
                      return ConstrainedBox(
                        key: row.closing
                            ? ValueKey(('json-close', n.path))
                            : ValueKey('json-row:${n.path}'),
                        constraints: const BoxConstraints(
                          minHeight: DeskSpace.jsonRow,
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 1),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SizedBox(width: n.depth * DeskSpace.indent),
                              SizedBox(
                                width: 18,
                                height: 18,
                                child: disclosure
                                    ? Tooltip(
                                        message:
                                            '${row.expanded ? 'Collapse' : 'Expand'} ${n.path.isEmpty ? 'response' : n.path}',
                                        child: Semantics(
                                          button: true,
                                          expanded: row.expanded,
                                          child: InkResponse(
                                            onTap: () => setState(
                                              () => model.toggle(n.path),
                                            ),
                                            child: Icon(
                                              row.expanded
                                                  ? Icons.keyboard_arrow_down
                                                  : Icons.keyboard_arrow_right,
                                              size: 16,
                                            ),
                                          ),
                                        ),
                                      )
                                    : null,
                              ),
                              Expanded(
                                child: Text.rich(highlight(row.text, color)),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

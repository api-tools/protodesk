import 'package:flutter/material.dart';

import 'controller.dart';

class ResponseTree extends StatelessWidget {
  final Object? value;
  final String label, filter;
  final int depth;
  const ResponseTree({
    super.key,
    required this.value,
    this.label = 'response',
    this.filter = '',
    this.depth = 0,
  });
  bool get matches =>
      filter.isEmpty ||
      '$label ${pretty.convert(value)}'.toLowerCase().contains(
        filter.toLowerCase(),
      );
  @override
  Widget build(BuildContext context) {
    if (!matches) return const SizedBox.shrink();
    if (value is Map || value is List) {
      final entries = value is Map
          ? (value as Map).entries
                .map((e) => MapEntry(e.key.toString(), e.value))
                .toList()
          : (value as List)
                .asMap()
                .entries
                .map((e) => MapEntry('[${e.key}]', e.value))
                .toList();
      if (depth >= 32) {
        return SelectableText(
          '$label: ${pretty.convert(value)}',
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
        );
      }
      return ExpansionTile(
        key: PageStorageKey('$depth-$label'),
        dense: true,
        initiallyExpanded: depth < 2 || filter.isNotEmpty,
        controlAffinity: ListTileControlAffinity.leading,
        title: Text(
          '$label ${value is Map ? '{${entries.length}}' : '[${entries.length}]'}',
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
        ),
        childrenPadding: const EdgeInsets.only(left: 14),
        children: [
          for (final e in entries)
            ResponseTree(
              value: e.value,
              label: e.key,
              filter: filter,
              depth: depth + 1,
            ),
        ],
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Align(
        alignment: Alignment.centerLeft,
        child: SelectableText(
          '$label: ${pretty.convert(value)}',
          style: TextStyle(
            fontFamily: 'monospace',
            fontSize: 12,
            color: value is String
                ? const Color(0xff9dd5b3)
                : const Color(0xffb2c6ef),
          ),
        ),
      ),
    );
  }
}

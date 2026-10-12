import 'dart:convert';

import 'package:flutter/material.dart';

import '../schema/schema.dart';
import '../schema/codec.dart';
import 'controller.dart';
import 'design.dart';

/// Local text drafts keep focus and invalid edits without corrupting the request.
class FieldEditor extends StatefulWidget {
  final ProtoField field;
  final SchemaRegistry schema;
  final Object? value;
  final ValueChanged<Object?> onChanged;
  final Set<String> ancestors;
  final int depth;
  const FieldEditor({
    super.key,
    required this.field,
    required this.schema,
    required this.value,
    required this.onChanged,
    this.ancestors = const {},
    this.depth = 0,
  });
  @override
  State<FieldEditor> createState() => _FieldEditorState();
}

class _FieldEditorState extends State<FieldEditor> {
  late final TextEditingController text;
  String? error;
  bool jsonMode = false;
  ProtoField get field => widget.field;
  bool get map =>
      (field.type == 11 || field.type == 10) &&
      widget.schema.messages[field.typeName]?.mapEntry == true;
  bool get structured =>
      (field.type == 11 || field.type == 10) &&
      !map &&
      !field.typeName.startsWith('google.protobuf.') &&
      !widget.ancestors.contains(field.typeName) &&
      widget.depth < 6;
  @override
  void initState() {
    super.initState();
    text = TextEditingController(text: _text(widget.value));
  }

  String _text(Object? v) =>
      ((field.type == 11 || field.type == 10) && !scalarWrapper)
      ? pretty.convert(v ?? {})
      : v?.toString() ?? '';
  bool get scalarWrapper =>
      field.typeName.startsWith('google.protobuf.') &&
      ProtoCodec.wrappers.containsKey(field.typeName.split('.').last);
  int get scalarType => scalarWrapper
      ? ProtoCodec.wrappers[field.typeName.split('.').last]!
      : field.type;
  @override
  void didUpdateWidget(covariant FieldEditor old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value &&
        error == null &&
        text.text != _text(widget.value)) {
      text.text = _text(widget.value);
    }
  }

  @override
  void dispose() {
    text.dispose();
    super.dispose();
  }

  void update(Object? value) {
    widget.onChanged(value);
  }

  Widget editor(
    ProtoField f,
    Object? value,
    ValueChanged<Object?> changed,
    int index,
  ) => FieldEditor(
    key: ValueKey('${field.name}-$index'),
    field: f,
    schema: widget.schema,
    value: value,
    onChanged: changed,
    ancestors: widget.ancestors,
    depth: widget.depth + 1,
  );
  @override
  Widget build(BuildContext context) {
    if (field.repeated && !map) {
      final values = widget.value is List
          ? List<Object?>.from(widget.value as List)
          : <Object?>[];
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < values.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: DeskSpace.gap,
                      vertical: 9,
                    ),
                    child: Text('$i'),
                  ),
                  Expanded(
                    child: editor(field.item, values[i], (v) {
                      values[i] = v;
                      update(values);
                    }, i),
                  ),
                  IconButton(
                    tooltip: 'Remove item ${i + 1}',
                    onPressed: () {
                      values.removeAt(i);
                      update(values);
                    },
                    icon: const Icon(Icons.remove_circle_outline, size: 18),
                  ),
                ],
              ),
            ),
          TextButton.icon(
            onPressed: () {
              final codec = ProtoCodec(widget.schema);
              values.add(
                field.typeName == 'google.protobuf.Timestamp'
                    ? DateTime.now().toUtc().toIso8601String()
                    : field.typeName == 'google.protobuf.Duration'
                    ? '0s'
                    : scalarWrapper
                    ? codec.defaultValue(
                        ProtoField(
                          name: field.name,
                          jsonName: field.jsonName,
                          number: field.number,
                          type: scalarType,
                        ),
                      )
                    : codec.defaultValue(field.item),
              );
              update(values);
            },
            icon: const Icon(Icons.add, size: 16),
            label: const Text('Add item'),
          ),
        ],
      );
    }
    if (structured && !jsonMode) {
      final message = widget.schema.messages[field.typeName]!;
      final value = widget.value is Map
          ? Map<String, Object?>.from(widget.value as Map)
          : <String, Object?>{};
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'Form',
                style: DeskType.label.copyWith(color: Colors.tealAccent),
              ),
              TextButton(
                onPressed: () {
                  setState(() {
                    jsonMode = true;
                    text.text = pretty.convert(widget.value ?? {});
                  });
                },
                child: const Text('JSON'),
              ),
              const Spacer(),
              TextButton(
                onPressed: () => update(null),
                child: const Text('Unset'),
              ),
            ],
          ),
          Container(
            padding: const EdgeInsets.only(left: 12),
            decoration: const BoxDecoration(
              border: Border(left: BorderSide(color: Color(0xff344048))),
            ),
            child: Column(
              children: [
                for (final f in message.fields)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: DeskSpace.small,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        FieldHeading(field: f),
                        const SizedBox(height: DeskSpace.small),
                        FieldEditor(
                          key: ValueKey(f.name),
                          field: f,
                          schema: widget.schema,
                          value: value[f.jsonName],
                          ancestors: {...widget.ancestors, field.typeName},
                          depth: widget.depth + 1,
                          onChanged: (v) {
                            if (v == null) {
                              value.remove(f.jsonName);
                            } else {
                              if (f.oneof != null) {
                                for (final sibling in message.fields.where(
                                  (s) => s.oneof == f.oneof,
                                )) {
                                  value.remove(sibling.jsonName);
                                }
                              }
                              value[f.jsonName] = v;
                            }
                            update(value);
                          },
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      );
    }
    if (scalarType == 8) {
      return Row(
        children: [
          Checkbox(
            tristate: true,
            value: widget.value as bool?,
            onChanged: update,
          ),
          Text(widget.value == null ? 'Unset' : widget.value.toString()),
        ],
      );
    }
    if (scalarType == 14) {
      final values =
          widget.schema.enumNumbers[field.typeName]?.keys.toList() ??
          widget.schema.enums[field.typeName]?.values.toSet().toList() ??
          [];
      return DropdownButtonFormField<String>(
        isExpanded: true,
        style: DeskType.body,
        initialValue: values.contains(widget.value)
            ? widget.value as String
            : null,
        decoration: const InputDecoration(
          hintText: 'Unset',
          contentPadding: DeskSpace.dropdownPadding,
        ),
        items: [
          const DropdownMenuItem(value: '', child: Text('Unset')),
          for (final v in values)
            DropdownMenuItem(
              value: v,
              child: Text(v, overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: (v) => update(v == '' ? null : v),
      );
    }
    final json =
        (field.type == 11 || field.type == 10) &&
        !scalarWrapper &&
        field.typeName != 'google.protobuf.Timestamp' &&
        field.typeName != 'google.protobuf.Duration' &&
        field.typeName != 'google.protobuf.FieldMask';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (structured)
          TextButton(
            onPressed: error == null
                ? () {
                    setState(() => jsonMode = false);
                  }
                : null,
            child: const Text('Switch to Form'),
          ),
        TextField(
          controller: text,
          maxLines: json ? 4 : 1,
          style: json ? DeskType.code : DeskType.body,
          decoration: InputDecoration(
            isDense: true,
            contentPadding: json
                ? const EdgeInsets.all(DeskSpace.inset)
                : DeskSpace.fieldPadding,
            errorText: error,
            hintText: json ? '{}' : 'Unset',
            suffixIcon: field.typeName == 'google.protobuf.Timestamp'
                ? IconButton(
                    tooltip: 'Choose date',
                    icon: const Icon(Icons.calendar_month, size: 18),
                    onPressed: () async {
                      final date = await showDatePicker(
                        context: context,
                        firstDate: DateTime(1970),
                        lastDate: DateTime(2200),
                        initialDate:
                            DateTime.tryParse(text.text) ?? DateTime.now(),
                      );
                      if (date != null && context.mounted) {
                        final hour = await showTimePicker(
                          context: context,
                          initialTime: const TimeOfDay(hour: 0, minute: 0),
                        );
                        if (hour != null) {
                          final value = DateTime.utc(
                            date.year,
                            date.month,
                            date.day,
                            hour.hour,
                            hour.minute,
                          ).toIso8601String();
                          text.text = value;
                          update(value);
                        }
                      }
                    },
                  )
                : null,
          ),
          onChanged: (raw) {
            try {
              Object? value;
              if (raw.isEmpty) {
                value = null;
              } else if (json) {
                value = jsonDecode(raw);
                ProtoCodec(widget.schema).encode(field.typeName, value);
              } else if ({1, 2}.contains(scalarType)) {
                value = num.tryParse(raw) ?? raw;
              } else if ({5, 7, 13, 15, 17}.contains(scalarType)) {
                value = int.parse(raw);
              } else {
                value = raw;
              }
              setState(() => error = null);
              update(value);
            } catch (e) {
              setState(() => error = e.toString());
            }
          },
        ),
      ],
    );
  }
}

String typeLabel(int type) =>
    const {
      1: 'double',
      2: 'float',
      3: 'int64',
      4: 'uint64',
      5: 'int32',
      6: 'fixed64',
      7: 'fixed32',
      8: 'bool',
      9: 'string',
      10: 'group',
      11: 'message',
      12: 'bytes',
      13: 'uint32',
      14: 'enum',
      15: 'sfixed32',
      16: 'sfixed64',
      17: 'sint32',
      18: 'sint64',
    }[type] ??
    'unknown';

/// One heading treatment for top-level, nested and repeated fields.
class FieldHeading extends StatelessWidget {
  final ProtoField field;
  final Widget? action;
  const FieldHeading({super.key, required this.field, this.action});
  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(child: Text(field.jsonName, style: DeskType.label)),
      const SizedBox(width: DeskSpace.gap),
      Flexible(
        fit: FlexFit.tight,
        child: Tooltip(
          message: field.typeName,
          child: Text(
            '${field.repeated ? 'repeated ' : ''}${typeLabel(field.type)}${field.typeName.isEmpty ? '' : ' · ${field.typeName.split('.').last}'}',
            textAlign: TextAlign.right,
            style: DeskType.secondary.copyWith(color: Colors.grey),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
      ?action,
    ],
  );
}

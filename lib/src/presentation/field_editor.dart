import 'dart:convert';

import 'package:flutter/material.dart';

import '../schema/schema.dart';
import '../schema/codec.dart';
import 'controller.dart';
import 'design.dart';

class _UnsetField {
  const _UnsetField();
}

const unsetFieldValue = _UnsetField();

/// Local text drafts keep focus and invalid edits without corrupting the request.
class FieldEditor extends StatefulWidget {
  final ProtoField field;
  final SchemaRegistry schema;
  final Object? value;
  final ValueChanged<Object?> onChanged;
  final Set<String> ancestors;
  final int depth;
  final bool present;
  const FieldEditor({
    super.key,
    required this.field,
    required this.schema,
    required this.value,
    required this.onChanged,
    this.ancestors = const {},
    this.depth = 0,
    this.present = true,
  });
  @override
  State<FieldEditor> createState() => _FieldEditorState();
}

class _FieldEditorState extends State<FieldEditor>
    with AutomaticKeepAliveClientMixin<FieldEditor> {
  @override
  bool get wantKeepAlive => true;
  late final TextEditingController text;
  String? error;
  bool jsonMode = false;
  final itemKeys = <UniqueKey>[];
  int structureRevision = 0;
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

  String _text(Object? v, {bool? present}) => jsonInput
      ? pretty.convert(
          v ??
              (field.typeName == 'google.protobuf.Value' &&
                      (present ?? widget.present)
                  ? null
                  : {}),
        )
      : v?.toString() ?? '';
  bool get stringWellKnown => const {
    'google.protobuf.Timestamp',
    'google.protobuf.Duration',
    'google.protobuf.FieldMask',
  }.contains(field.typeName);
  bool get jsonInput =>
      (field.type == 11 || field.type == 10) &&
      !scalarWrapper &&
      !stringWellKnown;
  bool get scalarWrapper =>
      field.typeName.startsWith('google.protobuf.') &&
      ProtoCodec.wrappers.containsKey(field.typeName.split('.').last);
  int get scalarType => scalarWrapper
      ? ProtoCodec.wrappers[field.typeName.split('.').last]!
      : field.type;
  @override
  void didUpdateWidget(covariant FieldEditor old) {
    super.didUpdateWidget(old);
    if (_text(old.value, present: old.present) != _text(widget.value) &&
        text.text != _text(widget.value)) {
      error = null;
      if (widget.value == null) structureRevision++;
      final next = _text(widget.value);
      // Updating a TextFormField controller during its parent's build would
      // notify the Form while the widget tree is still being rebuilt.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _text(widget.value) == next && text.text != next) {
          text.value = TextEditingValue(
            text: next,
            selection: TextSelection.collapsed(offset: next.length),
          );
        }
      });
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
    key: ValueKey(field.name),
    field: f,
    schema: widget.schema,
    value: value,
    onChanged: changed,
    ancestors: widget.ancestors,
    depth: widget.depth + 1,
  );
  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (field.repeated && !map) {
      final values = widget.value is List
          ? List<Object?>.from(widget.value as List)
          : <Object?>[];
      while (itemKeys.length < values.length) {
        itemKeys.add(UniqueKey());
      }
      if (itemKeys.length > values.length) {
        itemKeys.removeRange(values.length, itemKeys.length);
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < values.length; i++)
            Padding(
              key: itemKeys[i],
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
                      values[i] = identical(v, unsetFieldValue) ? null : v;
                      update(values);
                    }, i),
                  ),
                  IconButton(
                    tooltip: 'Remove item ${i + 1}',
                    onPressed: () {
                      values.removeAt(i);
                      itemKeys.removeAt(i);
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
              itemKeys.add(UniqueKey());
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
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                'Form',
                style: DeskType.label.copyWith(color: Colors.tealAccent),
              ),
              TextButton(
                onPressed: () {
                  if (Form.maybeOf(context)?.validate() == false) return;
                  setState(() {
                    jsonMode = true;
                    text.text = pretty.convert(widget.value ?? {});
                  });
                },
                child: const Text('JSON'),
              ),
              IconButton(
                tooltip: 'Set empty message',
                onPressed: () => update(<String, Object?>{}),
                icon: const Icon(Icons.add_box_outlined, size: 18),
              ),
              TextButton(
                onPressed: () => update(unsetFieldValue),
                child: const Text('Unset'),
              ),
            ],
          ),
          Container(
            key: ValueKey(structureRevision),
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
                          value: value.containsKey(f.jsonName)
                              ? value[f.jsonName]
                              : value[f.name],
                          present:
                              value.containsKey(f.jsonName) ||
                              value.containsKey(f.name),
                          ancestors: {...widget.ancestors, field.typeName},
                          depth: widget.depth + 1,
                          onChanged: (v) {
                            value.remove(f.name);
                            if (identical(v, unsetFieldValue) ||
                                (v == null &&
                                    f.typeName != 'google.protobuf.Value' &&
                                    f.typeName !=
                                        'google.protobuf.NullValue')) {
                              value.remove(f.jsonName);
                            } else {
                              if (f.oneof != null) {
                                for (final sibling in message.fields.where(
                                  (s) => s.oneof == f.oneof,
                                )) {
                                  value.remove(sibling.jsonName);
                                  value.remove(sibling.name);
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
    if (field.typeName == 'google.protobuf.NullValue') {
      return Row(
        children: [
          const Text('null'),
          TextButton(
            onPressed: () => update(null),
            child: const Text('Set null'),
          ),
          TextButton(
            onPressed: () => update(unsetFieldValue),
            child: const Text('Unset'),
          ),
        ],
      );
    }
    if (scalarType == 14) {
      final values =
          widget.schema.enumNumbers[field.typeName]?.keys.toList() ??
          widget.schema.enums[field.typeName]?.values.toSet().toList() ??
          [];
      return DeskDropdown<String>(
        value: values.contains(widget.value) ? widget.value as String : null,
        decoration: const InputDecoration(hintText: 'Unset'),
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
    final json = jsonInput;
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
        TextFormField(
          validator: (_) => error,
          controller: text,
          maxLines: json ? 4 : 1,
          style: json ? DeskType.code : DeskType.body,
          decoration: InputDecoration(
            contentPadding: json ? const EdgeInsets.all(DeskSpace.inset) : null,
            errorText: error,
            hintText: json ? '{}' : 'Unset',
            suffixIcon: field.typeName == 'google.protobuf.Timestamp'
                ? IconButton(
                    tooltip: 'Choose date',
                    icon: const Icon(Icons.calendar_month, size: 18),
                    onPressed: () async {
                      final fraction = RegExp(r'\.(\d{1,9})')
                          .firstMatch(text.text)
                          ?.group(1);
                      final parsed = DateTime.tryParse(text.text)?.toUtc();
                      final initial =
                          parsed != null &&
                              parsed.year >= 1 &&
                              parsed.year <= 9999
                          ? parsed
                          : DateTime.now().toUtc();
                      final date = await showDatePicker(
                        context: context,
                        firstDate: DateTime(1),
                        lastDate: DateTime(9999, 12, 31),
                        initialDate: initial,
                      );
                      if (date != null && context.mounted) {
                        final hour = await showTimePicker(
                          context: context,
                          initialTime: TimeOfDay.fromDateTime(initial),
                        );
                        if (hour != null) {
                          final value = DateTime.utc(
                            date.year,
                            date.month,
                            date.day,
                            hour.hour,
                            hour.minute,
                            initial.second,
                            initial.millisecond,
                            initial.microsecond,
                          ).toIso8601String();
                          final precise = value.replaceFirst(
                            RegExp(r'\.\d+Z$'),
                            fraction == null ? 'Z' : '.${fraction}Z',
                          );
                          text.text = precise;
                          update(precise);
                        }
                      }
                    },
                  )
                : IconButton(
                    tooltip: 'Unset field',
                    onPressed: () {
                      text.clear();
                      setState(() => error = null);
                      update(unsetFieldValue);
                    },
                    icon: const Icon(Icons.clear, size: 16),
                  ),
          ),
          onChanged: (raw) {
            try {
              Object? value;
              if (raw.isEmpty) {
                value =
                    {9, 12}.contains(scalarType) ||
                        field.typeName == 'google.protobuf.FieldMask'
                    ? ''
                    : null;
              } else if (json) {
                value = jsonDecode(raw);
              } else if ({1, 2}.contains(scalarType)) {
                value = num.tryParse(raw) ?? raw;
              } else if ({5, 7, 13, 15, 17}.contains(scalarType)) {
                value = int.parse(raw);
              } else {
                value = raw;
              }
              if (value != null ||
                  (json &&
                      raw == 'null' &&
                      field.typeName == 'google.protobuf.Value')) {
                ProtoCodec(widget.schema).validateField(field, value);
              }
              setState(() => error = null);
              update(
                raw.isEmpty && field.typeName == 'google.protobuf.Value'
                    ? unsetFieldValue
                    : value,
              );
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

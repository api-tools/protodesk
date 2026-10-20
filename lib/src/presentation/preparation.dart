import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../security/credentials.dart';
import '../workflow/preparation.dart';
import '../workflow/preparation_storage.dart';
import 'controller.dart';
import 'credentials.dart';
import 'design.dart';

Future<void> showRequestPreparation(
  BuildContext context,
  DeskController desk,
) => showDialog<void>(context: context, builder: (_) => _Preparation(desk));

class _EnvironmentDraft {
  final String id;
  String name, json;
  final Set<String> unbound;
  _EnvironmentDraft(this.id, this.name, this.json, this.unbound);
}

class _PresetDraft {
  final String id;
  String name, json;
  MetadataReferences references;
  bool selected = false;
  _PresetDraft(this.id, this.name, this.json, this.references);
}

class _Preparation extends StatefulWidget {
  final DeskController desk;
  const _Preparation(this.desk);
  @override
  State<_Preparation> createState() => _PreparationState();
}

class _PreparationState extends State<_Preparation> {
  static const pretty = JsonEncoder.withIndent('  ');
  final name = TextEditingController(), json = TextEditingController();
  final environments = <_EnvironmentDraft>[], presets = <_PresetDraft>[];
  String? serverId, editingEnvironment, editingPreset;
  String environment = '', error = '', status = '', tab = 'Prepare';
  bool broken = false, busy = false;
  int generation = 0;
  PreparedRequest? prepared;
  PreparationTemplate? savedTemplate, previewTemplate;
  String? templateMethod;
  bool useSavedTemplate = false, keepTemplate = true;
  String templateWarning = '';
  String? originalBody,
      originalMetadata,
      originalReferences,
      originalMethod,
      originalAuthority,
      originalSignature;
  int? originalTimeout;
  DeskController get desk => widget.desk;
  @override
  void initState() {
    super.initState();
    serverId = desk.server?['id'] as String?;
    templateMethod = desk.method?.path;
    if (serverId == null) {
      broken = true;
      error = 'Select a server profile first.';
      return;
    }
    try {
      if (desk.method != null) {
        savedTemplate = PreparationTemplateStore(desk.store)
            .load(serverId!, desk.method!.path);
      }
      if (savedTemplate != null) keepTemplate = false;
    } catch (_) {
      keepTemplate = false;
      templateWarning = 'Saved template is unsupported or invalid and remains intact. Current-draft preparation is still available without replacing it.';
    }
    try {
      final config = PreparationProfiles.decode(
        desk.server!['requestProfilesJson'] as String?,
      );
      for (final item in config.environments) {
        final values = item['variables'] as Map;
        environments.add(
          _EnvironmentDraft(
            item['id'] as String,
            item['name'] as String,
            pretty.convert({
              for (final entry in values.entries)
                if ((entry.value as Map)['bound'] == true)
                  entry.key: (entry.value as Map)['value'],
            }),
            {
              for (final entry in values.entries)
                if ((entry.value as Map)['bound'] != true) entry.key as String,
            },
          ),
        );
      }
      for (final item in config.presets) {
        presets.add(
          _PresetDraft(
            item['id'] as String,
            item['name'] as String,
            pretty.convert(item['metadata']),
            MetadataReferences.decode(item['references'] as String),
          ),
        );
      }
    } catch (_) {
      broken = true;
      error = 'Saved preparation definitions are invalid or unsupported. Original data remains intact. Export the full workspace for recovery; editing here is disabled.';
    }
  }

  @override
  void dispose() {
    generation++;
    name.dispose();
    json.dispose();
    super.dispose();
  }

  void invalidate([VoidCallback? change]) {
    generation++;
    setState(() {
      change?.call();
      prepared = null;
      busy = false;
      error = '';
      status = '';
    });
  }

  _EnvironmentDraft? get selectedEnvironment =>
      environments.where((e) => e.id == editingEnvironment).firstOrNull;
  _PresetDraft? get selectedPreset =>
      presets.where((e) => e.id == editingPreset).firstOrNull;
  void chooseEditor(String nextTab, String? id) {
    invalidate(() {
      tab = nextTab;
      if (tab == 'Environments') editingEnvironment = id;
      if (tab == 'Metadata presets') editingPreset = id;
      final item = tab == 'Environments' ? selectedEnvironment : selectedPreset;
      name.text = item is _EnvironmentDraft
          ? item.name
          : item is _PresetDraft
          ? item.name
          : '';
      json.text = item is _EnvironmentDraft
          ? item.json
          : item is _PresetDraft
          ? item.json
          : '{}';
    });
  }

  PreparationProfiles config() {
    try {
      return PreparationProfiles({
        'version': 1,
        'environments': [
          for (final item in environments)
            {
              'id': item.id,
              'name': item.name,
              'variables': {
                for (final key in item.unbound) key: {'bound': false},
                for (final entry in (jsonDecode(item.json) as Map).entries)
                  entry.key: {'bound': true, 'value': entry.value},
              },
            },
        ],
        'presets': [
          for (final item in presets)
            {
              'id': item.id,
              'name': item.name,
              'metadata': parseLiteralMetadata(item.json),
              'references': item.references.encode(),
            },
        ],
      });
    } catch (_) {
      throw const PreparationFailure(
        'Review every definition: names must be unique, variables a JSON object and metadata a JSON object of strings. Original stored definitions remain intact.',
      );
    }
  }

  void saveDefinitions() {
    try {
      final value = config().encode();
      final current = desk.store
          .list('servers')
          .where((s) => s['id'] == serverId)
          .firstOrNull;
      if (current == null) {
        throw const PreparationFailure('Server profile no longer exists.');
      }
      final saved = desk.store.save('servers', {
        ...current,
        'requestProfilesJson': value,
      });
      if (desk.server?['id'] == serverId) desk.server = saved;
      desk.refresh();
      for (final item in environments) {
        final bound = (jsonDecode(item.json) as Map).keys.toSet();
        item.unbound.removeWhere(bound.contains);
      }
      setState(() {
        status = 'Definitions saved locally. Existing calls, drafts and snapshots were not changed.';
        error = '';
      });
    } catch (e) {
      setState(() => error = e.toString());
    }
  }

  Future<void> preview() async {
    final current = ++generation;
    try {
      if (desk.invoking || desk.connecting || desk.server?['id'] != serverId) {
        throw const PreparationFailure(
          'Finish the active operation and select the original server before preparing.',
        );
      }
      if (desk.method == null) {
        throw const PreparationFailure(
          'Select a method before preparing a request. Definitions can be saved without connecting.',
        );
      }
      if (useSavedTemplate && desk.method?.path != templateMethod) {
        throw const PreparationFailure(
          'Selected method changed. Reopen preparation to load its own template.',
        );
      }
      final method = desk.method?.path,
          authority = desk.authority,
          timeout = desk.timeoutMs,
          signature = desk.schemaSignature();
      final guardBody = desk.body,
          guardMetadata = desk.metadata,
          guardReferences = desk.requestCredentials.encode();
      final source = useSavedTemplate
          ? savedTemplate!
          : PreparationTemplate(guardBody, guardMetadata, guardReferences);
      final definitions = config().encode(),
          body = source.body,
          metadata = source.metadata,
          refs = source.references;
      final environmentId = environment.isEmpty ? null : environment;
      final ids = [
        for (final preset in presets)
          if (preset.selected) preset.id,
      ];
      setState(() {
        busy = true;
        error = '';
        prepared = null;
        status = 'Preparing locally…';
      });
      final result = await prepareRequestInWorker(
        definitions: definitions,
        body: body,
        metadata: metadata,
        references: refs,
        environmentId: environmentId,
        presetIds: ids,
      );
      if (!mounted || current != generation) return;
      final invalid = desk.validateBody(result.body);
      if (invalid != null) {
        throw const PreparationFailure(
          'Prepared JSON is incompatible with the selected method. Review variable types and fields; no draft changed.',
        );
      }
      setState(() {
        prepared = result;
        originalBody = guardBody;
        originalMetadata = guardMetadata;
        originalReferences = guardReferences;
        previewTemplate = source;
        originalMethod = method;
        originalAuthority = authority;
        originalTimeout = timeout;
        originalSignature = signature;
        status = 'Preview ready. No credential was read, connection opened or RPC invoked.';
      });
    } catch (e) {
      if (mounted && current == generation) {
        setState(
          () => error = e is PreparationFailure ? e.toString() : 'Preparation could not complete. Existing draft remains unchanged.',
        );
      }
    } finally {
      if (mounted && current == generation) setState(() => busy = false);
    }
  }

  void apply() {
    final result = prepared;
    if (result == null) return;
    if (desk.invoking ||
        desk.connecting ||
        desk.server?['id'] != serverId ||
        desk.body != originalBody ||
        desk.metadata != originalMetadata ||
        desk.requestCredentials.encode() != originalReferences ||
        desk.method?.path != originalMethod ||
        desk.authority != originalAuthority ||
        desk.timeoutMs != originalTimeout ||
        desk.schemaSignature() != originalSignature) {
      invalidate();
      setState(() => error = 'Request changed. Preview again before applying.');
      return;
    }
    try {
      if (keepTemplate && previewTemplate != null) {
        PreparationTemplateStore(desk.store)
            .save(serverId!, originalMethod!, previewTemplate!);
      }
    } catch (e) {
      setState(() => error = e.toString());
      return;
    }
    desk.body = result.body;
    desk.metadata = pretty.convert(result.metadata);
    desk.requestCredentials = result.references;
    desk.status = 'Prepared draft applied. Queued/sent snapshots and connection settings unchanged; no RPC invoked.';
    desk.emit();
    Navigator.pop(context);
  }

  void restoreTemplate() {
    if (savedTemplate == null ||
        desk.invoking ||
        desk.connecting ||
        desk.server?['id'] != serverId ||
        desk.method?.path != templateMethod) {
      setState(
        () => error = 'Finish the active operation and reopen preparation for the selected method.',
      );
      return;
    }
    desk.body = savedTemplate!.body;
    desk.metadata = savedTemplate!.metadata;
    desk.requestCredentials = MetadataReferences.decode(
      savedTemplate!.references,
    );
    desk.status = 'Source template restored for editing or saving. Prepare its variables before invoking.';
    desk.emit();
    Navigator.pop(context);
  }

  Widget editor() {
    final envMode = tab == 'Environments';
    final activePreset = selectedPreset;
    final currentId = envMode ? editingEnvironment : editingPreset;
    final ids = envMode
        ? environments.map((e) => (e.id, e.name)).toList()
        : presets.map((e) => (e.id, e.name)).toList();
    final active = envMode
        ? selectedEnvironment != null
        : selectedPreset != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: DeskDropdown<String>(
                value: currentId,
                items: [
                  for (final item in ids)
                    DropdownMenuItem(
                      value: item.$1,
                      child: Text(item.$2, overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: (id) => chooseEditor(tab, id),
              ),
            ),
            TextButton(
              onPressed: () {
                final id = const Uuid().v4();
                if (envMode) {
                  environments.add(
                    _EnvironmentDraft(
                      id,
                      'Environment ${environments.length + 1}',
                      '{}',
                      {},
                    ),
                  );
                } else {
                  presets.add(
                    _PresetDraft(
                      id,
                      'Preset ${presets.length + 1}',
                      '{}',
                      MetadataReferences({}),
                    ),
                  );
                }
                chooseEditor(tab, id);
              },
              child: Text(envMode ? 'Add environment' : 'Add preset'),
            ),
            IconButton(
              tooltip: 'Remove definition',
              onPressed: !active
                  ? null
                  : () {
                      invalidate(() {
                        if (envMode) {
                          environments.removeWhere((e) => e.id == currentId);
                          if (environment == currentId) environment = '';
                          editingEnvironment = null;
                        } else {
                          presets.removeWhere((e) => e.id == currentId);
                          editingPreset = null;
                        }
                      });
                    },
              icon: const Icon(Icons.close, size: 16),
            ),
          ],
        ),
        if (!active)
          const Padding(
            padding: EdgeInsets.all(DeskSpace.inset),
            child: Text(
              'Add or select a definition. Nothing is created automatically.',
              style: DeskType.secondary,
            ),
          ),
        if (active) ...[
          const SizedBox(height: DeskSpace.small),
          TextField(
            controller: name,
            decoration: InputDecoration(
              labelText: envMode ? 'Environment name' : 'Preset name',
            ),
            onChanged: (value) => invalidate(() {
              if (envMode) {
                selectedEnvironment!.name = value;
              } else {
                selectedPreset!.name = value;
              }
            }),
          ),
          const SizedBox(height: DeskSpace.inset),
          Text(
            envMode
                ? 'Variables are literal local JSON values. Use the OS store for secrets. Explicit null, empty strings, false, zero, objects and arrays are preserved.'
                : 'Reusable RPC headers only. Presets apply in selected order, then existing request overrides win. Reflection metadata is unchanged.',
            style: DeskType.secondary,
          ),
          if (envMode)
            for (final key in selectedEnvironment!.unbound)
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '$key · unbound (add a value below to bind)',
                      style: DeskType.secondary,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Remove unbound variable $key',
                    onPressed: () => invalidate(
                      () => selectedEnvironment!.unbound.remove(key),
                    ),
                    icon: const Icon(Icons.close, size: 16),
                  ),
                ],
              ),
          const SizedBox(height: DeskSpace.small),
          TextField(
            controller: json,
            minLines: 5,
            maxLines: 10,
            style: DeskType.code,
            decoration: InputDecoration(
              labelText: envMode
                  ? 'Variables (JSON object)'
                  : 'Literal RPC metadata (JSON object)',
              alignLabelWithHint: true,
            ),
            onChanged: (value) => invalidate(() {
              if (envMode) {
                selectedEnvironment!.json = value;
              } else {
                selectedPreset!.json = value;
              }
            }),
          ),
          if (!envMode && activePreset != null) ...[
            const SizedBox(height: DeskSpace.inset),
            MetadataCredentialEditor(
              key: ValueKey(activePreset.id),
              desk: desk,
              title: 'Protected preset headers',
              scope: () => DeskController.credentialScope(
                desk.server!,
                authority: desk.authority,
              ),
              references: activePreset.references,
              onChanged: (refs) {
                if (mounted && presets.contains(activePreset)) {
                  invalidate(() => activePreset.references = refs);
                }
              },
              literals: () => parseLiteralMetadata(activePreset.json),
              onLiteralsChanged: (values) {
                if (mounted && presets.contains(activePreset)) {
                  invalidate(() {
                    activePreset.json = pretty.convert(values);
                    if (selectedPreset?.id == activePreset.id) {
                      json.text = activePreset.json;
                    }
                  });
                }
              },
            ),
          ],
        ],
      ],
    );
  }

  Widget prepareControls() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text(
        'Prepare previews substitutions locally. Apply explicitly materializes the current JSON and request/preset headers; changing saved definitions never changes active calls or queued/sent snapshots.',
        style: DeskType.secondary,
      ),
      const SizedBox(height: DeskSpace.inset),
      DeskDropdown<bool>(
        value: useSavedTemplate,
        decoration: const InputDecoration(labelText: 'Preparation source'),
        items: [
          const DropdownMenuItem(value: false, child: Text('Current draft')),
          if (savedTemplate != null)
            const DropdownMenuItem(
              value: true,
              child: Text('Saved reusable template'),
            ),
        ],
        onChanged: (value) => invalidate(() => useSavedTemplate = value!),
      ),
      if (useSavedTemplate)
        TextButton(
          onPressed: busy ? null : restoreTemplate,
          child: const Text('Load saved template into draft'),
        ),
      CheckboxListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        title: Text(
          savedTemplate == null
              ? 'Keep source template for reuse (local to this server/method)'
              : 'Replace saved source template (explicit overwrite)',
          style: DeskType.body,
        ),
        value: keepTemplate,
        onChanged: templateWarning.isNotEmpty
            ? null
            : (value) => invalidate(() => keepTemplate = value!),
      ),
      if (templateWarning.isNotEmpty)
        Text(templateWarning, style: DeskType.secondary),
      const Text(
        'Choose Saved reusable template to prepare the original placeholders again for another environment. Working templates are excluded from workspace exports.',
        style: DeskType.secondary,
      ),
      const SizedBox(height: DeskSpace.inset),
      DeskDropdown<String>(
        value: environment,
        decoration: const InputDecoration(labelText: 'Environment'),
        items: [
          const DropdownMenuItem(value: '', child: Text('No environment')),
          for (final item in environments)
            DropdownMenuItem(
              value: item.id,
              child: Text(item.name, overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: (id) => invalidate(() => environment = id!),
      ),
      const SizedBox(height: DeskSpace.inset),
      const Text(
        'RPC presets · top to bottom, then current request overrides',
        style: DeskType.label,
      ),
      if (presets.isEmpty)
        const Text('No presets configured.', style: DeskType.secondary),
      for (var index = 0; index < presets.length; index++)
        Row(
          children: [
            Expanded(
              child: CheckboxListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(presets[index].name, style: DeskType.body),
                value: presets[index].selected,
                onChanged: (v) =>
                    invalidate(() => presets[index].selected = v!),
              ),
            ),
            IconButton(
              tooltip: 'Move preset up',
              onPressed: index == 0
                  ? null
                  : () => invalidate(() {
                      final item = presets.removeAt(index);
                      presets.insert(index - 1, item);
                    }),
              icon: const Icon(Icons.arrow_upward, size: 16),
            ),
            IconButton(
              tooltip: 'Move preset down',
              onPressed: index == presets.length - 1
                  ? null
                  : () => invalidate(() {
                      final item = presets.removeAt(index);
                      presets.insert(index + 1, item);
                    }),
              icon: const Icon(Icons.arrow_downward, size: 16),
            ),
          ],
        ),
      const SizedBox(height: DeskSpace.inset),
      const Text(
        r'Use ${name} in JSON values or literal headers. A whole JSON value placeholder retains its type; embedded scalars become text. Escape $${name} for literal ${name}. Keys, endpoints, TLS, reflection and protected values are not interpolated.',
        style: DeskType.secondary,
      ),
      if (prepared != null) ...[
        const Divider(),
        for (final note in prepared!.notes)
          Text(note, style: DeskType.secondary),
        Text(
          'RPC literal headers: ${prepared!.metadata.keys.join(', ')} · Protected headers: ${prepared!.references.headers.keys.join(', ')}',
          style: DeskType.secondary,
        ),
        const SizedBox(height: DeskSpace.small),
        SelectableText(
          prepared!.body.length > 16000
              ? '${prepared!.body.substring(0, 16000)}\n… Preview truncated; Apply uses the complete bounded result.'
              : pretty.convert(jsonDecode(prepared!.body)),
          style: DeskType.code,
        ),
      ],
    ],
  );
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Environments & metadata presets'),
    content: SizedBox(
      width: min(820, MediaQuery.sizeOf(context).width - 96),
      height: min(540, MediaQuery.sizeOf(context).height - 190),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!broken)
            Wrap(
              children: [
                for (final label in [
                  'Prepare',
                  'Environments',
                  'Metadata presets',
                ])
                  TextButton(
                    onPressed: () => chooseEditor(
                      label,
                      label == 'Environments'
                          ? editingEnvironment
                          : editingPreset,
                    ),
                    child: Text(
                      label,
                      style: tab == label ? DeskType.heading : DeskType.body,
                    ),
                  ),
              ],
            ),
          if (busy) const LinearProgressIndicator(),
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (!broken)
                    if (tab == 'Prepare') prepareControls() else editor(),
                  if (error.isNotEmpty) Text(error, style: DeskType.secondary),
                  if (status.isNotEmpty)
                    Text(status, style: DeskType.secondary),
                ],
              ),
            ),
          ),
        ],
      ),
    ),
    actions: [
      if (!broken)
        TextButton(
          onPressed: busy ? null : saveDefinitions,
          child: const Text('Save definitions'),
        ),
      if (!broken && tab == 'Prepare')
        TextButton(
          onPressed: busy ? null : preview,
          child: const Text('Preview preparation'),
        ),
      if (!broken && tab == 'Prepare')
        FilledButton(
          onPressed: prepared == null || busy ? null : apply,
          child: const Text('Apply prepared draft'),
        ),
      if (busy)
        TextButton(
          onPressed: () => invalidate(),
          child: const Text('Cancel preparation'),
        ),
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Close'),
      ),
    ],
  );
}

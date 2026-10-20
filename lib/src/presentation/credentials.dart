import 'package:flutter/material.dart';

import '../security/credentials.dart';
import 'controller.dart';
import 'design.dart';

/// Only labels and opaque references enter parent form state. Values are held
/// by this dialog's controllers until the OS write is confirmed.
Future<String?> createCredential(
  BuildContext context,
  DeskController desk,
  CredentialScope scope, {
  String initialValue = '',
}) => showDialog<String>(
  context: context,
  builder: (_) => _CreateCredential(desk, scope, initialValue),
);

class _CreateCredential extends StatefulWidget {
  final DeskController desk;
  final CredentialScope scope;
  final String initialValue;
  const _CreateCredential(this.desk, this.scope, this.initialValue);
  @override
  State<_CreateCredential> createState() => _CreateCredentialState();
}

class _CreateCredentialState extends State<_CreateCredential> {
  final label = TextEditingController();
  late final value = TextEditingController(text: widget.initialValue);
  bool saving = false;
  String? error;
  @override
  void dispose() {
    label.dispose();
    value.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Store protected credential'),
    content: SizedBox(
      width: 520,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Stored in the OS credential store. No plaintext fallback. Bound to this recipient:',
          ),
          const SizedBox(height: 8),
          SelectableText(widget.scope.target, style: DeskType.code),
          const SizedBox(height: 12),
          TextField(
            controller: label,
            enabled: !saving,
            decoration: const InputDecoration(labelText: 'Label'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: value,
            enabled: !saving,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(labelText: 'Secret value'),
          ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                error!,
                style: DeskType.body.copyWith(
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: saving ? null : () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: saving
            ? null
            : () async {
                setState(() {
                  saving = true;
                  error = null;
                });
                try {
                  final id = await widget.desk.credentials.create(
                    label.text,
                    CredentialValue(widget.scope, value.text),
                  );
                  if (!context.mounted) return;
                  Navigator.pop(context, id);
                } catch (e) {
                  if (!mounted) return;
                  setState(() {
                    saving = false;
                    error = e is CredentialFailure
                        ? e.toString()
                        : CredentialFailure.unavailable.toString();
                  });
                }
              },
        child: Text(saving ? 'Storing…' : 'Store'),
      ),
    ],
  );
}

class MetadataCredentialEditor extends StatefulWidget {
  final DeskController desk;
  final CredentialScope Function() scope;
  final MetadataReferences references;
  final ValueChanged<MetadataReferences> onChanged;
  final String title;
  final Map<String, String> Function() literals;
  final ValueChanged<Map<String, String>> onLiteralsChanged;
  const MetadataCredentialEditor({
    super.key,
    required this.desk,
    required this.scope,
    required this.references,
    required this.onChanged,
    required this.title,
    required this.literals,
    required this.onLiteralsChanged,
  });
  @override
  State<MetadataCredentialEditor> createState() =>
      _MetadataCredentialEditorState();
}

class _MetadataCredentialEditorState extends State<MetadataCredentialEditor> {
  final header = TextEditingController();
  String? error;
  @override
  void dispose() {
    header.dispose();
    super.dispose();
  }

  List<DropdownMenuItem<String>> existing() {
    try {
      return widget.desk.credentialCatalog
          .matching(widget.scope())
          .map(
            (r) => DropdownMenuItem(
              value: r['id'] as String,
              child: Text(r['name'] as String, overflow: TextOverflow.ellipsis),
            ),
          )
          .toList();
    } catch (_) {
      return [];
    }
  }

  void remove(String key) => widget.onChanged(
    MetadataReferences({...widget.references.headers}..remove(key)),
  );
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(widget.title, style: DeskType.heading),
      const SizedBox(height: 8),
      const Text(
        'Literal JSON is retained for compatibility. Protected headers override the same literal header. Store a literal explicitly to migrate it; it is removed from this form only after the OS write succeeds.',
        style: DeskType.secondary,
      ),
      for (final e in widget.references.headers.entries)
        Row(
          children: [
            Expanded(
              child: Text(
                '${e.key} · ${e.value == null ? 'Rebind required' : widget.desk.credentialCatalog.entries.where((r) => r['id'] == e.value).firstOrNull?['name'] ?? 'Unavailable on this computer'}',
                style: DeskType.body,
              ),
            ),
            IconButton(
              tooltip: 'Remove protected header',
              onPressed: () => remove(e.key),
              icon: const Icon(Icons.close),
            ),
          ],
        ),
      const SizedBox(height: 8),
      Row(
        children: [
          Expanded(
            child: TextField(
              controller: header,
              decoration: const InputDecoration(
                labelText: 'Header to protect / migrate',
              ),
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: () async {
              try {
                final key = header.text.trim().toLowerCase();
                MetadataReferences({
                  key: null,
                }); // Validate before any OS operation.
                final literals = widget.literals();
                final initial =
                    literals.entries
                        .where((e) => e.key.toLowerCase() == key)
                        .firstOrNull
                        ?.value ??
                    '';
                final id = await createCredential(
                  context,
                  widget.desk,
                  widget.scope(),
                  initialValue: initial,
                );
                if (!mounted || id == null) return;
                widget.onChanged(
                  MetadataReferences({...widget.references.headers, key: id}),
                );
                widget.onLiteralsChanged(
                  {...literals}..removeWhere((k, _) => k.toLowerCase() == key),
                );
                header.clear();
                setState(() => error = null);
              } catch (e) {
                if (mounted) setState(() => error = e.toString());
              }
            },
            child: const Text('Store securely'),
          ),
        ],
      ),
      if (error != null)
        Text(
          error!,
          style: DeskType.body.copyWith(
            color: Theme.of(context).colorScheme.error,
          ),
        ),
      if (existing().isNotEmpty)
        DropdownButtonFormField<String>(
          key: ValueKey(widget.references.encode()),
          isExpanded: true,
          items: existing(),
          decoration: const InputDecoration(
            labelText: 'Use existing credential for header above',
          ),
          onChanged: (id) {
            if (id == null) return;
            try {
              final key = header.text.trim().toLowerCase();
              final next = MetadataReferences({
                ...widget.references.headers,
                key: id,
              });
              final literals = widget.literals();
              widget.onChanged(next);
              widget.onLiteralsChanged(
                {...literals}..removeWhere((k, _) => k.toLowerCase() == key),
              );
              header.clear();
              setState(() => error = null);
            } catch (e) {
              setState(() => error = e.toString());
            }
          },
        ),
      const SizedBox(height: 12),
    ],
  );
}

Future<void> manageCredentials(BuildContext context, DeskController desk) =>
    showDialog<void>(
      context: context,
      builder: (_) => _CredentialCatalogDialog(desk),
    );

class _CredentialCatalogDialog extends StatefulWidget {
  final DeskController desk;
  const _CredentialCatalogDialog(this.desk);
  @override
  State<_CredentialCatalogDialog> createState() =>
      _CredentialCatalogDialogState();
}

class _CredentialCatalogDialogState extends State<_CredentialCatalogDialog> {
  String? deleting, error;
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Protected credentials'),
    content: SizedBox(
      width: 640,
      height: 360,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Only labels, recipient bindings and lifecycle states are listed. Deleting a credential also disables every profile/request referencing it. Removing a header or source alone retains its credential here.',
          ),
          if (error != null) Text(error!, style: DeskType.secondary),
          const SizedBox(height: 12),
          Expanded(
            child: ListView(
              children: [
                if (widget.desk.credentialCatalog.entries.isEmpty)
                  const Text('No protected credentials on this workspace.'),
                for (final entry in widget.desk.credentialCatalog.entries)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      '${entry['name']} · ${entry['state']}',
                      style: DeskType.label,
                    ),
                    subtitle: Text(
                      entry['scopeJson'] as String,
                      style: DeskType.secondary,
                    ),
                    trailing: TextButton(
                      onPressed: deleting != null
                          ? null
                          : () async {
                              setState(() {
                                deleting = entry['id'] as String;
                                error = null;
                              });
                              try {
                                await widget.desk.credentials.delete(deleting!);
                              } catch (_) {
                                if (mounted) {
                                  setState(
                                    () => error = CredentialFailure.unavailable
                                        .toString(),
                                  );
                                }
                              } finally {
                                if (mounted) setState(() => deleting = null);
                              }
                            },
                      child: Text(
                        deleting == entry['id']
                            ? 'Deleting…'
                            : 'Delete from OS store',
                      ),
                    ),
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
    ],
  );
}

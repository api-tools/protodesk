import 'credentials.dart';

/// One precedence policy shared by transport, history and command exports.
/// Resolved protected values never enter the plan's persistent literals.
class MetadataPlan {
  final Map<String, String> literals;
  final MetadataReferences references;
  MetadataPlan(Map<String, String> values, this.references)
    : literals = Map.unmodifiable({
        for (final e in values.entries)
          if (!references.headers.containsKey(e.key.toLowerCase()))
            e.key.toLowerCase(): e.value,
      });

  factory MetadataPlan.rpc(
    Map<String, Object?> server,
    String request,
    MetadataReferences overrides,
  ) {
    final values = parseLiteralMetadata(request);
    final refs = {
      ...MetadataReferences.decode(server['metadataReferencesJson'] as String?)
          .headers,
    }..removeWhere((key, _) => values.keys.any((k) => k.toLowerCase() == key));
    return MetadataPlan({
      ...parseLiteralMetadata(server['metadataJson'] as String? ?? '{}'),
      ...{for (final e in values.entries) e.key.toLowerCase(): e.value},
    }, MetadataReferences({...refs, ...overrides.headers}));
  }
  factory MetadataPlan.reflection(Map<String, Object?> server) {
    final text = (server['reflectionMetadataJson'] as String? ?? '').trim();
    return MetadataPlan(
      parseLiteralMetadata(
        text.isEmpty ? server['metadataJson'] as String? ?? '{}' : text,
      ),
      MetadataReferences({
        if (text.isEmpty)
          ...MetadataReferences.decode(
            server['metadataReferencesJson'] as String?,
          ).headers,
        ...MetadataReferences.decode(
          server['reflectionMetadataReferencesJson'] as String?,
        ).headers,
      }),
    );
  }
  Future<Map<String, String>> resolve(
    CredentialService service,
    CredentialScope scope,
  ) => references.resolve(literals, service, scope);
}

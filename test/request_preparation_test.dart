import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:protodesk/src/workflow/preparation.dart';
import 'package:protodesk/src/security/credentials.dart';

PreparationProfiles profiles({
  Map<String, Object?> values = const {},
  List<Map<String, Object?>> presets = const [],
}) => PreparationProfiles({
  'version': 1,
  'environments': [
    {
      'id': 'dev',
      'name': 'Development',
      'variables': {
        for (final entry in values.entries)
          entry.key: {'bound': true, 'value': entry.value},
      },
    },
  ],
  'presets': presets,
});
Map<String, Object?> preset(
  String id,
  Map<String, String> metadata, [
  Map<String, String?> refs = const {},
]) => {
  'id': id,
  'name': id,
  'metadata': metadata,
  'references': MetadataReferences(refs).encode(),
};
PreparedRequest prepare(
  PreparationProfiles config,
  String body, {
  String metadata = '{}',
  List<String> selected = const [],
  MetadataReferences? refs,
}) => prepareRequest(
  profiles: config,
  body: body,
  metadata: metadata,
  references: refs ?? MetadataReferences({}),
  environmentId: 'dev',
  presetIds: selected,
);
void main() {
  test('typed variables preserve null, optional empty strings, false, zero and nested presence', () {
    final config = profiles(
      values: {
        'empty': '',
        'nil': null,
        'zero': 0,
        'falseValue': false,
        'nested': {'child': {}, 'items': []},
        'unicode': "it's 日本語 \\n \\",
      },
    );
    final result = prepare(
      config,
      r'{"optional":"${empty}","value":"${nil}","count":"${zero}","enabled":"${falseValue}","nested":"${nested}","text":"prefix ${unicode}"}',
    );
    final body = jsonDecode(result.body) as Map;
    expect(body['optional'], '');
    expect(body.containsKey('value'), true);
    expect(body['value'], isNull);
    expect(body['count'], 0);
    expect(body['enabled'], false);
    expect(body['nested'], {'child': {}, 'items': []});
    expect(
      body['text'],
      'prefix ${config.environments.single['variables'] is Map ? (config.environments.single['variables'] as Map)['unicode']['value'] : ''}',
    );
    expect(prepare(config, r'"${nil}"').body, 'null');
  });
  test('escape and single-pass substitution never interpolate keys or execute code', () {
    final config = profiles(
      values: {
        'name': r'$(touch /tmp/never-execute) `literal` ${other}',
        'obj': {'text': r'${other}'},
      },
    );
    final body = jsonDecode(
      prepare(
        config,
        r'{"${name}":"$${name}","text":"${name}","object":"${obj}","escaped":"$${not-valid}"}',
      ).body,
    ) as Map;
    expect(body.keys.first, r'${name}');
    expect(body[r'${name}'], r'${name}');
    expect(body['text'], r'$(touch /tmp/never-execute) `literal` ${other}');
    expect(body['object'], {'text': r'${other}'});
    expect(body['escaped'], r'${not-valid}');
  });
  test('unbound differs from explicit null and malformed placeholders fail without payload disclosure', () {
    final config = PreparationProfiles({
      'version': 1,
      'environments': [
        {
          'id': 'dev',
          'name': 'Dev',
          'variables': {
            'unbound': {'bound': false},
            'nil': {'bound': true, 'value': null},
          },
        },
      ],
      'presets': [],
    });
    expect(prepare(config, r'"${nil}"').body, 'null');
    for (final body in [
      r'"${unbound}"',
      r'"${missing}"',
      r'"${bad-name}"',
      r'"${unfinished"',
      'secret invalid json',
    ]) {
      expect(() => prepare(config, body), throwsA(isA<PreparationFailure>()));
    }
    try {
      prepare(config, 'secret invalid json');
    } catch (e) {
      expect(e.toString(), isNot(contains('secret invalid json')));
    }
    expect(
      () => PreparationProfiles({
        'version': 1,
        'environments': [
          {
            'id': 'dev',
            'name': 'Dev',
            'variables': {
              'nil': {'bound': true},
            },
          },
        ],
        'presets': [],
      }),
      throwsA(isA<PreparationFailure>()),
    );
  });
  test('ordered presets and existing literal/protected overrides resolve before variable lookup', () {
    const id = '12345678-1234-4234-8234-123456789abc';
    final config = profiles(
      values: {'name': 'resolved'},
      presets: [
        preset(
          'base',
          {'Authorization': r'${unused}', 'x-test': 'first'},
          {'authorization': id},
        ),
        preset('later', {'x-test': r'${name}', 'x-empty': ''}),
      ],
    );
    final result = prepare(
      config,
      '{}',
      metadata: '{"authorization":"request literal","x-test":"request wins"}',
      selected: ['base', 'later'],
      refs: MetadataReferences({'x-empty': id}),
    );
    expect(result.metadata, {
      'authorization': 'request literal',
      'x-test': 'request wins',
    });
    expect(result.references.headers, {'x-empty': id});
    final inherited = prepare(config, '{}', selected: ['base', 'later']);
    expect(inherited.metadata, {'x-test': 'resolved', 'x-empty': ''});
    expect(inherited.references.headers, {'authorization': id});
  });
  test('safe definitions export never includes literal values and marks variables/headers unbound', () {
    final config = profiles(
      values: {'token': 'synthetic-secret', 'nil': null},
      presets: [
        preset('auth', {'authorization': 'literal-secret', 'x-empty': ''}),
      ],
    );
    final safe = config.safeExport();
    expect(safe, isNot(contains('synthetic-secret')));
    expect(safe, isNot(contains('literal-secret')));
    final restored = PreparationProfiles.decode(safe);
    expect((restored.environments.single['variables'] as Map)['nil'], {
      'bound': false,
    });
    expect(
      MetadataReferences.decode(restored.presets.single['references'] as String)
          .headers,
      {'authorization': null, 'x-empty': null},
    );
    expect(
      PreparationProfiles.decode(config.encode()).encode(),
      config.encode(),
    );
  });
  test('oversized expansion is rejected before constructing a huge result', () {
    final config = profiles(values: {'large': 'x' * (2 * 1024 * 1024)});
    expect(
      () => prepare(config, jsonEncode(List.filled(40, r'${large}'))),
      throwsA(isA<PreparationFailure>()),
    );
    expect(
      () => prepare(config, jsonEncode(r'${large}' * 40)),
      throwsA(isA<PreparationFailure>()),
    );
    expect(
      () =>
          prepare(config, '{}', metadata: jsonEncode({'x-large': r'${large}'})),
      throwsA(isA<PreparationFailure>()),
    );
  });
  test('unknown versions/fields, ambiguous names, duplicate headers and overdeep values are not discarded', () {
    for (final data in [
      {'version': 2, 'environments': [], 'presets': []},
      {'version': 1, 'environments': [], 'presets': [], 'future': 'preserve'},
      {
        'version': 1,
        'environments': [],
        'presets': [
          preset('p', {'X-Key': 'one', 'x-key': 'two'}),
        ],
      },
    ]) {
      expect(
        () => PreparationProfiles(data),
        throwsA(isA<PreparationFailure>()),
      );
    }
    Object? nested;
    for (var i = 0; i < 66; i++) {
      nested = {'child': nested};
    }
    expect(
      () => profiles(values: {'deep': nested}),
      throwsA(isA<PreparationFailure>()),
    );
    final config = profiles(values: {'object': {}});
    expect(
      () => prepare(config, r'"prefix ${object}"'),
      throwsA(isA<PreparationFailure>()),
    );
  });
}

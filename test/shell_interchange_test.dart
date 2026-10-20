import 'package:flutter_test/flutter_test.dart';
import 'package:protodesk/src/interchange/shell.dart';
import 'package:protodesk/src/endpoint.dart';

void main() {
  for (final shell in CommandShell.values) {
    test('$shell quotes round-trip every literal without expansion', () {
      for (final value in [
        '',
        'plain',
        "apostrophe's",
        'double"quote',
        r'$(touch /tmp/never) ${TOKEN} `literal`',
        'line\nnext\r\ttab',
        r'C:\Program Files\proto\',
        '日本語 🚀',
        '; & | > < # * ?',
      ]) {
        expect(
          literalCommand('grpcurl ${quoteArgument(value, shell)}', shell),
          ['grpcurl', value],
        );
      }
    });
    test('$shell rejects shell execution and unsupported expansions', () {
      for (final command in [
        'grpcurl x; echo bad',
        'grpcurl x | other',
        r'grpcurl $TOKEN x',
        if (shell == CommandShell.posix) 'grpcurl `other` x',
        'grpcurl x > output',
        'grpcurl *.proto x',
        'grpcurl file[ab].proto x',
        'grpcurl {a,b}.proto x',
        'grpcurl x\nother y',
        'grpcurl "unterminated',
      ]) {
        expect(
          () => literalCommand(command, shell),
          throwsA(isA<CommandSyntax>()),
          reason: command,
        );
      }
    });
  }
  test('POSIX quote concatenation, escapes and explicit continuations', () {
    expect(
      literalCommand(
        "# preview\ngrpcurl -d '{\"text\":\"a'\"'\"'b\"}' \\\n 'localhost:50051' 'example.Echo/Call' # trailing",
        CommandShell.posix,
      ),
      [
        'grpcurl',
        '-d',
        '{"text":"a\'b"}',
        'localhost:50051',
        'example.Echo/Call',
      ],
    );
    expect(literalCommand(r'grpcurl "literal\q \$value"', CommandShell.posix), [
      'grpcurl',
      r'literal\q $value',
    ]);
  });
  test('PowerShell quote escapes, Windows paths and continuations', () {
    expect(
      literalCommand(
        "grpcurl -proto 'C:\\Proto files\\a.proto' `\r\n -d '{\"text\":\"it''s literal\"}' endpoint method",
        CommandShell.powershell,
      ),
      [
        'grpcurl',
        '-proto',
        r'C:\Proto files\a.proto',
        '-d',
        '{"text":"it\'s literal"}',
        'endpoint',
        'method',
      ],
    );
  });
  test(
    'PowerShell control escapes are preserved and Unicode expressions rejected',
    () {
      expect(
        literalCommand(r'grpcurl "`a`b`e`f`v`n`r`t"', CommandShell.powershell),
        ['grpcurl', '\u0007\b\u001b\f\u000b\n\r\t'],
      );
      expect(
        () => literalCommand(r'grpcurl "`u{1F680}"', CommandShell.powershell),
        throwsA(isA<CommandSyntax>()),
      );
    },
  );
  test('explicit ports survive URI normalization in transport and credential paths', () {
    expect(parseServerAddress('example.com:80'), ('example.com', 80));
    expect(parseServerAddress('example.com:443'), ('example.com', 443));
    expect(grpcAuthority('::1', 443), '[::1]');
    for (final value in [
      'example.com',
      'user:password@example.com:80',
      'example.com:80?q=x',
      'example.com:80/path',
      'example.com:80#fragment',
      'http://example.com:80',
      'example.com:0',
      'example.com:65536',
      'example.com:abc',
    ]) {
      expect(() => parseServerAddress(value), throwsFormatException);
    }
  });
}

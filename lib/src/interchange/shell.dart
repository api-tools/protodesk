import 'dart:convert';

/// A literal-only shell subset for command interchange, never a shell runner.
/// Expansions, operators and additional commands are rejected outside quotes.
enum CommandShell { posix, powershell }

class CommandSyntax implements Exception {
  final String message;
  const CommandSyntax(this.message);
  @override
  String toString() => 'Command: $message';
}

String quoteArgument(String value, CommandShell shell) {
  if (value.contains('\u0000')) {
    throw const CommandSyntax('NUL characters are unsupported.');
  }
  return shell == CommandShell.posix
      ? "'${value.replaceAll("'", "'\"'\"'")}'"
      : "'${value.replaceAll("'", "''")}'";
}

List<String> literalCommand(String input, CommandShell shell) {
  if (input.length > 4 * 1024 * 1024 ||
      input.contains('\u0000') ||
      utf8.encode(input).length > 4 * 1024 * 1024) {
    throw const CommandSyntax('Command exceeds limits or contains NUL.');
  }
  final tokens = <String>[];
  var token = StringBuffer();
  var active = false;
  String? quote;
  var endedLine = false;
  void finish() {
    if (active) {
      tokens.add(token.toString());
      if (tokens.length > 4096) {
        throw const CommandSyntax('Too many command arguments.');
      }
      token = StringBuffer();
      active = false;
    }
  }

  for (var i = 0; i < input.length; i++) {
    final c = input[i];
    if (quote == "'") {
      if (c == "'") {
        if (shell == CommandShell.powershell &&
            i + 1 < input.length &&
            input[i + 1] == "'") {
          token.write("'");
          i++;
        } else {
          quote = null;
        }
      } else {
        token.write(c);
      }
      continue;
    }
    if (quote == '"') {
      if (c == '"') {
        quote = null;
        continue;
      }
      if (c == r'$' || (shell == CommandShell.posix && c == '`')) {
        throw const CommandSyntax(
          'Variable/command expansion is unsupported. Use literal values in single quotes.',
        );
      }
      final escape = shell == CommandShell.posix ? r'\' : '`';
      if (c == escape) {
        if (++i == input.length) {
          throw const CommandSyntax('Incomplete quoted escape.');
        }
        final next = input[i];
        if (next == '\n') continue;
        if (next == '\r' && i + 1 < input.length && input[i + 1] == '\n') {
          i++;
          continue;
        }
        if (shell == CommandShell.posix &&
            !['"', r'$', '`', r'\'].contains(next)) {
          token.write(r'\');
        }
        token.write(
          shell == CommandShell.powershell
              ? switch (next) {
                  'a' => '\u0007',
                  'b' => '\b',
                  'e' => '\u001b',
                  'f' => '\f',
                  'v' => '\u000b',
                  'u' => throw const CommandSyntax(
                    'PowerShell Unicode escape expressions are unsupported. Paste literal Unicode.',
                  ),
                  'n' => '\n',
                  'r' => '\r',
                  't' => '\t',
                  '0' => throw const CommandSyntax(
                    'NUL escapes are unsupported.',
                  ),
                  _ => next,
                }
              : next,
        );
      } else {
        token.write(c);
      }
      continue;
    }
    if (c == '\n' || c == '\r') {
      finish();
      if (tokens.isNotEmpty) endedLine = true;
      continue;
    }
    if (c == ' ' || c == '\t') {
      finish();
      continue;
    }
    if (c == '#' && !active) {
      while (i + 1 < input.length && input[i + 1] != '\n') {
        i++;
      }
      continue;
    }
    if (endedLine) {
      throw const CommandSyntax(
        'Only one command is supported. Use an escaped line continuation.',
      );
    }
    if (shell == CommandShell.powershell && (c == '{' || c == '}')) {
      throw const CommandSyntax(
        'PowerShell script blocks are unsupported. Single-quote JSON data.',
      );
    }
    if (c == '~' && !active) {
      throw const CommandSyntax(
        'Home-directory expansion is unsupported. Use a literal absolute path.',
      );
    }
    if (c == "'" || c == '"') {
      if (shell == CommandShell.powershell && tokens.isEmpty && !active) {
        throw const CommandSyntax(
          'Use a bare grpcurl command name in PowerShell. Invocation expressions are unsupported.',
        );
      }
      quote = c;
      active = true;
      continue;
    }
    final escape = shell == CommandShell.posix ? r'\' : '`';
    if (c == escape) {
      if (++i == input.length) throw const CommandSyntax('Incomplete escape.');
      if (input[i] == '\n') continue;
      if (input[i] == '\r' && i + 1 < input.length && input[i + 1] == '\n') {
        i++;
        continue;
      }
      token.write(input[i]);
      active = true;
      continue;
    }
    if (r'$`;&|<>()*?[]{}'.contains(c)) {
      throw const CommandSyntax(
        'Shell operators, expansions and globs are unsupported. Quote literal data.',
      );
    }
    token.write(c);
    active = true;
  }
  if (quote != null) throw const CommandSyntax('Unclosed quote.');
  finish();
  return tokens;
}

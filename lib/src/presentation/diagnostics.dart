import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../transport/diagnostics.dart';
import 'controller.dart';
import 'design.dart';

Future<void> showCallDiagnostics(BuildContext context, DeskController desk) =>
    showDialog<void>(context: context, builder: (_) => _Diagnostics(desk));

class _Diagnostics extends StatefulWidget {
  final DeskController desk;
  const _Diagnostics(this.desk);
  @override
  State<_Diagnostics> createState() => _DiagnosticsState();
}

class _DiagnosticsState extends State<_Diagnostics> {
  bool includeDetails = false;
  CallDiagnostics? previousTrace;
  static const pretty = JsonEncoder.withIndent('  ');
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.desk,
    builder: (context, _) {
      final trace = widget.desk.diagnostics;
      if (!identical(trace, previousTrace)) {
        previousTrace = trace;
        includeDetails = false;
      }
      final details = includeDetails
          ? structuredStatus(
              widget.desk.result?.trailers ?? {},
              widget.desk.schema,
            )
          : null;
      return AlertDialog(
        title: const Text('Call diagnostics'),
        content: SizedBox(
          width: min(760, MediaQuery.sizeOf(context).width - 96),
          height: min(520, MediaQuery.sizeOf(context).height - 190),
          child: trace == null
              ? const Text(
                  'Invoke a request to capture call diagnostics.',
                  style: DeskType.secondary,
                )
              : ListView(
                  children: [
                    Text(
                      '${trace.code ?? 'IN_PROGRESS'} · ${(trace.elapsedUs / 1000).toStringAsFixed(2)} ms total',
                      style: DeskType.body,
                    ),
                    Text(
                      'First response: ${trace.firstResponseUs == null ? 'none' : '${(trace.firstResponseUs! / 1000).toStringAsFixed(2)} ms'}',
                      style: DeskType.body,
                    ),
                    Text(
                      'Sent ${trace.sentMessages} messages / ${trace.sentBytes} B · Received ${trace.receivedMessages} messages / ${trace.receivedBytes} B',
                      style: DeskType.body,
                    ),
                    const SizedBox(height: DeskSpace.small),
                    const Text(
                      'Serialized protobuf observed at the gRPC runtime boundary. Excludes framing, compression, TLS and network overhead; sent events do not prove server receipt. Half-close/cancel events record requests, not server acknowledgement.',
                      style: DeskType.secondary,
                    ),
                    if (trace.droppedEvents > 0)
                      Text(
                        '${trace.droppedEvents} timeline events omitted by the ${CallDiagnostics.eventLimit}-event limit; counters retain all observed messages.',
                        style: DeskType.secondary,
                      ),
                    const SizedBox(height: DeskSpace.inset),
                    for (final event in trace.events)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: SelectableText(
                          '${event.timestamp.toIso8601String()}  +${(event.elapsedUs / 1000).toStringAsFixed(2)} ms  ${event.kind}${event.protobufBytes == null ? '' : '  ${event.protobufBytes} B'}',
                          style: DeskType.code,
                        ),
                      ),
                    const Divider(),
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: const Text(
                        'Include structured status details (may contain sensitive server data)',
                        style: DeskType.body,
                      ),
                      value: includeDetails,
                      onChanged: (value) =>
                          setState(() => includeDetails = value!),
                    ),
                    if (details != null)
                      SelectableText(
                        pretty.convert(details),
                        style: DeskType.code,
                      ),
                  ],
                ),
        ),
        actions: [
          TextButton(
            onPressed: trace == null
                ? null
                : () => Clipboard.setData(
                    ClipboardData(
                      text: pretty.convert({
                        ...trace.toJson(),
                        'structuredStatus': ?details,
                      }),
                    ),
                  ),
            child: Text(
              includeDetails
                  ? 'Copy including details'
                  : 'Copy payload-free diagnostics',
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      );
    },
  );
}

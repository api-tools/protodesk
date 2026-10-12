import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../transport/engine.dart';
import 'controller.dart';
import 'design.dart';

class CallStatusBar extends StatefulWidget {
  final DeskController desk;
  final VoidCallback onMetadata;
  const CallStatusBar({
    super.key,
    required this.desk,
    required this.onMetadata,
  });
  @override
  State<CallStatusBar> createState() => _CallStatusBarState();
}

class _CallStatusBarState extends State<CallStatusBar> {
  Timer? clock;
  @override
  void initState() {
    super.initState();
    clock = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (mounted && widget.desk.invoking) setState(() {});
    });
  }

  @override
  void dispose() {
    clock?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final desk = widget.desk;
    final result = desk.result;
    final count =
        '${desk.messages.length} ${desk.messages.length == 1 ? 'message' : 'messages'}';
    final prefix = result == null
        ? ''
        : '${result.code} · ${result.durationMs} ms';
    final status = desk.invoking
        ? '${desk.method?.clientStreaming == true
              ? 'Client stream · ${desk.sentRequests.length} sent · ${desk.sendingFinished ? 'send closed' : 'send open'}'
              : desk.method?.serverStreaming == true
              ? 'Live stream'
              : 'Calling'} · ${desk.callClock.elapsedMilliseconds} ms · $count'
        : result != null
        ? desk.status.startsWith(prefix)
              ? desk.status.replaceFirst(prefix, '$prefix · $count')
              : '${desk.status} · Last call: $prefix · $count'
        : desk.status;
    return SizedBox(
      height: DeskSpace.control + DeskSpace.gap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: DeskSpace.panel),
        child: Row(
          children: [
            if (desk.invoking)
              const SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              Icon(
                desk.connected ? Icons.circle : Icons.circle_outlined,
                size: 8,
                color: desk.connected ? const Color(0xff55d6b0) : Colors.grey,
              ),
            const SizedBox(width: DeskSpace.gap),
            Expanded(
              child: Tooltip(
                message: '${desk.status}\n$status',
                child: Text(
                  status,
                  key: const ValueKey('call-status'),
                  style: DeskType.secondary,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            TextButton.icon(
              onPressed: widget.onMetadata,
              icon: const Icon(Icons.info_outline, size: 16),
              label: const Text('Headers / trailers'),
            ),
            const SizedBox(width: DeskSpace.gap),
            Text(
              '${desk.schema.services.length} services · ${desk.schema.methods.length} methods',
              style: DeskType.secondary.copyWith(color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> showResponseMetadata(BuildContext context, CallResult? result) =>
    showDialog<void>(
      context: context,
      builder: (context) {
        Widget section(String title, Map<String, String> values) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text(title, style: DeskType.heading)),
                IconButton(
                  tooltip: 'Copy $title',
                  onPressed: () => Clipboard.setData(
                    ClipboardData(text: pretty.convert(values)),
                  ),
                  icon: const Icon(Icons.copy, size: 16),
                ),
              ],
            ),
            SelectableText(
              values.isEmpty
                  ? 'No ${title.toLowerCase()} received.'
                  : pretty.convert(values),
              style: values.isEmpty
                  ? DeskType.secondary.copyWith(color: Colors.grey)
                  : DeskType.code,
            ),
          ],
        );
        return AlertDialog(
          title: const Text('Response metadata'),
          content: SizedBox(
            width: min(640, MediaQuery.sizeOf(context).width - 120),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: min(420, MediaQuery.sizeOf(context).height - 200),
              ),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    section('Headers', result?.headers ?? {}),
                    const SizedBox(height: DeskSpace.panel),
                    const Divider(height: DeskSpace.gap),
                    section('Trailers', result?.trailers ?? {}),
                  ],
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Clipboard.setData(
                ClipboardData(
                  text: pretty.convert({
                    'headers': result?.headers ?? {},
                    'trailers': result?.trailers ?? {},
                  }),
                ),
              ),
              child: const Text('Copy all'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );

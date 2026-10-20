import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../build_info.dart';
import '../distribution/releases.dart';
import 'design.dart';

class ReleaseAvailability extends StatefulWidget {
  final String currentVersion;
  final ReleaseCheck Function()? checkFactory;
  final Future<bool> Function(Uri)? openLink;
  const ReleaseAvailability({
    super.key,
    this.currentVersion = applicationVersion,
    this.checkFactory,
    this.openLink,
  });
  @override
  State<ReleaseAvailability> createState() => _ReleaseAvailabilityState();
}

class _ReleaseAvailabilityState extends State<ReleaseAvailability> {
  ReleaseCheck? active;
  OfficialRelease? release;
  String message = '';
  int generation = 0;
  @override
  void dispose() {
    generation++;
    active?.cancel();
    super.dispose();
  }

  Future<void> check() async {
    final current = ++generation;
    final operation = widget.checkFactory?.call() ?? ReleaseCheck();
    setState(() {
      active = operation;
      release = null;
      message = '';
    });
    try {
      final result = await operation.run();
      if (!mounted || current != generation) return;
      final installed = ReleaseVersion.parse(widget.currentVersion);
      setState(() {
        release = result;
        message = installed == null
            ? 'Development version cannot be compared with stable releases.'
            : result.version.compareTo(installed) > 0
            ? 'A newer stable release is available.'
            : result.version.compareTo(installed) == 0
            ? 'You are using the latest stable release.'
            : 'This build is newer than the latest stable release.';
      });
    } catch (e) {
      if (mounted && current == generation) {
        setState(
          () => message = e is ReleaseCheckFailure
              ? e.message
              : 'Release check failed. Try again later.',
        );
      }
    } finally {
      if (mounted && current == generation) setState(() => active = null);
    }
  }

  void cancel() {
    generation++;
    active?.cancel();
    setState(() {
      active = null;
      message = 'Release check cancelled.';
    });
  }

  Future<void> open(Uri url) async {
    if (release?.permits(url) != true) return;
    try {
      final success =
          await (widget.openLink?.call(url) ??
              launchUrl(url, mode: LaunchMode.externalApplication));
      if (mounted && !success) {
        setState(
          () => message =
              'Could not open the browser. Copy the official link below.',
        );
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => message =
              'Could not open the browser. Copy the official link below.',
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final result = release;
    return SizedBox(
      width: 520,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: DeskSpace.inset),
          const Text(
            'Check manually for stable GitHub releases. No background checks or automatic installation.',
            style: DeskType.secondary,
          ),
          const SizedBox(height: DeskSpace.gap),
          Wrap(
            spacing: DeskSpace.gap,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              TextButton.icon(
                onPressed: active == null ? check : null,
                icon: const Icon(Icons.refresh, size: 18),
                label: Text(active == null ? 'Check for updates' : 'Checking…'),
              ),
              if (active != null)
                TextButton(
                  onPressed: cancel,
                  child: const Text('Cancel check'),
                ),
            ],
          ),
          if (message.isNotEmpty) Text(message, style: DeskType.body),
          if (result != null) ...[
            const SizedBox(height: DeskSpace.gap),
            Text('Latest stable: ${result.tag}', style: DeskType.heading),
            const Text('Release notes (plain text)', style: DeskType.label),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 160),
              child: SingleChildScrollView(
                child: SelectableText(
                  result.notes.isEmpty
                      ? 'No release notes provided.'
                      : result.notes,
                  style: DeskType.body,
                ),
              ),
            ),
            const SizedBox(height: DeskSpace.gap),
            Wrap(
              spacing: DeskSpace.gap,
              children: [
                TextButton(
                  onPressed: () => open(result.page),
                  child: const Text('Official release page'),
                ),
                for (final entry in result.downloads.entries)
                  TextButton(
                    onPressed: () => open(entry.value),
                    child: Text(switch (entry.key) {
                      'ProtoDesk-macos-universal.zip' => 'macOS download',
                      'ProtoDesk-windows-x64.zip' =>
                        'Windows download (unsigned)',
                      'ProtoDesk-linux-x64.tar.gz' => 'Linux download',
                      _ => 'Checksums',
                    }),
                  ),
                TextButton(
                  onPressed: () => Clipboard.setData(
                    ClipboardData(text: result.page.toString()),
                  ),
                  child: const Text('Copy official link'),
                ),
              ],
            ),
            SelectableText(result.page.toString(), style: DeskType.secondary),
            const Text(
              'Links open your browser. Verify release checksums and platform signing before installation.',
              style: DeskType.secondary,
            ),
          ],
        ],
      ),
    );
  }
}

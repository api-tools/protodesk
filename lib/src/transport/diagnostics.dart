import 'dart:convert';

import '../schema/codec.dart';
import '../schema/schema.dart';
import '../schema/wire.dart';

class CallEvent {
  final String kind;
  final DateTime timestamp;
  final int elapsedUs;
  final int? protobufBytes;
  const CallEvent(
    this.kind,
    this.timestamp,
    this.elapsedUs,
    this.protobufBytes,
  );
  Map<String, Object?> toJson() => {
    'event': kind,
    'timestampUtc': timestamp.toIso8601String(),
    'elapsedUs': elapsedUs,
    if (protobufBytes != null) 'protobufBytes': protobufBytes,
  };
}

/// Payload-free, bounded observation at the gRPC runtime boundary. Serialized
/// protobuf bytes exclude gRPC framing, compression, TLS and network overhead.
class CallDiagnostics {
  static const eventLimit = 2048;
  final DateTime startedAt = DateTime.now().toUtc();
  final Stopwatch _clock = Stopwatch()..start();
  final List<CallEvent> _events = [];
  int sentMessages = 0, receivedMessages = 0, sentBytes = 0, receivedBytes = 0;
  int droppedEvents = 0;
  int? firstResponseUs;
  String? code;
  bool _halfClosed = false, _cancelled = false;
  CallDiagnostics() {
    event('started');
  }
  List<CallEvent> get events => List.unmodifiable(_events);
  int get elapsedUs => _clock.elapsedMicroseconds;
  bool get completed => code != null;
  void event(String kind, [int? bytes]) {
    if (completed) return;
    if (kind == 'sent') {
      sentMessages++;
      sentBytes += bytes!;
    }
    if (kind == 'received') {
      receivedMessages++;
      receivedBytes += bytes!;
      firstResponseUs ??= elapsedUs;
    }
    if (kind == 'half_close_requested') {
      if (_halfClosed) return;
      _halfClosed = true;
    }
    if (kind == 'cancel_requested') {
      if (_cancelled) return;
      _cancelled = true;
    }
    final value = CallEvent(kind, DateTime.now().toUtc(), elapsedUs, bytes);
    // Keep the beginning/context and always retain the final terminal event.
    if (_events.length < eventLimit) {
      _events.add(value);
    } else {
      droppedEvents++;
      if (kind == 'completed') _events[_events.length - 1] = value;
    }
  }

  void complete(String status) {
    if (completed) return;
    event('completed');
    code = status;
    _clock.stop();
  }

  Map<String, Object?> toJson() => {
    'startedAtUtc': startedAt.toIso8601String(),
    'status': code ?? 'IN_PROGRESS',
    'durationUs': elapsedUs,
    'timeToFirstResponseUs': firstResponseUs,
    'sentMessages': sentMessages,
    'receivedMessages': receivedMessages,
    'sentProtobufBytes': sentBytes,
    'receivedProtobufBytes': receivedBytes,
    'byteMeaning': 'Serialized protobuf at the runtime boundary; excludes framing, compression, TLS and network overhead.',
    'droppedEvents': droppedEvents,
    'events': [for (final event in _events) event.toJson()],
  };
}

/// Decodes only locally known detail descriptors. Unknown/malformed Any values
/// retain their raw base64; this never fetches a descriptor or logs contents.
Map<String, Object?> structuredStatus(
  Map<String, String> trailers,
  SchemaRegistry schema,
) {
  final raw = trailers['grpc-status-details-bin'];
  if (raw == null) return {'state': 'No structured status trailer'};
  if (raw.length > 350000) {
    return {
      'state': 'Structured status exceeds the 256 KiB decoding limit; original trailer remains available in response metadata.',
    };
  }
  final result = <String, Object?>{'rawBase64': raw};
  if (!schema.messages.containsKey('google.rpc.Status')) {
    return {
      ...result,
      'state':
          'google.rpc.Status descriptor is unavailable; raw trailer preserved',
    };
  }
  try {
    final bytes = base64.decode(base64.normalize(raw));
    if (bytes.length > 256 * 1024) throw const FormatException();
    final status = WireReader(bytes).fields();
    final details = <Map<String, Object?>>[];
    for (final any in status.messages(3)) {
      if (details.length == 64) throw const FormatException();
      final url = any.text(1),
          value = (any[2]?.firstOrNull as List<int>?) ?? <int>[];
      final name = url.split('/').last;
      final detail = <String, Object?>{
        'typeUrl': url,
        'rawBase64': base64.encode(value),
      };
      if (schema.messages.containsKey(name)) {
        try {
          detail['decoded'] = ProtoCodec(schema).decode(name, value);
        } catch (_) {
          detail['state'] =
              'Known detail could not be decoded; raw bytes preserved';
        }
      } else {
        detail['state'] = 'Unknown detail descriptor; raw bytes preserved';
      }
      details.add(detail);
    }
    return {
      ...result,
      'code': status.integer(1),
      'message': status.text(2),
      'details': details,
    };
  } catch (_) {
    return {
      ...result,
      'state':
          'Malformed or oversized structured status; raw trailer preserved',
    };
  }
}

import 'dart:convert';
import 'dart:io';
import 'dart:async';

class LatencyStats {
  final double currentMs;
  final double minMs;
  final double maxMs;
  final double avgMs;
  final int    sampleCount;

  const LatencyStats({
    this.currentMs   = 0,
    this.minMs       = 0,
    this.maxMs       = 0,
    this.avgMs       = 0,
    this.sampleCount = 0,
  });
}

class UdpService {
  final String ip;
  final int sendPort;
  final int receivePort;
  final void Function(String message) onMessageReceived;
  final void Function(LatencyStats stats)? onLatencyUpdated;

  RawDatagramSocket? _socket;
  RawDatagramSocket? _receiveSocket;

  // ── Latency tracking ──────────────────────────────────────────
  static const int _maxSamples = 20;
  final List<double> _samples = [];

  LatencyStats _latency = const LatencyStats();
  LatencyStats get latency => _latency;

  UdpService({
    required this.ip,
    this.sendPort         = 5005,
    this.receivePort      = 5006,
    required this.onMessageReceived,
    this.onLatencyUpdated,
  });

  Future<void> start() async {
    _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    _receiveSocket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      receivePort,
    );

    _receiveSocket!.listen((event) {
      if (event == RawSocketEvent.read) {
        final datagram = _receiveSocket!.receive();
        if (datagram != null) {
          final message = utf8.decode(datagram.data).trim();
          _handleIncoming(message);
        }
      }
    });
  }

  void _handleIncoming(String message) {
    if (message.startsWith('PONG:')) {
      _processPong(message);
    } else {
      onMessageReceived(message);
    }
  }

  void _processPong(String message) {
    // Format: PONG:timestamp_ms
    final parts = message.split(':');
    if (parts.length < 2) { onMessageReceived('PONG'); return; }

    final sentTs = int.tryParse(parts[1]);
    if (sentTs == null) { onMessageReceived('PONG'); return; }

    final nowMs    = DateTime.now().millisecondsSinceEpoch;
    final rttMs    = (nowMs - sentTs).toDouble();
    final oneWayMs = rttMs / 2.0;

    // Tolak nilai tidak wajar
    if (oneWayMs < 0 || oneWayMs > 2000) {
      onMessageReceived('PONG');
      return;
    }

    _samples.add(oneWayMs);
    if (_samples.length > _maxSamples) _samples.removeAt(0);

    double sum = 0, min = _samples[0], max = _samples[0];
    for (final s in _samples) {
      sum += s;
      if (s < min) min = s;
      if (s > max) max = s;
    }

    _latency = LatencyStats(
      currentMs:   oneWayMs,
      minMs:       min,
      maxMs:       max,
      avgMs:       sum / _samples.length,
      sampleCount: _samples.length,
    );

    onLatencyUpdated?.call(_latency);
    onMessageReceived('PONG');
  }

  void send({
    required double pitch,
    required double roll,
    required double yaw,
    required bool   isSwing,
    required double peak,
  }) {
    final message =
        '${pitch.toStringAsFixed(2)},'
        '${roll.toStringAsFixed(2)},'
        '${yaw.toStringAsFixed(2)},'
        '${isSwing ? 1 : 0},'
        '${peak.toStringAsFixed(2)}';
    _sendRaw(message);
  }

  void sendPing() {
    final ts = DateTime.now().millisecondsSinceEpoch;
    _sendRaw('PING:$ts');
  }

  void sendCalibrate() => _sendRaw('CALIBRATE');

  void _sendRaw(String message) {
    try {
      _socket?.send(utf8.encode(message), InternetAddress(ip), sendPort);
    } catch (_) {}
  }

  void resetLatency() {
    _samples.clear();
    _latency = const LatencyStats();
  }

  void dispose() {
    _socket?.close();
    _receiveSocket?.close();
  }
}
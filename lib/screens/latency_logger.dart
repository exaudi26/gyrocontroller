import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import '../services/udp_service.dart';

// ============================================================
//  latency_logger.dart
//  Modul logging data latency UDP untuk pengujian Bab 4
//  Baseball Controller Skripsi
//
//  Output CSV: latency_logs/latency_{kondisi}_{timestamp}.csv
//  Kolom:
//    sample_index, timestamp_ms, rtt_ms, one_way_ms,
//    rolling_avg_ms, rolling_min_ms, rolling_max_ms,
//    std_dev_ms, jitter_ms, kondisi
//
//  Cara pakai:
//    1. Tambahkan LatencyLoggerScreen ke route aplikasi
//    2. Pilih kondisi jaringan & isi IP PC
//    3. Tekan MULAI → tunggu minimal 40 detik (window 20 sampel)
//    4. Tekan STOP & SIMPAN → salin CSV ke PC
// ============================================================

// ── CSV Row Model ─────────────────────────────────────────────
class _LatencyRow {
  final int    sampleIndex;
  final int    timestampMs;
  final double rttMs;
  final double oneWayMs;
  final double rollingAvgMs;
  final double rollingMinMs;
  final double rollingMaxMs;
  final double stdDevMs;
  final double jitterMs;   // |oneWay - prevOneWay|
  final String kondisi;

  _LatencyRow({
    required this.sampleIndex,
    required this.timestampMs,
    required this.rttMs,
    required this.oneWayMs,
    required this.rollingAvgMs,
    required this.rollingMinMs,
    required this.rollingMaxMs,
    required this.stdDevMs,
    required this.jitterMs,
    required this.kondisi,
  });

  String toCsv() =>
    '$sampleIndex,'
    '$timestampMs,'
    '${rttMs.toStringAsFixed(2)},'
    '${oneWayMs.toStringAsFixed(2)},'
    '${rollingAvgMs.toStringAsFixed(2)},'
    '${rollingMinMs.toStringAsFixed(2)},'
    '${rollingMaxMs.toStringAsFixed(2)},'
    '${stdDevMs.toStringAsFixed(4)},'
    '${jitterMs.toStringAsFixed(2)},'
    '$kondisi';

  static String header() =>
    'sample_index,'
    'timestamp_ms,'
    'rtt_ms,'
    'one_way_ms,'
    'rolling_avg_ms,'
    'rolling_min_ms,'
    'rolling_max_ms,'
    'std_dev_ms,'
    'jitter_ms,'
    'kondisi';
}

// ── Statistik Live ────────────────────────────────────────────
class _LiveStats {
  final int    count;
  final double avg;
  final double min;
  final double max;
  final double stdDev;
  final double lastJitter;

  const _LiveStats({
    this.count = 0,
    this.avg   = 0,
    this.min   = 0,
    this.max   = 0,
    this.stdDev = 0,
    this.lastJitter = 0,
  });
}

// ── Logger Screen ─────────────────────────────────────────────
class LatencyLoggerScreen extends StatefulWidget {
  const LatencyLoggerScreen({super.key});
  @override
  State<LatencyLoggerScreen> createState() => _LatencyLoggerScreenState();
}

class _LatencyLoggerScreenState extends State<LatencyLoggerScreen> {
  final _ipController   = TextEditingController(text: '192.168.1.5');
  final _portController = TextEditingController(text: '5005');

  static const int _windowSize = 20;
  static const int _pingIntervalMs = 500; // lebih rapat dari 2000ms untuk data yang lebih kaya

  final List<double> _window   = [];
  final List<_LatencyRow> _rows = [];

  UdpService? _udp;
  Timer?  _pingTimer;

  bool   _logging    = false;
  int    _sampleIdx  = 0;
  double _prevOneWay = -1;
  String _status     = 'Siap — isi IP & pilih kondisi';
  String _savedPath  = '';

  _LiveStats _stats = const _LiveStats();

  final _kondisiOptions = [
    'wifi_5ghz',
    'wifi_24ghz',
    'wifi_padat',
    'mobile_hotspot',
    'sinyal_lemah',
  ];
  String _kondisi = 'wifi_24ghz';

  // ── Kalkulasi statistik ─────────────────────────────────────
  _LiveStats _calcStats(List<double> window, double oneWay) {
    if (window.isEmpty) return const _LiveStats();
    final n   = window.length;
    final sum = window.reduce((a, b) => a + b);
    final avg = sum / n;
    final min = window.reduce((a, b) => a < b ? a : b);
    final max = window.reduce((a, b) => a > b ? a : b);

    final variance = window
        .map((x) => (x - avg) * (x - avg))
        .reduce((a, b) => a + b) / n;
    final stdDev = sqrt(variance);

    final jitter = _prevOneWay < 0 ? 0.0 : (oneWay - _prevOneWay).abs();

    return _LiveStats(
      count:       _sampleIdx,
      avg:         avg,
      min:         min,
      max:         max,
      stdDev:      stdDev,
      lastJitter:  jitter,
    );
  }

  // ── Koneksi & ping ─────────────────────────────────────────
  Future<void> _startLogging() async {
    final ip   = _ipController.text.trim();
    final port = int.tryParse(_portController.text) ?? 5005;
    if (ip.isEmpty) {
      setState(() => _status = '❌ IP tidak boleh kosong');
      return;
    }

    _rows.clear();
    _window.clear();
    _sampleIdx  = 0;
    _prevOneWay = -1;
    _savedPath  = '';
    _stats      = const _LiveStats();

    setState(() { _logging = true; _status = 'Menghubungkan ke $ip:$port...'; });

    _udp = UdpService(
      ip:          ip,
      sendPort:    port,
      receivePort: 5006,
      onMessageReceived: _handleMessage,
      onLatencyUpdated:  _handlePong,
    );

    try {
      await _udp!.start();
    } catch (e) {
      setState(() { _logging = false; _status = '❌ Gagal bind socket: $e'; });
      return;
    }

    // Kirim ping lebih rapat agar data lebih banyak
    _pingTimer = Timer.periodic(
      const Duration(milliseconds: _pingIntervalMs),
      (_) => _udp?.sendPing(),
    );

    setState(() => _status = 'Logging... tunggu minimal 40 detik untuk window penuh');
  }

  void _handleMessage(String msg) {
    // hanya dipakai untuk non-PONG; bisa diabaikan di logger
  }

  // Dipanggil setiap PONG diterima dari UdpService
  void _handlePong(LatencyStats ls) {
    if (!_logging) return;

    // UdpService sudah hitung one-way; kita butuh RTT → ×2
    final oneWayMs = ls.currentMs;
    final rttMs    = oneWayMs * 2;

    _window.add(oneWayMs);
    if (_window.length > _windowSize) _window.removeAt(0);

    final stats  = _calcStats(_window, oneWayMs);
    final jitter = _prevOneWay < 0 ? 0.0 : (oneWayMs - _prevOneWay).abs();

    final row = _LatencyRow(
      sampleIndex:  _sampleIdx,
      timestampMs:  DateTime.now().millisecondsSinceEpoch,
      rttMs:        rttMs,
      oneWayMs:     oneWayMs,
      rollingAvgMs: stats.avg,
      rollingMinMs: stats.min,
      rollingMaxMs: stats.max,
      stdDevMs:     stats.stdDev,
      jitterMs:     jitter,
      kondisi:      _kondisi,
    );

    _rows.add(row);
    _prevOneWay = oneWayMs;
    _sampleIdx++;

    if (mounted) setState(() {
      _stats  = stats;
      _status = 'Logging... $_sampleIdx sampel  '
                '(window: ${_window.length}/$_windowSize)';
    });
  }

  // ── Simpan CSV ──────────────────────────────────────────────
  Future<void> _stopAndSave() async {
    _pingTimer?.cancel();
    _udp?.dispose();
    _udp = null;

    setState(() { _logging = false; _status = 'Menyimpan...'; });

    if (_rows.isEmpty) {
      setState(() => _status = '⚠️ Tidak ada data — pastikan PC merespons PING.');
      return;
    }

    try {
      // MANAGE_EXTERNAL_STORAGE wajib untuk Android 11+ (API 30+)
      // agar bisa tulis ke /storage/emulated/0/Documents/
      final status = await Permission.manageExternalStorage.request();
      if (!status.isGranted) {
        setState(() => _status = '❌ Izin storage ditolak.\nBuka Pengaturan → Izin → File & Media → Izinkan.');
        return;
      }

      final logDir = Directory('/storage/emulated/0/Documents/latency_logs');
      if (!await logDir.exists()) await logDir.create(recursive: true);

      final ts    = DateTime.now().toIso8601String()
          .replaceAll(':', '-').substring(0, 19);
      final fname = 'latency_${_kondisi}_$ts.csv';
      final file  = File('${logDir.path}/$fname');

      final buf = StringBuffer()..writeln(_LatencyRow.header());
      for (final r in _rows) buf.writeln(r.toCsv());
      await file.writeAsString(buf.toString());

      setState(() {
        _savedPath = '${logDir.path}/$fname';
        _status    = '✅ Tersimpan: $fname\n(${_rows.length} baris)';
      });
    } catch (e) {
      setState(() => _status = '❌ Error simpan: $e');
    }
  }

  @override
  void dispose() {
    _pingTimer?.cancel();
    _udp?.dispose();
    _ipController.dispose();
    _portController.dispose();
    super.dispose();
  }

  // ── UI ──────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1A1A2E),
      appBar: AppBar(
        title: const Text('Latency Logger — UDP Test',
            style: TextStyle(color: Colors.white)),
        backgroundColor: const Color(0xFF2D2D44),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [

          // ── Konfigurasi ─────────────────────────────────────
          _sectionLabel('Konfigurasi'),
          const SizedBox(height: 8),
          TextField(
            controller: _ipController,
            enabled: !_logging,
            style: const TextStyle(color: Colors.white),
            decoration: _inp('IP Address PC'),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _portController,
            enabled: !_logging,
            keyboardType: TextInputType.number,
            style: const TextStyle(color: Colors.white),
            decoration: _inp('Port (default 5005)'),
          ),
          const SizedBox(height: 12),
          _sectionLabel('Kondisi Jaringan'),
          const SizedBox(height: 6),
          DropdownButtonFormField<String>(
            value: _kondisi,
            dropdownColor: const Color(0xFF2D2D44),
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              filled: true, fillColor: const Color(0xFF2D2D44),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
              enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: Colors.transparent)),
            ),
            items: _kondisiOptions.map((k) =>
                DropdownMenuItem(value: k, child: Text(k))).toList(),
            onChanged: _logging ? null : (v) => setState(() => _kondisi = v!),
          ),

          const SizedBox(height: 20),

          // ── Status ──────────────────────────────────────────
          _sectionLabel('Status'),
          const SizedBox(height: 6),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFF2D2D44),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: _logging
                    ? Colors.greenAccent.withOpacity(0.4)
                    : Colors.transparent,
              ),
            ),
            child: Text(_status,
                style: TextStyle(
                    color: _logging ? Colors.greenAccent : Colors.white70,
                    fontSize: 12)),
          ),

          const SizedBox(height: 14),

          // ── Live Statistik ───────────────────────────────────
          if (_sampleIdx > 0) ...[
            _sectionLabel('Live Statistik  (window ${_window.length}/$_windowSize sampel)'),
            const SizedBox(height: 8),
            Row(children: [
              _statBox('Avg',    '${_stats.avg.toStringAsFixed(1)} ms',     _colorAvg(_stats.avg)),
              const SizedBox(width: 8),
              _statBox('Min',    '${_stats.min.toStringAsFixed(1)} ms',     Colors.greenAccent),
              const SizedBox(width: 8),
              _statBox('Max',    '${_stats.max.toStringAsFixed(1)} ms',     Colors.redAccent),
              const SizedBox(width: 8),
              _statBox('StdDev', '${_stats.stdDev.toStringAsFixed(1)} ms',  Colors.white70),
            ]),
            const SizedBox(height: 8),
            Row(children: [
              _statBox('Jitter',  '${_stats.lastJitter.toStringAsFixed(1)} ms', Colors.orangeAccent),
              const SizedBox(width: 8),
              _statBox('Sampel',  '${_stats.count}',                             Colors.white60),
            ]),
            const SizedBox(height: 8),
            _latencyBar(_stats.avg),
            const SizedBox(height: 16),
          ],

          // ── Path tersimpan ──────────────────────────────────
          if (_savedPath.isNotEmpty) ...[
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                  color: Colors.green.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.greenAccent.withOpacity(0.3))),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('📁 File tersimpan:',
                    style: TextStyle(color: Colors.white54, fontSize: 11)),
                const SizedBox(height: 4),
                Text(_savedPath,
                    style: const TextStyle(color: Colors.white70, fontSize: 11)),
                const SizedBox(height: 4),
                const Text('→ Salin ke PC lalu jalankan analyze_latency.py',
                    style: TextStyle(color: Colors.greenAccent, fontSize: 11)),
              ]),
            ),
            const SizedBox(height: 14),
          ],

          // ── Tombol ──────────────────────────────────────────
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _logging ? _stopAndSave : _startLogging,
              style: ElevatedButton.styleFrom(
                backgroundColor: _logging ? Colors.redAccent : Colors.greenAccent,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              child: Text(
                _logging ? '⏹  STOP & SIMPAN' : '▶  MULAI LOGGING',
                style: const TextStyle(
                    color: Colors.black, fontWeight: FontWeight.bold, fontSize: 16),
              ),
            ),
          ),
          const SizedBox(height: 10),

          // ── Catatan kolom CSV ────────────────────────────────
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
                color: const Color(0xFF2D2D44),
                borderRadius: BorderRadius.circular(8)),
            child: const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Kolom CSV yang dihasilkan:',
                  style: TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.bold)),
              SizedBox(height: 6),
              Text(
                'sample_index  — urutan sampel\n'
                'timestamp_ms  — epoch millisecond saat PONG diterima\n'
                'rtt_ms        — round-trip time (one_way × 2)\n'
                'one_way_ms    — estimasi one-way (RTT ÷ 2)\n'
                'rolling_avg   — rata-rata sliding window 20 sampel\n'
                'rolling_min   — minimum dalam window\n'
                'rolling_max   — maksimum dalam window\n'
                'std_dev_ms    — standar deviasi dalam window\n'
                'jitter_ms     — |one_way[n] − one_way[n-1]|\n'
                'kondisi       — label kondisi jaringan sesi',
                style: TextStyle(color: Colors.white38, fontSize: 10, height: 1.7),
              ),
            ]),
          ),

          const SizedBox(height: 8),
          const Text(
            'Prosedur: Pastikan PC server sudah aktif → isi IP → pilih kondisi → MULAI.\n'
            'Tunggu minimal 40 detik (window penuh 20 sampel) sebelum STOP.',
            style: TextStyle(color: Colors.white30, fontSize: 10),
            textAlign: TextAlign.center,
          ),
        ]),
      ),
    );
  }

  // ── Helpers UI ───────────────────────────────────────────────
  Widget _sectionLabel(String text) => Text(text,
      style: const TextStyle(color: Colors.white54, fontSize: 12));

  Widget _statBox(String label, String value, Color color) => Expanded(
    child: Container(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
      decoration: BoxDecoration(
          color: const Color(0xFF2D2D44),
          borderRadius: BorderRadius.circular(8)),
      child: Column(children: [
        Text(label,
            style: const TextStyle(color: Colors.white38, fontSize: 10)),
        const SizedBox(height: 4),
        Text(value,
            style: TextStyle(
                color: color, fontSize: 14, fontWeight: FontWeight.bold)),
      ]),
    ),
  );

  Widget _latencyBar(double avg) {
    // Skala 0–300 ms; threshold hijau/oranye/merah
    final pct   = (avg / 300).clamp(0.0, 1.0);
    final color = _colorAvg(avg);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Text('0 ms', style: const TextStyle(color: Colors.white30, fontSize: 10)),
        Text('${avg.toStringAsFixed(1)} ms',
            style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.bold)),
        Text('300 ms', style: const TextStyle(color: Colors.white30, fontSize: 10)),
      ]),
      const SizedBox(height: 4),
      Stack(children: [
        Container(height: 8, decoration: BoxDecoration(
            color: Colors.white10,
            borderRadius: BorderRadius.circular(4))),
        FractionallySizedBox(widthFactor: pct,
          child: Container(height: 8, decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(4)))),
        // Threshold markers
        Positioned(left: MediaQuery.of(context).size.width * (50 / 300) * 0.85,
          child: Container(width: 1.5, height: 8, color: Colors.greenAccent.withOpacity(0.5))),
        Positioned(left: MediaQuery.of(context).size.width * (150 / 300) * 0.85,
          child: Container(width: 1.5, height: 8, color: Colors.orangeAccent.withOpacity(0.5))),
      ]),
      const SizedBox(height: 3),
      Row(children: [
        const Expanded(child: Text('Hijau <50 ms',
            style: TextStyle(color: Colors.greenAccent, fontSize: 9))),
        const Expanded(child: Text('Oranye 50–150 ms',
            style: TextStyle(color: Colors.orangeAccent, fontSize: 9), textAlign: TextAlign.center)),
        Expanded(child: Text('Merah >150 ms',
            style: const TextStyle(color: Colors.redAccent, fontSize: 9),
            textAlign: TextAlign.end)),
      ]),
    ]);
  }

  Color _colorAvg(double avg) {
    if (avg < 50)  return Colors.greenAccent;
    if (avg < 150) return Colors.orangeAccent;
    return Colors.redAccent;
  }

  InputDecoration _inp(String hint) => InputDecoration(
    hintText: hint,
    hintStyle: const TextStyle(color: Colors.grey),
    filled: true, fillColor: const Color(0xFF2D2D44),
    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
    enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: Colors.transparent)),
    disabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: Colors.transparent)),
  );
}
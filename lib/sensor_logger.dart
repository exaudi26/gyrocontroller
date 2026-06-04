import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:sensors_plus/sensors_plus.dart';

// ============================================================
//  sensor_logger.dart
//  Modul logging data IMU untuk pengujian Complementary Filter
//  Bab 4.2.1 — Baseball Controller Skripsi
//
//  Output CSV: sensor_logs/alpha{XX}_{label}_{timestamp}.csv
//  Kolom:
//    timestamp_ms, dt_ms,
//    ax, ay, az,
//    gx, gy, gz,
//    pitch_filtered, roll_filtered, yaw_filtered,
//    pitch_accel_ref, roll_accel_ref
//
//  Cara pakai:
//    1. Tambahkan SensorLoggerScreen ke route aplikasi
//    2. Buka layar logger, pilih alpha & label sesi
//    3. Tekan START → diamkan HP 60 detik → STOP
//    4. Salin file CSV dari Documents/sensor_logs/ ke PC
// ============================================================

// ── Internal Complementary Filter (duplikat agar standalone) ─
class _CF {
  final double alpha;
  double pitch = 0, roll = 0, yaw = 0;
  int _lastTs = 0;
  bool _first = true;
  static const double _r2d = 180.0 / pi;

  _CF(this.alpha);

  void update(List<double> a, List<double> g, int ts) {
    if (_first) {
      _first = false;
      _lastTs = ts;
      pitch = atan2(a[1], a[2]) * _r2d;
      roll  = atan2(-a[0], a[2]) * _r2d;
      return;
    }
    final dt = (ts - _lastTs) / 1e9;
    _lastTs = ts;
    if (dt <= 0 || dt > 0.5) return;

    final ap = atan2(a[1], a[2]) * _r2d;
    final ar = atan2(-a[0], a[2]) * _r2d;

    pitch = alpha * (pitch + g[0] * dt * _r2d) + (1 - alpha) * ap;
    roll  = alpha * (roll  + g[1] * dt * _r2d) + (1 - alpha) * ar;
    yaw  += g[2] * dt * _r2d;
    if (yaw >  180) yaw -= 360;
    if (yaw < -180) yaw += 360;
  }

  void reset() { pitch = roll = yaw = 0; _first = true; }
}

// ── CSV Row Model ─────────────────────────────────────────────
class _CsvRow {
  final int    timestampMs;
  final double dtMs;
  final double ax, ay, az;
  final double gx, gy, gz;
  final double pitchF, rollF, yawF;
  final double pitchAccel, rollAccel;

  _CsvRow({
    required this.timestampMs, required this.dtMs,
    required this.ax, required this.ay, required this.az,
    required this.gx, required this.gy, required this.gz,
    required this.pitchF, required this.rollF, required this.yawF,
    required this.pitchAccel, required this.rollAccel,
  });

  String toCsv() =>
    '$timestampMs,${dtMs.toStringAsFixed(2)},'
    '${ax.toStringAsFixed(5)},${ay.toStringAsFixed(5)},${az.toStringAsFixed(5)},'
    '${gx.toStringAsFixed(6)},${gy.toStringAsFixed(6)},${gz.toStringAsFixed(6)},'
    '${pitchF.toStringAsFixed(4)},${rollF.toStringAsFixed(4)},${yawF.toStringAsFixed(4)},'
    '${pitchAccel.toStringAsFixed(4)},${rollAccel.toStringAsFixed(4)}';

  static String header() =>
    'timestamp_ms,dt_ms,'
    'ax,ay,az,'
    'gx,gy,gz,'
    'pitch_filtered,roll_filtered,yaw_filtered,'
    'pitch_accel_ref,roll_accel_ref';
}

// ── Logger Screen ─────────────────────────────────────────────
class SensorLoggerScreen extends StatefulWidget {
  const SensorLoggerScreen({super.key});
  @override
  State<SensorLoggerScreen> createState() => _SensorLoggerScreenState();
}

class _SensorLoggerScreenState extends State<SensorLoggerScreen> {
  // Tiga filter sekaligus (satu sesi menghasilkan 3 file)
  final _filters = {
    '90': _CF(0.90),
    '95': _CF(0.95),
    '98': _CF(0.98),
  };

  // Buffer per alpha
  final _rows = {'90': <_CsvRow>[], '95': <_CsvRow>[], '98': <_CsvRow>[]};

  bool   _logging      = false;
  int    _elapsed      = 0;   // detik
  int    _rowCount     = 0;
  String _status       = 'Siap';
  String _sessionLabel = 'stationary_60s';
  String _savedPath    = '';

  Timer? _uiTimer;

  StreamSubscription? _accelSub;
  StreamSubscription? _gyroSub;

  List<double> _accel = [0, 0, 0];
  List<double> _gyro  = [0, 0, 0];
  int _lastTs = 0;

  final _labelOptions = [
    'stationary_60s',
    'stationary_30s',
    'slow_rotation',
    'fast_rotation',
    'swing_test',
  ];

  @override
  void initState() {
    super.initState();
    _accelSub = accelerometerEventStream().listen((e) => _accel = [e.x, e.y, e.z]);
    _gyroSub  = gyroscopeEventStream().listen((e) => _gyro  = [e.x, e.y, e.z]);
  }

  @override
  void dispose() {
    _accelSub?.cancel(); _gyroSub?.cancel();
    _uiTimer?.cancel();
    super.dispose();
  }

  void _startLogging() {
    for (final f in _filters.values) f.reset();
    for (final r in _rows.values)    r.clear();
    _rowCount = 0; _elapsed = 0; _savedPath = '';
    _lastTs   = 0;

    // Sampling setiap 100ms (10 Hz) sesuai prosedur bab 4.2.1
    // Ganti ke 20ms jika ingin 50 Hz
    const sampleMs = 100;

    _uiTimer = Timer.periodic(const Duration(milliseconds: sampleMs), (_) {
      _sample();
      if (mounted) setState(() {
        _elapsed  = (_rowCount * sampleMs) ~/ 1000;
        _status   = 'Logging... $_elapsed s  ($_rowCount baris)';
      });
    });

    setState(() { _logging = true; _status = 'Logging...'; });
  }

  void _sample() {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final dtMs  = _lastTs == 0 ? 0.0 : (nowMs - _lastTs).toDouble();
    _lastTs     = nowMs;

    // Timestamp dalam nanosecond (untuk _CF)
    final ts = nowMs * 1000000;

    // Referensi accel pitch/roll (raw, tanpa filter)
    final pitchAccel = atan2(_accel[1], _accel[2]) * (180.0 / pi);
    final rollAccel  = atan2(-_accel[0], _accel[2]) * (180.0 / pi);

    for (final entry in _filters.entries) {
      entry.value.update(_accel, _gyro, ts);
      _rows[entry.key]!.add(_CsvRow(
        timestampMs: nowMs,
        dtMs:        dtMs,
        ax: _accel[0], ay: _accel[1], az: _accel[2],
        gx: _gyro[0],  gy: _gyro[1],  gz: _gyro[2],
        pitchF:    entry.value.pitch,
        rollF:     entry.value.roll,
        yawF:      entry.value.yaw,
        pitchAccel: pitchAccel,
        rollAccel:  rollAccel,
      ));
    }
    _rowCount++;
  }

  Future<void> _stopAndSave() async {
    _uiTimer?.cancel();
    setState(() { _logging = false; _status = 'Menyimpan...'; });

    try {
      // Minta permission storage (wajib Android 10 ke bawah)
      // Android 11+: perlu MANAGE_EXTERNAL_STORAGE di manifest
      final status = await Permission.manageExternalStorage.request();
      if (!status.isGranted) {
        setState(() => _status = '❌ Permission storage ditolak.\nBuka Pengaturan → Izin → File & Media → Izinkan.');
        return;
      }

      final logDir = Directory('/storage/emulated/0/Documents/sensor_loggers');
      if (!await logDir.exists()) await logDir.create(recursive: true);

      final ts = DateTime.now().toIso8601String()
          .replaceAll(':', '-').substring(0, 19);

      final saved = <String>[];
      for (final entry in _rows.entries) {
        if (entry.value.isEmpty) continue;
        final fname = 'alpha${entry.key}_${_sessionLabel}_$ts.csv';
        final file  = File('${logDir.path}/$fname');
        final buf   = StringBuffer()..writeln(_CsvRow.header());
        for (final r in entry.value) buf.writeln(r.toCsv());
        await file.writeAsString(buf.toString());
        saved.add(fname);
      }

      setState(() {
        _savedPath = logDir.path;
        _status    = '✅ Tersimpan ${saved.length} file\n${logDir.path}';
      });
    } catch (e) {
      setState(() => _status = '❌ Error: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1A1A2E),
      appBar: AppBar(
        title: const Text('Sensor Logger — CF Test',
            style: TextStyle(color: Colors.white)),
        backgroundColor: const Color(0xFF2D2D44),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // Label sesi
          const Text('Label Sesi:', style: TextStyle(color: Colors.white70, fontSize: 13)),
          const SizedBox(height: 6),
          DropdownButtonFormField<String>(
            value: _sessionLabel,
            dropdownColor: const Color(0xFF2D2D44),
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              filled: true, fillColor: const Color(0xFF2D2D44),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
              enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: Colors.transparent)),
            ),
            items: _labelOptions.map((l) =>
                DropdownMenuItem(value: l, child: Text(l))).toList(),
            onChanged: _logging ? null : (v) => setState(() => _sessionLabel = v!),
          ),
          const SizedBox(height: 20),

          // Info alpha
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: const Color(0xFF2D2D44),
                borderRadius: BorderRadius.circular(10)),
            child: const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Alpha yang direkam sekaligus:', style: TextStyle(color: Colors.white70, fontSize: 12)),
              SizedBox(height: 6),
              Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
                _AlphaBadge('α = 0.90', Color(0xFFFF6B6B)),
                _AlphaBadge('α = 0.95', Color(0xFFFFE66D)),
                _AlphaBadge('α = 0.98', Color(0xFF4ECDC4)),
              ]),
            ]),
          ),
          const SizedBox(height: 20),

          // Status
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFF2D2D44),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                  color: _logging ? Colors.greenAccent.withOpacity(0.4) : Colors.transparent),
            ),
            child: Text(_status,
                style: TextStyle(
                    color: _logging ? Colors.greenAccent : Colors.white70,
                    fontSize: 13)),
          ),
          const SizedBox(height: 8),

          // Progress bar (60 detik)
          if (_logging) ...[
            LinearProgressIndicator(
              value: (_elapsed / 60).clamp(0.0, 1.0),
              backgroundColor: Colors.white12,
              valueColor: const AlwaysStoppedAnimation(Colors.greenAccent),
            ),
            const SizedBox(height: 4),
            Text('$_elapsed / 60 detik',
                style: const TextStyle(color: Colors.white38, fontSize: 11)),
          ],

          if (_savedPath.isNotEmpty) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                  color: Colors.green.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.greenAccent.withOpacity(0.3))),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('📁 Path file CSV:', style: TextStyle(color: Colors.white54, fontSize: 11)),
                const SizedBox(height: 4),
                Text(_savedPath, style: const TextStyle(color: Colors.white70, fontSize: 11)),
                const SizedBox(height: 4),
                const Text('→ Salin ke PC lalu jalankan analyze_complementary_filter.py',
                    style: TextStyle(color: Colors.greenAccent, fontSize: 11)),
              ]),
            ),
          ],

          const SizedBox(height: 24),

          // Tombol
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
                style: const TextStyle(color: Colors.black, fontWeight: FontWeight.bold, fontSize: 16),
              ),
            ),
          ),
          const SizedBox(height: 8),

          // Petunjuk
          const Text(
            'Prosedur: Letakkan HP diam di permukaan datar → MULAI → tunggu 60 detik → STOP.\n'
            'Satu sesi otomatis menghasilkan 3 file CSV (α=0.90, 0.95, 0.98).',
            style: TextStyle(color: Colors.white38, fontSize: 10),
            textAlign: TextAlign.center,
          ),
        ]),
      ),
    );
  }
}

class _AlphaBadge extends StatelessWidget {
  final String label;
  final Color  color;
  const _AlphaBadge(this.label, this.color);
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withOpacity(0.5))),
    child: Text(label, style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 13)),
  );
}
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:sensors_plus/sensors_plus.dart';
import '../services/complementary_filter.dart';
import '../services/swing_detector.dart';
import '../services/udp_service.dart';
import 'latency_logger.dart';
import '../sensor_logger.dart';

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});
  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  final _ipController   = TextEditingController(text: '192.168.1.5');
  final _portController = TextEditingController(text: '5005');

  final _filter   = ComplementaryFilter(alpha: 0.98);
  final _detector = SwingDetector(windowSize: 20);
  UdpService? _udp;

  bool   _isConnected     = false;
  bool   _isSwing         = false;
  double _pitch = 0, _roll = 0, _yaw = 0, _peak = 0;
  String _connectionText  = 'Belum Terhubung';
  Color  _connectionColor = Colors.redAccent;
  int    _lastPongTime    = 0;

  LatencyStats _latency = const LatencyStats();

  StreamSubscription? _accelSub;
  StreamSubscription? _gyroSub;
  Timer? _pingTimer;

  List<double> _accel = [0, 0, 0];
  List<double> _gyro  = [0, 0, 0];

  @override
  void initState() { super.initState(); _startSensors(); }

  void _startSensors() {
    _accelSub = accelerometerEventStream().listen((e) {
      _accel = [e.x, e.y, e.z];
      _processSensorData();
    });
    _gyroSub = gyroscopeEventStream().listen((e) {
      _gyro = [e.x, e.y, e.z];
    });
  }

  void _processSensorData() {
    final ts = DateTime.now().microsecondsSinceEpoch * 1000;
    _filter.update(accel: _accel, gyro: _gyro, timestamp: ts);
    final result = _detector.process(_accel);
    _udp?.send(pitch: _filter.pitch, roll: _filter.roll, yaw: _filter.yaw,
        isSwing: result.isSwing, peak: result.peak);
    if (mounted) setState(() {
      _pitch = _filter.pitch; _roll = _filter.roll;
      _yaw   = _filter.yaw;  _isSwing = result.isSwing; _peak = result.peak;
    });
  }

  Future<void> _connect() async {
    final ip = _ipController.text.trim();
    final port = int.tryParse(_portController.text) ?? 5005;
    if (ip.isEmpty) return;
    setState(() { _connectionText = 'Menghubungkan...'; _connectionColor = Colors.orange; });
    _udp = UdpService(
      ip: ip, sendPort: port, receivePort: 5006,
      onMessageReceived: _handleMessage,
      onLatencyUpdated:  (s) { if (mounted) setState(() => _latency = s); },
    );
    await _udp!.start();
    _pingTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      _udp?.sendPing();
      final now = DateTime.now().millisecondsSinceEpoch;
      if (_lastPongTime > 0 && now - _lastPongTime > 5000) _onConnectionLost();
    });
  }

  void _handleMessage(String msg) {
    if (msg != 'PONG') return;
    _lastPongTime = DateTime.now().millisecondsSinceEpoch;
    if (!_isConnected) setState(() {
      _isConnected = true; _connectionText = 'Terhubung'; _connectionColor = Colors.greenAccent;
    });
  }

  void _onConnectionLost() {
    if (!mounted) return;
    setState(() { _isConnected = false; _connectionText = 'Koneksi Terputus!'; _connectionColor = Colors.red; });
    _pingTimer?.cancel();
  }

  void _disconnect() {
    _pingTimer?.cancel(); _udp?.resetLatency(); _udp?.dispose(); _udp = null;
    setState(() { _isConnected = false; _lastPongTime = 0; _latency = const LatencyStats();
      _connectionText = 'Belum Terhubung'; _connectionColor = Colors.redAccent; });
  }

  void _calibrate() {
    _filter.reset(); _udp?.sendCalibrate();
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('Kalibrasi berhasil!'), backgroundColor: Colors.green,
      duration: Duration(seconds: 1)));
  }

  @override
  void dispose() {
    _accelSub?.cancel(); _gyroSub?.cancel(); _pingTimer?.cancel();
    _udp?.dispose(); _ipController.dispose(); _portController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1A1A2E),
      body: SafeArea(child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(children: [
          const Text('Baseball Controller', style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold)),
          const SizedBox(height: 10),
          Text(_connectionText, style: TextStyle(color: _connectionColor, fontSize: 13)),
          const SizedBox(height: 18),
          TextField(controller: _ipController, style: const TextStyle(color: Colors.white),
              decoration: _inp('IP Address PC')),
          const SizedBox(height: 8),
          TextField(controller: _portController, keyboardType: TextInputType.number,
              style: const TextStyle(color: Colors.white), decoration: _inp('Port (5005)')),
          const SizedBox(height: 14),
          _btn(_isConnected ? 'DISCONNECT' : 'CONNECT', const Color(0xFF4ECDC4),
              _isConnected ? _disconnect : _connect),
          const SizedBox(height: 8),
          _btn('KALIBRASI', const Color(0xFFFFE66D), _isConnected ? _calibrate : null),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: _btnOutline(
                '🧪 Latency Logger',
                const Color(0xFFFF6B6B),
                () => Navigator.push(context, MaterialPageRoute(
                    builder: (_) => const LatencyLoggerScreen())),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _btnOutline(
                '📊 Sensor Logger',
                const Color(0xFF4ECDC4),
                () => Navigator.push(context, MaterialPageRoute(
                    builder: (_) => const SensorLoggerScreen())),
              ),
            ),
          ]),
          const SizedBox(height: 22),
          _buildSensorPanel(),
          const SizedBox(height: 10),
          if (_isConnected) _buildLatencyPanel(),
          const SizedBox(height: 16),
          AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            decoration: BoxDecoration(
              color: _isSwing ? Colors.greenAccent.withOpacity(0.15) : Colors.transparent,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: _isSwing ? Colors.greenAccent : Colors.grey.shade800, width: 1.5),
            ),
            child: Text(_isSwing ? 'SWING DETECTED!' : 'Standby',
              style: TextStyle(color: _isSwing ? Colors.greenAccent : Colors.white54,
                  fontSize: 20, fontWeight: FontWeight.bold)),
          ),
          const SizedBox(height: 8),
          Text('Peak: ${_peak.toStringAsFixed(2)} m/s²',
              style: const TextStyle(color: Color(0xFFFFE66D), fontSize: 13)),
        ]),
      )),
    );
  }

  Widget _buildLatencyPanel() {
    final hasData = _latency.sampleCount > 0;
    Color col = Colors.greenAccent;
    if (_latency.avgMs > 50)  col = Colors.orangeAccent;
    if (_latency.avgMs > 150) col = Colors.redAccent;

    return Container(
      padding: const EdgeInsets.all(14),
      margin: const EdgeInsets.only(bottom: 4),
      decoration: BoxDecoration(
        color: const Color(0xFF2D2D44), borderRadius: BorderRadius.circular(12),
        border: Border.all(color: col.withOpacity(0.35), width: 1),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(width: 8, height: 8, decoration: BoxDecoration(
              color: hasData ? col : Colors.grey, shape: BoxShape.circle)),
          const SizedBox(width: 8),
          Text('Latency  (n=${_latency.sampleCount})',
              style: TextStyle(color: Colors.white.withOpacity(0.6), fontSize: 12)),
        ]),
        const SizedBox(height: 10),
        if (!hasData)
          const Text('Mengukur...', style: TextStyle(color: Colors.white38, fontSize: 13))
        else Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
          _lv('Sekarang', _latency.currentMs, col),
          _ld(), _lv('Rata-rata', _latency.avgMs, Colors.white70),
          _ld(), _lv('Min', _latency.minMs, Colors.greenAccent),
          _ld(), _lv('Max', _latency.maxMs, Colors.redAccent),
        ]),
      ]),
    );
  }

  Widget _lv(String label, double ms, Color color) => Column(children: [
    Text(label, style: TextStyle(color: Colors.white.withOpacity(0.5), fontSize: 10)),
    const SizedBox(height: 2),
    Text('${ms.toStringAsFixed(1)} ms',
        style: TextStyle(color: color, fontSize: 15, fontWeight: FontWeight.bold)),
  ]);

  Widget _ld() => Container(width: 1, height: 30, color: Colors.white12);

  Widget _buildSensorPanel() => Container(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    decoration: BoxDecoration(color: const Color(0xFF2D2D44), borderRadius: BorderRadius.circular(12)),
    child: Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
      _sv('PITCH', _pitch, Colors.cyanAccent), _ld(),
      _sv('ROLL',  _roll,  const Color(0xFF4ECDC4)), _ld(),
      _sv('YAW',   _yaw,   const Color(0xFFFFB347)),
    ]),
  );

  Widget _sv(String label, double value, Color color) => Column(children: [
    Text(label, style: TextStyle(color: color.withOpacity(0.7), fontSize: 11)),
    const SizedBox(height: 4),
    Text('${value.toStringAsFixed(1)}°',
        style: TextStyle(color: color, fontSize: 17, fontWeight: FontWeight.bold)),
  ]);

  Widget _btnOutline(String label, Color color, VoidCallback? fn) => SizedBox(
    width: double.infinity,
    child: OutlinedButton(
      onPressed: fn,
      style: OutlinedButton.styleFrom(
        side: BorderSide(color: color.withOpacity(0.7), width: 1.2),
        padding: const EdgeInsets.symmetric(vertical: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      child: Text(label, style: TextStyle(color: color, fontWeight: FontWeight.w600, fontSize: 12)),
    ),
  );

  Widget _btn(String label, Color color, VoidCallback? fn) => SizedBox(
    width: double.infinity,
    child: ElevatedButton(onPressed: fn,
      style: ElevatedButton.styleFrom(backgroundColor: color,
          disabledBackgroundColor: Colors.grey.shade700,
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
      child: Text(label, style: const TextStyle(color: Colors.black, fontWeight: FontWeight.bold))),
  );

  InputDecoration _inp(String hint) => InputDecoration(
    hintText: hint, hintStyle: const TextStyle(color: Colors.grey),
    filled: true, fillColor: const Color(0xFF2D2D44),
    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: Colors.transparent)),
  );
}
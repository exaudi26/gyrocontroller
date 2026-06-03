import 'dart:math';

// PITCH & ROLL : complementary filter (accel + gyro)
//   - Accel memberikan referensi gravitasi (stabil jangka panjang)
//   - Gyro memberikan respons cepat (mengurangi noise accel)
//   - alpha: 0.98 = 98% gyro, 2% accel per frame
//
// YAW : integrasi gyro murni (tidak ada referensi magnetometer)
//   - Rentan drift jangka panjang!!!
//   - Tombol KALIBRASI di UI mereset yaw ke 0
//   - Axis yaw: gyro[2] = rotasi sumbu Z device (putar horizontal
//     saat HP landscape = sumbu utama gerakan swing)
//

class ComplementaryFilter {
  // alpha tinggi → lebih percaya gyro (lebih smooth tapi sedikit lag)
  // alpha rendah → lebih percaya accel (lebih responsif tapi noisy)
  final double alpha;

  double pitch = 0.0;
  double roll  = 0.0;
  double yaw   = 0.0;

  int  _lastTimestamp = 0;
  bool _isFirstRun    = true;

  // Faktor konversi rad/s → deg/s
  static const double _rad2deg = 180.0 / pi;

  ComplementaryFilter({this.alpha = 0.98});

  void update({
    required List<double> accel, // [x, y, z] dalam m/s²
    required List<double> gyro,  // [x, y, z] dalam rad/s
    required int timestamp,      // nanosecond epoch
  }) {
    if (_isFirstRun) {
      _isFirstRun     = false;
      _lastTimestamp  = timestamp;
      // Inisialisasi pitch & roll dari accel agar tidak mulai dari 0
      pitch = atan2(accel[1], accel[2]) * _rad2deg;
      roll  = atan2(-accel[0], accel[2]) * _rad2deg;
      return;
    }

    // Delta waktu dalam detik
    final dt = (timestamp - _lastTimestamp) / 1e9;
    _lastTimestamp = timestamp;

    if (dt <= 0 || dt > 0.5) return;

    // Referensi sudut dari accelerometer (dalam derajat) 
    final accelPitch = atan2(accel[1], accel[2]) * _rad2deg;
    final accelRoll  = atan2(-accel[0], accel[2]) * _rad2deg;

    // Complementary Filter (pitch & roll)
    // gyro[n] dalam rad/s → kali _rad2deg untuk konversi ke deg/s
    pitch = alpha * (pitch + gyro[0] * dt * _rad2deg) + (1 - alpha) * accelPitch;
    roll  = alpha * (roll  + gyro[1] * dt * _rad2deg) + (1 - alpha) * accelRoll;

    // Yaw: integrasi gyro Z murni
    // gyro[2] = kecepatan rotasi sumbu Z device (rad/s)
    // Dalam landscape: sumbu Z ≈ sumbu vertikal → gerakan swing horizontal
    // konversi rad/s → deg/s
    yaw += gyro[2] * dt * _rad2deg;

    // Normalisasi yaw ke range -180..180 agar tidak overflow
    if (yaw > 180.0)  yaw -= 360.0;
    if (yaw < -180.0) yaw += 360.0;
  }

  // Reset semua sudut (saat kalibrasi)
  void reset() {
    pitch       = 0.0;
    roll        = 0.0;
    yaw         = 0.0;
    _isFirstRun = true;
  }

  // Reset hanya yaw
  void resetYaw() {
    yaw = 0.0;
  }
}
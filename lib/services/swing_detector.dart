import 'dart:math';

class SwingResult {
  final bool isSwing;
  final double peak;
  final double mean;
  final double stdDev;

  SwingResult({
    required this.isSwing,
    required this.peak,
    required this.mean,
    required this.stdDev,
  });
}

class SwingDetector {
  final int windowSize;
  final double peakThreshold;
  final double stdDevThreshold;

  final List<double> _buffer = [];

  SwingDetector({
    this.windowSize = 20,
    this.peakThreshold = 15.0,   
    this.stdDevThreshold = 4.0,  
  });

  SwingResult process(List<double> accel) {
    // Hitung magnitude
    final magnitude = sqrt(
      accel[0] * accel[0] +
      accel[1] * accel[1] +
      accel[2] * accel[2],
    );

    _buffer.add(magnitude);
    if (_buffer.length > windowSize) _buffer.removeAt(0);
    if (_buffer.length < windowSize) {
      return SwingResult(isSwing: false, peak: 0, mean: 0, stdDev: 0);
    }

    // Feature Extraction
    final peak = _buffer.reduce(max);
    final mean = _buffer.reduce((a, b) => a + b) / _buffer.length;
    final variance = _buffer
        .map((x) => (x - mean) * (x - mean))
        .reduce((a, b) => a + b) / _buffer.length;
    final stdDev = sqrt(variance);

    final isSwing = peak > peakThreshold && stdDev > stdDevThreshold;

    return SwingResult(isSwing: isSwing, peak: peak, mean: mean, stdDev: stdDev);
  }
}
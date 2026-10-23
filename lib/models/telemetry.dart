import 'dart:convert';

class Telemetry {
  final List<double> ai;
  final List<double> ao;
  final List<int> di;
  final List<int> doo;
  // Device millis() and message sequence number. Optional: older
  // firmware does not send them.
  final int? deviceMs;
  final int? seq;

  Telemetry({
    required this.ai,
    required this.ao,
    required this.di,
    required this.doo,
    this.deviceMs,
    this.seq,
  });

  factory Telemetry.fromJson(String payload) {
    final j = jsonDecode(payload);
    return Telemetry(
      ai: (j['ai'] as List).map((e) => (e as num).toDouble()).toList(),
      ao: (j['ao'] as List).map((e) => (e as num).toDouble()).toList(),
      di: (j['di'] as List).map((e) => (e as num).toInt()).toList(),
      doo: (j['do'] as List).map((e) => (e as num).toInt()).toList(),
      deviceMs: (j['ms'] as num?)?.toInt(),
      seq: (j['seq'] as num?)?.toInt(),
    );
  }
}


import 'dart:convert';

class Telemetry {
  final List<double> ai;
  final List<double> ao;
  final List<int> di;
  final List<int> doo;

  Telemetry({
    required this.ai,
    required this.ao,
    required this.di,
    required this.doo,
  });

  factory Telemetry.fromJson(String payload) {
    final j = jsonDecode(payload);
    return Telemetry(
      ai: (j['ai'] as List).map((e) => (e as num).toDouble()).toList(),
      ao: (j['ao'] as List).map((e) => (e as num).toDouble()).toList(),
      di: (j['di'] as List).map((e) => (e as num).toInt()).toList(),
      doo: (j['do'] as List).map((e) => (e as num).toInt()).toList(),
    );
  }
}
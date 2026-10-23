import 'dart:convert';
import 'dart:math';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tcc_flutter/pages/dashboard_screen/pid_identification_export.dart';
import 'package:tcc_flutter/pages/dashboard_screen/widgets/graph.dart';

// Synthetic heater: FOPDT with K = 25 °C, L = 4 s, Tau = 110 s, sampled at
// 1 s, DO stepping 0 -> 1 at t = 20 s.
List<ExportSeries> _syntheticSeries({bool withEdge = true}) {
  final rnd = Random(1);
  final t0 = DateTime(2026, 10, 22, 19);
  final temp = <SparkPoint>[];
  final dout = <SparkPoint>[];
  const stepAt = 20.0;
  for (int k = 0; k < 300; k++) {
    final time = t0.add(Duration(seconds: k));
    final t = withEdge ? k.toDouble() : k + stepAt;
    final u = t >= stepAt ? 1.0 : 0.0;
    final dt = t - stepAt - 4;
    final y =
        21 +
        (dt > 0 ? 25 * (1 - exp(-dt / 110)) : 0) +
        (rnd.nextDouble() - 0.5) * 0.2;
    temp.add(SparkPoint(y, time));
    dout.add(SparkPoint(u, time));
  }
  return [
    ExportSeries(header: 'AI_1_Temperatura', points: temp),
    ExportSeries(header: 'DO_1_Resistencia', points: dout),
  ];
}

const _params = PidExportParams(
  deviceName: 'Forno teste',
  deviceId: 'abc123',
  inputSeries: 1,
  outputSeries: 0,
  inputLabel: 'Resistência',
  outputLabel: 'Temperatura',
  outputUnit: '°C',
  uMin: 0,
  uMax: 1,
  pid0: 0,
  pid100: 100,
  pidOutMin: 0,
  pidOutMax: 100,
  tpoPeriodS: 10,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('CSV has one aligned row per sample and honours the date filter', () {
    final series = _syntheticSeries();
    final csv = buildTraceCsv(series);
    final lines = const LineSplitter().convert(csv.content);
    expect(lines.first, 't_s,AI_1_Temperatura,DO_1_Resistencia');
    expect(csv.rows, 300);
    expect(lines[1].split(',').first, '0.000');
    expect(lines[21].split(',').last, '1.0000');

    final filtered = buildTraceCsv(
      series,
      startAt: series.first.points[100].time,
      endAt: series.first.points[199].time,
    );
    expect(filtered.rows, 100);
    expect(filtered.firstSample, series.first.points[100].time);
  });

  test('CSV prefers device millis, handles wrap, reboot and lost seq', () {
    final t0 = DateTime(2026, 10, 22, 19);
    // Arrival jitter: messages land at 0, 1.8, 2.0, 3.5, ... s while the
    // device sampled every 1000 ms (wrapping millis() at 2^32).
    const wrap = 0x100000000;
    final samples = <(int arrivalMs, int deviceMs, int seq)>[
      (0, wrap - 1500, 10),
      (1800, wrap - 500, 11),
      (2000, 500, 12), // millis() wrapped
      (3500, 2500, 14), // seq 13 lost, device gap 2 s
      (60000, 300, 0), // reboot: falls back to arrival step
      (61000, 1300, 1),
    ];
    final points = [
      for (final s in samples)
        SparkPoint(
          1,
          t0.add(Duration(milliseconds: s.$1)),
          deviceMs: s.$2,
          seq: s.$3,
        ),
    ];
    final csv = buildTraceCsv([ExportSeries(header: 'AI_1', points: points)]);
    final times = const LineSplitter()
        .convert(csv.content)
        .skip(1)
        .map((l) => l.split(',').first)
        .toList();
    expect(times, ['0.000', '1.000', '2.000', '4.000', '60.500', '61.500']);
    expect(csv.deviceTimedSteps, 4);
    expect(csv.usesDeviceClock, isFalse);
    expect(csv.lostMessages, 1);
  });

  test('CSV falls back to arrival time without device fields', () {
    final csv = buildTraceCsv(_syntheticSeries());
    expect(csv.deviceTimedSteps, 0);
    expect(csv.lostMessages, 0);
  });

  test('zip contains CSV, filled script and README', () async {
    final series = _syntheticSeries();
    final csv = buildTraceCsv(series);
    final zip = await buildPidIdentificationZip(
      series: series,
      csv: csv,
      params: _params,
    );
    final archive = ZipDecoder().decodeBytes(zip);
    final names = archive.files.map((f) => f.name).toSet();
    expect(names, {'dados.csv', 'identificacao_pid.m', 'LEIA-ME.txt'});

    final script = utf8.decode(
      archive.files.firstWhere((f) => f.name == 'identificacao_pid.m').content,
    );
    expect(script, isNot(contains('{{')));
    expect(script, contains('COL_U       = 3;'));
    expect(script, contains('COL_Y       = 2;'));
    expect(script, contains('TPO_PERIODO = 10;'));
  });
}

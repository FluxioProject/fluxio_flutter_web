import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:tcc_flutter/pages/dashboard_screen/widgets/graph.dart';

// Builds the "Identificação PID" export package: a zip with the trace as
// CSV, the identification/tuning MATLAB script (an asset template with
// its parameter block filled in) and a README for the customer.

const _scriptAsset = 'assets/matlab/identificacao_pid.m';

// One CSV column: header must already be a safe identifier (no commas).
class ExportSeries {
  final String header;
  final List<SparkPoint> points;

  const ExportSeries({required this.header, required this.points});
}

class PidExportParams {
  final String deviceName;
  final String deviceId;

  // Indexes into the series list passed to buildPidIdentificationZip.
  final int inputSeries;
  final int outputSeries;

  final String inputLabel;
  final String outputLabel;
  final String outputUnit;

  // Actuator range as logged: uMin = 0 %, uMax = 100 %.
  final double uMin;
  final double uMax;

  // PID block output that maps to 0 % and 100 % of the actuator.
  final double pid0;
  final double pid100;

  // PID block output clamp.
  final double pidOutMin;
  final double pidOutMax;

  // TPO cycle period in seconds; null simulates a continuous output.
  final double? tpoPeriodS;

  const PidExportParams({
    required this.deviceName,
    required this.deviceId,
    required this.inputSeries,
    required this.outputSeries,
    required this.inputLabel,
    required this.outputLabel,
    required this.outputUnit,
    required this.uMin,
    required this.uMax,
    required this.pid0,
    required this.pid100,
    required this.pidOutMin,
    required this.pidOutMax,
    this.tpoPeriodS,
  });
}

class TraceCsv {
  final String content;
  final int rows;
  final DateTime? firstSample;
  // Row-to-row steps timed by the device clock (the rest fall back to
  // browser arrival time).
  final int deviceTimedSteps;
  // Telemetry messages missing between exported rows, from seq gaps.
  final int lostMessages;

  const TraceCsv(
    this.content,
    this.rows,
    this.firstSample, {
    this.deviceTimedSteps = 0,
    this.lostMessages = 0,
  });

  bool get usesDeviceClock => rows > 1 && deviceTimedSteps == rows - 1;
}

const _uint32Range = 0x100000000;

// A device-clock step longer than this is treated as a reboot (millis()
// restarted) rather than a real gap, and timed by arrival instead.
const _maxDeviceStepMs = 10 * 60 * 1000;

// Every telemetry message appends one point to every channel history and
// trims them together, so the histories stay index-aligned. Rows are
// matched from the newest point backwards to be safe if lengths differ;
// the first series provides the row timestamp.
//
// t_s accumulates per-row steps: the device millis() difference when the
// firmware sends it (no network jitter), else the browser arrival
// difference. Date filtering always uses arrival time.
TraceCsv buildTraceCsv(
  List<ExportSeries> series, {
  DateTime? startAt,
  DateTime? endAt,
}) {
  final buffer = StringBuffer()
    ..writeln(['t_s', ...series.map((s) => s.header)].join(','));
  if (series.isEmpty) return TraceCsv(buffer.toString(), 0, null);

  final n = series.map((s) => s.points.length).reduce((a, b) => a < b ? a : b);
  final ref = series.first.points;

  SparkPoint? prev;
  DateTime? firstTime;
  var elapsedMs = 0;
  var rows = 0;
  var deviceSteps = 0;
  var lost = 0;
  for (int j = 0; j < n; j++) {
    final p = ref[ref.length - n + j];
    if (startAt != null && p.time.isBefore(startAt)) continue;
    if (endAt != null && p.time.isAfter(endAt)) continue;

    firstTime ??= p.time;
    if (prev != null) {
      var stepMs = p.time.difference(prev.time).inMilliseconds;
      if (p.deviceMs != null && prev.deviceMs != null) {
        // Modulo handles the uint32 millis() wrap (~49 days).
        final deviceStep = (p.deviceMs! - prev.deviceMs!) % _uint32Range;
        if (deviceStep <= _maxDeviceStepMs) {
          stepMs = deviceStep;
          deviceSteps++;
        }
      }
      elapsedMs += stepMs;

      if (p.seq != null && prev.seq != null) {
        final gap = (p.seq! - prev.seq!) % _uint32Range - 1;
        // A huge gap means the counter restarted (reboot), not losses.
        if (gap > 0 && gap < 100000) lost += gap;
      }
    }

    final cells = <String>[
      (elapsedMs / 1000.0).toStringAsFixed(3),
      for (final s in series)
        s.points[s.points.length - n + j].value.toStringAsFixed(4),
    ];
    buffer.writeln(cells.join(','));
    rows++;
    prev = p;
  }

  return TraceCsv(
    buffer.toString(),
    rows,
    firstTime,
    deviceTimedSteps: deviceSteps,
    lostMessages: lost,
  );
}

Future<Uint8List> buildPidIdentificationZip({
  required List<ExportSeries> series,
  required TraceCsv csv,
  required PidExportParams params,
}) async {
  final template = await rootBundle.loadString(_scriptAsset);
  final script = _fillTemplate(template, series, params);
  final readme = _buildReadme(series, csv, params);

  final archive = Archive();
  void add(String name, String content) {
    final bytes = utf8.encode(content);
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  }

  add('dados.csv', csv.content);
  add('identificacao_pid.m', script);
  add('LEIA-ME.txt', readme);

  return ZipEncoder().encodeBytes(archive);
}

String _num(double v) {
  // MATLAB literal without trailing zeros noise (10.0 -> 10).
  if (v == v.roundToDouble()) return v.toStringAsFixed(0);
  return v.toString();
}

// Escapes a value for a single-quoted MATLAB char literal.
String _mString(String s) => s.replaceAll("'", "''").replaceAll('\n', ' ');

String _fillTemplate(
  String template,
  List<ExportSeries> series,
  PidExportParams p,
) {
  final now = DateTime.now();
  final values = <String, String>{
    'DISPOSITIVO': '${p.deviceName.replaceAll('\n', ' ')} (${p.deviceId})',
    'GERADO_EM': _fmtDate(now),
    // +2: MATLAB is 1-based and column 1 is the time.
    'COL_U': '${p.inputSeries + 2}',
    'COL_Y': '${p.outputSeries + 2}',
    'NOME_U': _mString(p.inputLabel),
    'NOME_Y': _mString(p.outputLabel),
    'UNIDADE_Y': _mString(p.outputUnit),
    'U_MIN': _num(p.uMin),
    'U_MAX': _num(p.uMax),
    'PID_0': _num(p.pid0),
    'PID_100': _num(p.pid100),
    'PID_OUT_MIN': _num(p.pidOutMin),
    'PID_OUT_MAX': _num(p.pidOutMax),
    'TPO_PERIODO': p.tpoPeriodS == null ? '[]' : _num(p.tpoPeriodS!),
  };

  var out = template;
  values.forEach((key, value) => out = out.replaceAll('{{$key}}', value));
  return out;
}

String _fmtDate(DateTime d) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(d.day)}/${two(d.month)}/${d.year} '
      '${two(d.hour)}:${two(d.minute)}:${two(d.second)}';
}

String _buildReadme(
  List<ExportSeries> series,
  TraceCsv csv,
  PidExportParams p,
) {
  final b = StringBuffer();
  b.writeln('IDENTIFICAÇÃO DE PROCESSO E SINTONIA PID');
  b.writeln('Dispositivo: ${p.deviceName} (${p.deviceId})');
  b.writeln('Gerado em: ${_fmtDate(DateTime.now())}');
  if (csv.firstSample != null) {
    b.writeln('Primeira amostra (t = 0): ${_fmtDate(csv.firstSample!)}');
  }
  b.writeln('Amostras: ${csv.rows}');
  b.writeln(
    'Base de tempo: ${csv.usesDeviceClock
        ? 'relógio do dispositivo'
        : csv.deviceTimedSteps > 0
        ? 'relógio do dispositivo, com trechos pela chegada no navegador'
        : 'chegada no navegador'}',
  );
  if (csv.lostMessages > 0) {
    b.writeln(
      'Mensagens de telemetria perdidas no trecho: ${csv.lostMessages}',
    );
  }
  b.writeln();
  b.writeln('CONTEÚDO');
  b.writeln('  dados.csv            Trace exportado do painel.');
  b.writeln('  identificacao_pid.m  Identificação do modelo e sintonia.');
  b.writeln('  LEIA-ME.txt          Este arquivo.');
  b.writeln();
  b.writeln('COLUNAS DO CSV');
  b.writeln('  1: t_s  tempo em segundos desde a primeira amostra');
  for (int i = 0; i < series.length; i++) {
    final role = i == p.inputSeries
        ? '  <- entrada (atuador)'
        : i == p.outputSeries
        ? '  <- saída (variável de processo)'
        : '';
    b.writeln('  ${i + 2}: ${series[i].header}$role');
  }
  b.writeln();
  b.writeln('COMO USAR');
  b.writeln('  1. Extraia os três arquivos na mesma pasta.');
  b.writeln('  2. Abra identificacao_pid.m no MATLAB (ou GNU Octave) e rode.');
  b.writeln('     Não precisa de toolbox.');
  b.writeln('  3. O script imprime o modelo identificado (K, L, Tau) e uma');
  b.writeln('     tabela de ganhos Kp, Ki, Kd por regra de sintonia, já nas');
  b.writeln('     unidades do bloco PID. Os gráficos mostram o ajuste do');
  b.writeln('     modelo e a malha fechada simulada para cada regra.');
  b.writeln(
    '  4. Os parâmetros no topo do script (escala do atuador, saturação,',
  );
  b.writeln('     período do TPO, TAU_C, SETPOINT) podem ser ajustados à mão.');
  b.writeln();
  b.writeln('PARÂMETROS USADOS');
  b.writeln(
    '  Entrada: ${p.inputLabel} | escala ${_num(p.uMin)} = 0 %, '
    '${_num(p.uMax)} = 100 %',
  );
  b.writeln('  Saída: ${p.outputLabel} (${p.outputUnit})');
  b.writeln(
    '  Saída do PID: ${_num(p.pid0)} = 0 % e ${_num(p.pid100)} = 100 % '
    'do atuador; saturação ${_num(p.pidOutMin)}..${_num(p.pidOutMax)}',
  );
  b.writeln(
    '  TPO: ${p.tpoPeriodS == null ? 'não simulado' : '${_num(p.tpoPeriodS!)} s'}',
  );
  b.writeln();
  b.writeln('COMO FAZER UM BOM ENSAIO');
  b.writeln('  - Desligue o PID/TPO e comande o atuador manualmente.');
  b.writeln('  - Espere a variável estabilizar com o atuador em repouso.');
  b.writeln('  - Aplique um único degrau (ex.: 0 % -> 100 %) e não mexa mais.');
  b.writeln('  - Registre até a variável estabilizar de novo (pelo menos 5x a');
  b.writeln('    constante de tempo). O painel guarda só as últimas');
  b.writeln(
    '    $telemetryHistoryCapacity amostras por canal e só enquanto a tela',
  );
  b.writeln('    do dispositivo fica aberta; exporte antes de sair dela.');
  b.writeln('  - Se não houver degrau no trace, o script assume que a entrada');
  b.writeln('    saiu de 0 % no primeiro ponto e avisa.');
  b.writeln();
  b.writeln('SUPOSIÇÕES');
  b.writeln('  - PID paralelo, como o bloco PID do firmware:');
  b.writeln('    saída = Kp*e + Ki*integral(e) + Kd*de/dt, com tempo em');
  b.writeln('    segundos (Ki em 1/s, Kd em s). A integral congela quando a');
  b.writeln('    saída satura (anti-windup).');
  if (csv.usesDeviceClock) {
    b.writeln('  - O tempo do CSV vem do relógio do dispositivo (millis()).');
  } else {
    b.writeln(
      '  - O tempo do CSV vem, ao menos em parte, da hora de chegada da',
    );
    b.writeln('    telemetria no navegador, com variação de rede (jitter).');
    b.writeln('    Firmware atualizado envia o tempo do próprio dispositivo.');
  }
  b.writeln('  - Modelo de primeira ordem com atraso (FOPDT), linear.');
  b.writeln();
  b.writeln('SEGURANÇA');
  b.writeln(
    '  Os ganhos calculados são apenas um ponto de partida. A simulação',
  );
  b.writeln('  é simplificada e não substitui o teste real. Ao aplicar no');
  b.writeln(
    '  equipamento, mantenha limites de segurança (temperatura máxima,',
  );
  b.writeln(
    '  intertravamentos) e acompanhe o primeiro ciclo de perto. Regras',
  );
  b.writeln('  como Ziegler-Nichols e Cohen-Coon costumam ser agressivas;');
  b.writeln('  prefira começar por SIMC ou IMC.');
  return b.toString();
}

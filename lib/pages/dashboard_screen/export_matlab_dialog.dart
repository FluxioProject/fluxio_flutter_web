import 'dart:convert';
import 'dart:html' as html;
import 'package:flutter/material.dart';
import 'package:tcc_flutter/models/channel_config.dart';
import 'package:tcc_flutter/pages/dashboard_screen/widgets/graph.dart';

// Entry point: call this from the "Gerenciar cards" row (or anywhere else
// on DeviceDetailsPage) passing in the same aiHistory/aoHistory/diHistory/
// doHistory + aiCfg/aoCfg/diCfg/doCfg lists that already live on that page.
//
// Example wiring in device_details_page.dart, next to the "Gerenciar
// cards" IconButton:
//
//   IconButton(
//     tooltip: 'Exportar trace (MATLAB)',
//     icon: const Icon(Icons.insert_chart_outlined),
//     onPressed: () => showExportMatlabDialog(
//       context: context,
//       deviceName: widget.device.name,
//       deviceId: widget.device.deviceId,
//       aiHistory: aiHistory,
//       aoHistory: aoHistory,
//       diHistory: diHistory,
//       doHistory: doHistory,
//       aiCfg: aiCfg,
//       aoCfg: aoCfg,
//       diCfg: diCfg,
//       doCfg: doCfg,
//     ),
//   ),
Future<void> showExportMatlabDialog({
  required BuildContext context,
  required String deviceName,
  required String deviceId,
  required List<List<SparkPoint>> aiHistory,
  required List<List<SparkPoint>> aoHistory,
  required List<List<SparkPoint>> diHistory,
  required List<List<SparkPoint>> doHistory,
  required List<ChannelConfig> aiCfg,
  required List<ChannelConfig> aoCfg,
  required List<ChannelConfig> diCfg,
  required List<ChannelConfig> doCfg,
}) {
  return showDialog(
    context: context,
    builder: (_) => _ExportMatlabDialog(
      deviceName: deviceName,
      deviceId: deviceId,
      aiHistory: aiHistory,
      aoHistory: aoHistory,
      diHistory: diHistory,
      doHistory: doHistory,
      aiCfg: aiCfg,
      aoCfg: aoCfg,
      diCfg: diCfg,
      doCfg: doCfg,
    ),
  );
}

// Internal helper bundling one exportable channel: its raw history points,
// display label (from ChannelConfig.name) and the MATLAB-safe variable
// name prefix derived from it.
class _ExportChannel {
  final String groupLabel; // 'AI', 'AO', 'DI', 'DO'
  final int index;
  final String label;
  final String varName;
  final List<SparkPoint> points;

  _ExportChannel({
    required this.groupLabel,
    required this.index,
    required this.label,
    required this.varName,
    required this.points,
  });

  String get key => '${groupLabel}_$index';
}

class _ExportMatlabDialog extends StatefulWidget {
  final String deviceName;
  final String deviceId;
  final List<List<SparkPoint>> aiHistory;
  final List<List<SparkPoint>> aoHistory;
  final List<List<SparkPoint>> diHistory;
  final List<List<SparkPoint>> doHistory;
  final List<ChannelConfig> aiCfg;
  final List<ChannelConfig> aoCfg;
  final List<ChannelConfig> diCfg;
  final List<ChannelConfig> doCfg;

  const _ExportMatlabDialog({
    required this.deviceName,
    required this.deviceId,
    required this.aiHistory,
    required this.aoHistory,
    required this.diHistory,
    required this.doHistory,
    required this.aiCfg,
    required this.aoCfg,
    required this.diCfg,
    required this.doCfg,
  });

  @override
  State<_ExportMatlabDialog> createState() => _ExportMatlabDialogState();
}

class _ExportMatlabDialogState extends State<_ExportMatlabDialog> {
  late final List<_ExportChannel> _allChannels;
  final Set<String> _selectedKeys = {};

  bool _filterByDate = false;
  DateTime? _startAt;
  DateTime? _endAt;

  @override
  void initState() {
    super.initState();
    _allChannels = _buildChannelList();

    // Pre-select every channel that currently has data, so the common
    // case ("export everything I have") is a single tap.
    for (final c in _allChannels) {
      if (c.points.isNotEmpty) _selectedKeys.add(c.key);
    }
  }

  List<_ExportChannel> _buildChannelList() {
    final list = <_ExportChannel>[];

    void addGroup(
      String groupLabel,
      List<List<SparkPoint>> history,
      List<ChannelConfig> cfg,
    ) {
      for (int i = 0; i < history.length; i++) {
        final name = i < cfg.length ? cfg[i].name : '$groupLabel ${i + 1}';
        list.add(
          _ExportChannel(
            groupLabel: groupLabel,
            index: i,
            label: name,
            varName: _sanitizeVarName('${groupLabel}_${i + 1}_$name'),
            points: history[i],
          ),
        );
      }
    }

    addGroup('AI', widget.aiHistory, widget.aiCfg);
    addGroup('AO', widget.aoHistory, widget.aoCfg);
    addGroup('DI', widget.diHistory, widget.diCfg);
    addGroup('DO', widget.doHistory, widget.doCfg);

    return list;
  }

  // MATLAB variable names must start with a letter and contain only
  // letters, digits and underscores.
  String _sanitizeVarName(String raw) {
    var s = raw.replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '_');
    if (s.isEmpty || !RegExp(r'^[a-zA-Z]').hasMatch(s)) {
      s = 'ch_$s';
    }
    return s;
  }

  List<_ExportChannel> _groupOf(String label) =>
      _allChannels.where((c) => c.groupLabel == label).toList();

  Future<void> _pickDateTime({required bool isStart}) async {
    final now = DateTime.now();
    final initial = (isStart ? _startAt : _endAt) ?? now;

    final date = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(now.year - 2),
      lastDate: DateTime(now.year + 1),
    );
    if (date == null || !mounted) return;

    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
    );
    if (time == null) return;

    final picked = DateTime(
      date.year,
      date.month,
      date.day,
      time.hour,
      time.minute,
    );

    setState(() {
      if (isStart) {
        _startAt = picked;
      } else {
        _endAt = picked;
      }
    });
  }

  String _fmt(DateTime? d) {
    if (d == null) return '—';
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(d.day)}/${two(d.month)}/${d.year} ${two(d.hour)}:${two(d.minute)}';
  }

  bool get _hasAnySelection => _selectedKeys.isNotEmpty;

  void _export() {
    final selected = _allChannels
        .where((c) => _selectedKeys.contains(c.key))
        .toList();

    final script = _buildMatlabScript(selected);

    final safeDeviceName = _sanitizeVarName(widget.deviceName).toLowerCase();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final filename = 'trace_${safeDeviceName}_$timestamp.m';

    _downloadFile(filename, script);

    Navigator.of(context).pop();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Trace exportado: $filename')),
    );
  }

  String _buildMatlabScript(List<_ExportChannel> channels) {
    final buffer = StringBuffer();

    buffer.writeln('%% Trace exportado - ${widget.deviceName}');
    buffer.writeln('% Device ID: ${widget.deviceId}');
    buffer.writeln('% Gerado em ${DateTime.now()}');
    if (_filterByDate) {
      buffer.writeln('% Filtro de periodo: ${_fmt(_startAt)} ate ${_fmt(_endAt)}');
    }
    buffer.writeln();

    final varNames = <String>[];

    for (final ch in channels) {
      final points = ch.points.where((p) {
        if (_filterByDate) {
          if (_startAt != null && p.time.isBefore(_startAt!)) return false;
          if (_endAt != null && p.time.isAfter(_endAt!)) return false;
        }
        return true;
      }).toList();

      if (points.isEmpty) {
        buffer.writeln('% ${ch.groupLabel} ${ch.index + 1} (${ch.label}): sem pontos no periodo selecionado');
        buffer.writeln();
        continue;
      }

      final t0 = points.first.time;
      final tVals = points
          .map((p) =>
              (p.time.difference(t0).inMilliseconds / 1000.0).toStringAsFixed(3))
          .join(', ');
      final yVals = points.map((p) => p.value.toStringAsFixed(4)).join(', ');

      buffer.writeln('% ${ch.groupLabel} ${ch.index + 1}: ${ch.label}');
      buffer.writeln('${ch.varName}_t = [$tVals];  %% segundos, t=0 no primeiro ponto');
      buffer.writeln('${ch.varName}_y = [$yVals];');
      buffer.writeln("${ch.varName}_label = '${ch.label.replaceAll("'", "''")}';");
      buffer.writeln();

      varNames.add(ch.varName);
    }

    if (varNames.isNotEmpty) {
      buffer.writeln('%% Plot rapido de todos os canais exportados');
      buffer.writeln('figure; hold on;');
      for (final v in varNames) {
        buffer.writeln("plot(${v}_t, ${v}_y, 'DisplayName', ${v}_label);");
      }
      buffer.writeln('legend show;');
      buffer.writeln("xlabel('Tempo (s)'); ylabel('Valor');");
      buffer.writeln('grid on;');
    }

    return buffer.toString();
  }

  void _downloadFile(String filename, String content) {
    final bytes = utf8.encode(content);
    final blob = html.Blob([bytes], 'text/plain');
    final url = html.Url.createObjectUrlFromBlob(blob);
    html.AnchorElement(href: url)
      ..setAttribute('download', filename)
      ..click();
    html.Url.revokeObjectUrl(url);
  }

  Widget _channelGroup(String title, String groupLabel) {
    final channels = _groupOf(groupLabel);
    if (channels.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Text(
            title,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
          ),
        ),
        const Divider(height: 8),
        ...channels.map((c) {
          final hasData = c.points.isNotEmpty;
          return CheckboxListTile(
            dense: true,
            enabled: hasData,
            title: Text(c.label),
            subtitle: Text(
              hasData
                  ? '${c.points.length} pontos'
                  : 'Sem dados no buffer atual',
              style: const TextStyle(fontSize: 11),
            ),
            value: _selectedKeys.contains(c.key),
            onChanged: !hasData
                ? null
                : (v) {
                    setState(() {
                      if (v == true) {
                        _selectedKeys.add(c.key);
                      } else {
                        _selectedKeys.remove(c.key);
                      }
                    });
                  },
          );
        }),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Exportar trace (MATLAB)'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Selecione as entradas/saídas e, se quiser, um período. '
                'O arquivo gerado é um script .m que cria as variáveis '
                '(tempo, valor e rótulo) direto no workspace do MATLAB.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),

              // Date/time filter toggle
              SwitchListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text('Filtrar por data/hora'),
                value: _filterByDate,
                onChanged: (v) => setState(() => _filterByDate = v),
              ),
              if (_filterByDate) ...[
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.calendar_today, size: 16),
                        label: Text('Início: ${_fmt(_startAt)}'),
                        onPressed: () => _pickDateTime(isStart: true),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.calendar_today, size: 16),
                        label: Text('Fim: ${_fmt(_endAt)}'),
                        onPressed: () => _pickDateTime(isStart: false),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
              ],

              const Divider(height: 20),

              _channelGroup('Entradas Analógicas', 'AI'),
              _channelGroup('Saídas Analógicas', 'AO'),
              _channelGroup('Entradas Digitais', 'DI'),
              _channelGroup('Saídas Digitais', 'DO'),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: const Color.fromARGB(255, 63, 146, 66),
          ),
          onPressed: _hasAnySelection ? _export : null,
          child: const Text('Exportar', style: TextStyle(color: Colors.white)),
        ),
      ],
    );
  }
}
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:tcc_flutter/models/device.dart';
import 'package:tcc_flutter/models/channel_config.dart';
import 'package:tcc_flutter/models/telemetry.dart';
import 'package:tcc_flutter/mqtt/mqtt_manager.dart';
import 'package:tcc_flutter/widgets/gradient_bg.dart';

class DeviceCommandPage extends StatefulWidget {
  final Device device;
  final List<ChannelConfig> aoCfg;
  final List<ChannelConfig> doCfg;

  const DeviceCommandPage({
    super.key,
    required this.device,
    required this.aoCfg,
    required this.doCfg,
  });

  @override
  State<DeviceCommandPage> createState() => _DeviceCommandPageState();
}

class _DeviceCommandPageState extends State<DeviceCommandPage> {
  final List<double> aoValues = List.filled(4, 0.0);
  final List<TextEditingController> aoControllers = List.generate(
    4,
    (_) => TextEditingController(),
  );

  final List<bool> doStates = List.filled(4, false);
  Timer? _telemetryKeepAlive;
  late final String _topicControl;
  final List<bool> _editingAO = List.filled(4, false);

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      _topicControl = 'device/${widget.device.deviceId}/control';

      mqttManager.publish(_topicControl, jsonEncode({'telemetry': true}));

      _telemetryKeepAlive = Timer.periodic(const Duration(seconds: 5), (_) {
        mqttManager.publish(_topicControl, jsonEncode({'telemetry': true}));
      });

      final topicTelemetry = 'device/${widget.device.deviceId}/telemetry';

      mqttManager.subscribe(topicTelemetry, (payload) {
        final t = Telemetry.fromJson(payload);
        if (!mounted) return;

        setState(() {
          for (int i = 0; i < aoValues.length; i++) {
            if (!_editingAO[i]) {
              aoValues[i] = t.ao[i];
              aoControllers[i].text = aoValues[i].toStringAsFixed(
                widget.aoCfg[i].decimals,
              );
            }
          }

          for (int i = 0; i < doStates.length; i++) {
            doStates[i] = t.doo[i] == 1;
          }
        });
      });

      // opcional: pedir estado atual
      mqttManager.publish(
        'device/${widget.device.deviceId}/control',
        jsonEncode({'state': true}),
      );
      mqttManager.publish(
        'device/${widget.device.deviceId}/control',
        jsonEncode({'manual': true}),
      );
    });
  }

  @override
  void dispose() {
    super.dispose();
    mqttManager.publish(
      'device/${widget.device.deviceId}/control',
      jsonEncode({'manual': false}),
    );
    _telemetryKeepAlive?.cancel();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color.fromARGB(255, 35, 35, 35),
        title: Text(
          'Enviar comandos   -   ${widget.device.name} (${widget.device.deviceId})',
        ),
      ),
      body: GradientBackground(
        image: false,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 16, top: 16, left: 16),
          child: SingleChildScrollView(
            padding: const EdgeInsets.only(right: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _warningBox(),
                const SizedBox(height: 20),

                _sectionTitle('Saídas Digitais'),
                _digitalOutputs(),

                const SizedBox(height: 24),

                _sectionTitle('Saídas Analógicas'),
                _analogOutputs(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _sectionTitle(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        text,
        style: Theme.of(
          context,
        ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
      ),
    );
  }

  Widget _warningBox() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.orange.withOpacity(0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.orangeAccent),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: const [
          Icon(Icons.warning_amber_rounded, color: Colors.orangeAccent),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              'Esta área permite o envio manual de comandos ao dispositivo.\n'
              'Use apenas se souber exatamente o que está fazendo.\n'
              'A responsabilidade pelo uso é inteiramente do operador.',
              style: TextStyle(fontSize: 14),
            ),
          ),
        ],
      ),
    );
  }

  Widget _digitalOutputs() {
    return Column(
      children: List.generate(widget.doCfg.length, (i) {
        final c = widget.doCfg[i];

        return Card(
          color: const Color(0xFF1B1B1B),
          margin: const EdgeInsets.symmetric(vertical: 6),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          child: SwitchListTile(
            title: Text(c.name),
            value: doStates[i],
            onChanged: (v) {
              setState(() => doStates[i] = v);

              mqttManager.publish(
                'device/${widget.device.deviceId}/control',
                jsonEncode({
                  'do': {'index': i, 'value': v ? 1 : 0},
                }),
              );
            },
          ),
        );
      }),
    );
  }

  Widget _analogOutputs() {
    return Column(
      children: List.generate(widget.aoCfg.length, (i) {
        final c = widget.aoCfg[i];

        return Card(
          color: const Color(0xFF1B1B1B),
          margin: const EdgeInsets.symmetric(vertical: 8),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(c.name, style: const TextStyle(fontSize: 16)),
                const SizedBox(height: 8),

                Row(
                  children: [
                    Expanded(
                      child: Slider(
                        onChangeStart: (_) {
                          _editingAO[i] = true;
                        },
                        onChangeEnd: (_) {
                          _editingAO[i] = false;
                        },
                        min: c.min,
                        max: c.max,
                        value: aoValues[i].clamp(c.min, c.max),
                        onChanged: (v) {
                          setState(() {
                            aoValues[i] = v;
                            aoControllers[i].text = v.toStringAsFixed(
                              c.decimals,
                            );
                          });
                        },
                      ),
                    ),
                    SizedBox(
                      width: 90,
                      child: TextField(
                        onTap: () {
                          _editingAO[i] = true;
                        },
                        controller: aoControllers[i],
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        onSubmitted: (v) {
                          final parsed = double.tryParse(v);
                          if (parsed == null) return;

                          setState(() {
                            aoValues[i] = parsed.clamp(c.min, c.max);
                            aoControllers[i].text = aoValues[i].toStringAsFixed(
                              c.decimals,
                            );
                          });
                        },
                        decoration: InputDecoration(
                          suffixText: c.unit,
                          isDense: true,
                          border: const OutlineInputBorder(),
                        ),
                      ),
                    ),
                  ],
                ),

                Align(
                  alignment: Alignment.centerRight,
                  child: Text(
                    '${aoValues[i].toStringAsFixed(c.decimals)} ${c.unit}',
                    style: const TextStyle(color: Colors.white70),
                  ),
                ),

                const SizedBox(height: 6),

                ElevatedButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color.fromARGB(255, 63, 146, 66),
                  ),
                  onPressed: () {
                    mqttManager.publish(
                      'device/${widget.device.deviceId}/control',
                      jsonEncode({
                        'ao': {'index': i, 'value': aoValues[i]},
                      }),
                    );
                  },

                  icon: const Icon(Icons.send),
                  label: const Text(
                    'Enviar valor',
                    style: TextStyle(color: Colors.white),
                  ),
                ),
              ],
            ),
          ),
        );
      }),
    );
  }
}

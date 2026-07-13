import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:tcc_flutter/models/device.dart';
import 'package:tcc_flutter/models/channel_config.dart';
import 'package:tcc_flutter/models/telemetry.dart';
import 'package:tcc_flutter/services/mqtt_manager.dart';
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

  // --- Command confirmation tracking -----------------------------------
  // These track, per channel, whether a value the operator changed has
  // been sent to the device yet, and whether the device has confirmed it
  // (by echoing it back in telemetry). This is what lets the UI show
  // "sending...", "confirmed" or "no response" instead of just silently
  // hoping the command landed.

  // AO: value the operator changed but hasn't pressed "Enviar valor" for
  // yet. While dirty, live telemetry is not allowed to overwrite the
  // slider/textfield, so the operator never loses an in-progress edit.
  final List<bool> _aoDirty = List.filled(4, false);

  // AO: value that was sent and is waiting for the device to echo it back
  // via telemetry.
  final List<double?> _aoPendingValue = List.filled(4, null);
  final List<DateTime?> _aoPendingSince = List.filled(4, null);
  final List<bool> _aoFailed = List.filled(4, false);

  // DO: same idea as AO pending, but there's no separate "dirty" step
  // since toggling a switch sends the command immediately.
  final List<bool?> _doPendingValue = List.filled(4, null);
  final List<DateTime?> _doPendingSince = List.filled(4, null);
  final List<bool> _doFailed = List.filled(4, false);

  Timer? _pendingWatchdog;
  static const Duration _pendingTimeout = Duration(seconds: 4);

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
            final pending = _aoPendingValue[i];

            if (pending != null) {
              final matches =
                  t.ao[i].toStringAsFixed(widget.aoCfg[i].decimals) ==
                  pending.toStringAsFixed(widget.aoCfg[i].decimals);

              if (matches) {
                // Device confirmed the value we sent.
                _aoPendingValue[i] = null;
                _aoPendingSince[i] = null;
                _aoFailed[i] = false;
                aoValues[i] = t.ao[i];
                aoControllers[i].text = aoValues[i].toStringAsFixed(
                  widget.aoCfg[i].decimals,
                );
              }
              // Still waiting for confirmation — keep showing the target
              // value and ignore this telemetry sample for this channel.
              continue;
            }

            if (_editingAO[i] || _aoDirty[i]) {
              // Operator has an unsent local edit — don't let telemetry
              // clobber it.
              continue;
            }

            aoValues[i] = t.ao[i];
            aoControllers[i].text = aoValues[i].toStringAsFixed(
              widget.aoCfg[i].decimals,
            );
          }

          for (int i = 0; i < doStates.length; i++) {
            final pending = _doPendingValue[i];

            if (pending != null) {
              if ((t.doo[i] == 1) == pending) {
                _doPendingValue[i] = null;
                _doPendingSince[i] = null;
                _doFailed[i] = false;
                doStates[i] = pending;
              }
              // Still waiting — keep showing the optimistic target state.
              continue;
            }

            doStates[i] = t.doo[i] == 1;
          }
        });
      });

      // Optional: request the current state.
      mqttManager.publish(
        'device/${widget.device.deviceId}/control',
        jsonEncode({'state': true}),
      );
      mqttManager.publish(
        'device/${widget.device.deviceId}/control',
        jsonEncode({'manual': true}),
      );
    });

    // Periodically checks for commands that were sent but never confirmed
    // by the device within the timeout, so the UI can surface a clear
    // "no response" state instead of spinning forever.
    _pendingWatchdog = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (!mounted) return;

      final now = DateTime.now();
      var changed = false;

      for (int i = 0; i < 4; i++) {
        if (_aoPendingSince[i] != null &&
            now.difference(_aoPendingSince[i]!) > _pendingTimeout) {
          _aoPendingValue[i] = null;
          _aoPendingSince[i] = null;
          _aoFailed[i] = true;
          changed = true;
        }
        if (_doPendingSince[i] != null &&
            now.difference(_doPendingSince[i]!) > _pendingTimeout) {
          _doPendingValue[i] = null;
          _doPendingSince[i] = null;
          _doFailed[i] = true;
          changed = true;
        }
      }

      if (changed) setState(() {});
    });
  }

  @override
  void dispose() {
    _telemetryKeepAlive?.cancel();
    _pendingWatchdog?.cancel();

    mqttManager.publish(
      'device/${widget.device.deviceId}/control',
      jsonEncode({'manual': false}),
    );

    super.dispose();
  }

  void _sendAoValue(int i) {
    setState(() {
      _aoDirty[i] = false;
      _aoFailed[i] = false;
      _aoPendingValue[i] = aoValues[i];
      _aoPendingSince[i] = DateTime.now();
    });

    mqttManager.publish(
      'device/${widget.device.deviceId}/control',
      jsonEncode({
        'ao': {'index': i, 'value': aoValues[i]},
      }),
    );
  }

  void _toggleDo(int i, bool v) {
    setState(() {
      doStates[i] = v; // optimistic UI
      _doFailed[i] = false;
      _doPendingValue[i] = v;
      _doPendingSince[i] = DateTime.now();
    });

    mqttManager.publish(
      'device/${widget.device.deviceId}/control',
      jsonEncode({
        'do': {'index': i, 'value': v ? 1 : 0},
      }),
    );
  }

  // Small inline status row shown under a control: sending / confirmation
  // failed / unsent local edit. Returns null when there's nothing to show.
  Widget? _statusRow({
    required bool pending,
    required bool failed,
    bool dirty = false,
  }) {
    if (pending) {
      return const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          SizedBox(width: 6),
          Text(
            'Enviando...',
            style: TextStyle(fontSize: 12, color: Colors.white54),
          ),
        ],
      );
    }

    if (failed) {
      return const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.error_outline, size: 14, color: Colors.redAccent),
          SizedBox(width: 4),
          Text(
            'Sem confirmação do dispositivo — tente novamente',
            style: TextStyle(fontSize: 12, color: Colors.redAccent),
          ),
        ],
      );
    }

    if (dirty) {
      return const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.edit, size: 13, color: Colors.orangeAccent),
          SizedBox(width: 4),
          Text(
            'Alterado — clique em "Enviar valor"',
            style: TextStyle(fontSize: 12, color: Colors.orangeAccent),
          ),
        ],
      );
    }

    return null;
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
        final status = _statusRow(
          pending: _doPendingValue[i] != null,
          failed: _doFailed[i],
        );

        return Card(
          color: const Color(0xFF1B1B1B),
          margin: const EdgeInsets.symmetric(vertical: 6),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          child: SwitchListTile(
            title: Text(c.name),
            subtitle: status == null
                ? null
                : Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: status,
                  ),
            value: doStates[i],
            onChanged: (v) => _toggleDo(i, v),
          ),
        );
      }),
    );
  }

  Widget _analogOutputs() {
    return Column(
      children: List.generate(widget.aoCfg.length, (i) {
        final c = widget.aoCfg[i];
        final pending = _aoPendingValue[i] != null;
        final status = _statusRow(
          pending: pending,
          failed: _aoFailed[i],
          dirty: _aoDirty[i],
        );

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
                            _aoDirty[i] = true;
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
                            _aoDirty[i] = true;
                            // Typing is done — release the edit lock so
                            // telemetry can resume updating this channel
                            // once it's no longer dirty/pending.
                            _editingAO[i] = false;
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

                if (status != null) ...[
                  const SizedBox(height: 6),
                  status,
                ],

                const SizedBox(height: 6),

                ElevatedButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: pending
                        ? const Color.fromARGB(255, 90, 90, 90)
                        : const Color.fromARGB(255, 63, 146, 66),
                  ),
                  onPressed: pending ? null : () => _sendAoValue(i),
                  icon: pending
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white70,
                          ),
                        )
                      : const Icon(Icons.send),
                  label: Text(
                    pending ? 'Enviando...' : 'Enviar valor',
                    style: const TextStyle(color: Colors.white),
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
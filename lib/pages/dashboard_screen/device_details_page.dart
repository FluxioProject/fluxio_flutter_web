import 'dart:async';
import 'package:flutter/material.dart';
import 'package:tcc_flutter/backend_api/api_communication.dart';
import 'package:tcc_flutter/pages/dashboard_screen/device_command_page.dart';
import 'package:tcc_flutter/pages/dashboard_screen/drag_n_drop.dart';
import 'package:tcc_flutter/pages/dashboard_screen/edit_channel.dart';
import 'package:tcc_flutter/pages/dashboard_screen/export_matlab_dialog.dart';
import 'package:tcc_flutter/pages/dashboard_screen/fw_upload.dart';
import 'package:tcc_flutter/pages/dashboard_screen/widgets/graph.dart';
import 'package:tcc_flutter/services/app_state.dart';
import 'package:tcc_flutter/widgets/show_message.dart';
import 'package:tcc_flutter/models/channel_config.dart';
import 'package:tcc_flutter/models/device.dart';
import 'package:tcc_flutter/models/telemetry.dart';
import 'package:tcc_flutter/widgets/gradient_bg.dart';
import '../../services/mqtt_manager.dart';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

enum ViewMode { compact, detailed }

class AlarmEvent {
  final DateTime time;
  final String channel;
  final double value;
  final double min;
  final double max;
  final bool high;

  AlarmEvent({
    required this.time,
    required this.channel,
    required this.value,
    required this.min,
    required this.max,
    required this.high,
  });
}

class DeviceDetailsPage extends StatefulWidget {
  final Device device;
  const DeviceDetailsPage({super.key, required this.device});

  @override
  State<DeviceDetailsPage> createState() => _DeviceDetailsPageState();
}

class _DeviceDetailsPageState extends State<DeviceDetailsPage> {
  late final String topicTelemetry;
  late final String topicControl;
  late final String topicStatus;

  bool subscribed = false;

  Telemetry? last;
  DateTime? lastRx;

  ViewMode viewMode = ViewMode.compact;

  final List<List<SparkPoint>> aiHistory = List.generate(4, (_) => []);
  final List<List<SparkPoint>> aoHistory = List.generate(4, (_) => []);
  final List<List<SparkPoint>> diHistory = List.generate(4, (_) => []);
  final List<List<SparkPoint>> doHistory = List.generate(4, (_) => []);
  final List<ChannelConfig> aiCfg = List.generate(
    4,
    (i) => ChannelConfig(name: 'AI ${i + 1}'),
  );

  final List<ChannelConfig> aoCfg = List.generate(
    4,
    (i) => ChannelConfig(name: 'AO ${i + 1}'),
  );

  final List<ChannelConfig> diCfg = List.generate(
    4,
    (i) => ChannelConfig(name: 'DI ${i + 1}', analog: false),
  );

  final List<ChannelConfig> doCfg = List.generate(
    4,
    (i) => ChannelConfig(name: 'DO ${i + 1}', analog: false),
  );

  Timer? _watchdogTimer;
  Timer? _telemetryKeepAlive;
  static const int telemetryTimeoutSec = 5;
  DateTime? _watchdogStart;
  bool _loadingChannels = true;
  bool _loadingMQTT = true;

  // Live uptime value, fed by the device/{id}/status topic (see
  // _onStatusMessage). widget.device.uptimeSec is just a frozen snapshot
  // taken when this screen was pushed — it never changes on its own, no
  // matter how often the widget rebuilds. CardsPage's DeviceCard ticks
  // because CardsPage is subscribed to /status and updates appState.devices
  // every time a status message arrives; this screen never subscribed to
  // /status at all (only /telemetry), so uptime just sat frozen. Starts as
  // the snapshot value so something reasonable shows before the first live
  // status message arrives.
  int? _uptimeSec;
  String? _currentFwVersion;

  bool get isStale =>
      lastRx == null || DateTime.now().difference(lastRx!).inSeconds >= 2;

  // Watchdog retry logic. While telemetry is stale it keeps nudging the
  // device with "telemetry: true" every retryIntervalSec, since the socket
  // can (and does, per mqtt_manager's autoReconnect) come back on its own
  // and we don't want to require a manual step to resume telemetry.
  //
  // However, if telemetry stays stale for longer than
  // disconnectTimeoutSec, we stop retrying and leave the screen instead of
  // waiting forever — a dashboard with a dead device is not useful, and
  // the operator is better served by being sent back to the device list
  // (where the "Desconectado" status is visible) than by staring at a
  // frozen/stale screen indefinitely.
  static const int retryIntervalSec = 2;
  static const int disconnectTimeoutSec = 20;

  // Timestamp of the last retry attempt, tracked separately from
  // _watchdogStart so that sending a retry doesn't distort the timeout
  // math used to decide whether telemetry is still flowing.
  DateTime? _lastRetryAt;

  // How long we allow the initial "loading device" screen to spin before
  // giving up. Covers both cases: backend channel config taking too long,
  // and MQTT never completing its first connect (e.g. bad credentials,
  // broker unreachable) — without this the loading screen could hang
  // forever with no feedback to the operator.
  static const int loadingTimeoutSec = 5;
  Timer? _loadingTimeoutTimer;

  // Guards against calling Navigator.pop / showMessage more than once
  // (e.g. watchdog timeout firing again before the pop finishes).
  bool _leavingScreen = false;

  final List<AlarmEvent> alarmHistory = [];

  AlarmEvent? lastAlarm;

  @override
  void initState() {
    super.initState();

    topicTelemetry = 'device/${widget.device.deviceId}/telemetry';
    topicControl = 'device/${widget.device.deviceId}/control';
    topicStatus = 'device/${widget.device.deviceId}/status';

    _uptimeSec = widget.device.uptimeSec;
    _currentFwVersion = widget.device.fwVersion;

    // Resubscribing the socket after an auto-reconnect does NOT tell the
    // ESP to resume publishing telemetry — the device auto-disables
    // telemetry after 10s without a fresh "telemetry: true" command. So
    // as soon as the socket comes back, re-arm it immediately instead of
    // waiting for the next scheduled keepalive tick.
    mqttManager.isReconnectingNotifier.addListener(_onReconnectingChanged);

    _loadingTimeoutTimer = Timer(
      const Duration(seconds: loadingTimeoutSec),
      _onLoadingTimeout,
    );

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      appState.refreshLatestFirmwareVersion(
        deviceId: widget.device.deviceId,
        context: context,
      );

      await mqttManager.initializeMqtt(context, true);
      await _loadAllChannelsFromBackend();
      await _loadChannelPrefs();
      _trySubscribe();
    });
  }

  // Fires if the device hasn't finished loading (backend channels +
  // first telemetry) within loadingTimeoutSec. Leaves the screen instead
  // of leaving the operator stuck on a spinner.
  void _onLoadingTimeout() {
    if (!mounted) return;
    if (_loadingChannels || _loadingMQTT) {
      _leaveScreen(
        'Não foi possível conectar ao dispositivo. Verifique se ele está ligado e tente novamente.',
      );
    }
  }

  // Cancels the loading timeout once both the backend channel config and
  // the first telemetry message have arrived.
  void _cancelLoadingTimeoutIfDone() {
    if (!_loadingChannels && !_loadingMQTT) {
      _loadingTimeoutTimer?.cancel();
    }
  }

  // Central "give up and go back" path, used both by the loading timeout
  // and by the telemetry watchdog when the device stays unreachable for
  // too long. Safe to call more than once.
  void _leaveScreen(String message) {
    if (_leavingScreen || !mounted) return;
    _leavingScreen = true;

    _watchdogTimer?.cancel();
    _telemetryKeepAlive?.cancel();
    _loadingTimeoutTimer?.cancel();

    showMessage(context, message, true);
    Navigator.of(context).maybePop();
  }

  void _onReconnectingChanged() {
    if (!mounted) return;

    if (!mqttManager.isReconnectingNotifier.value) {
      // Just finished reconnecting.
      mqttManager.publish(topicControl, jsonEncode({'telemetry': true}));
    }

    setState(() {});
  }

  Future<void> _loadAllChannelsFromBackend() async {
    try {
      final res = await Session().getObj(
        'devices/get-all-channels?deviceId=${widget.device.deviceId}',
        context,
      );

      if (res is! Map<String, dynamic>) return;

      void applyCfg(
        List<ChannelConfig> list,
        Map<String, dynamic>? data,
        bool analog,
      ) {
        if (data == null) return;

        data.forEach((key, value) {
          final index = int.tryParse(key);
          if (index == null || index >= list.length) return;

          final c = list[index];

          c
            ..name = value['channelName']?.toString() ?? c.name
            ..notifyMobile = value['notifyMobile'] ?? false
            ..notifyEmail = value['notifyEmail'] ?? false
            ..notifySms = value['notifySms'] ?? false;

          if (analog) {
            c
              ..min = (value['min'] ?? c.min).toDouble()
              ..max = (value['max'] ?? c.max).toDouble()
              ..mapMin = (value['mapMin'] ?? c.mapMin).toDouble()
              ..mapMax = (value['mapMax'] ?? c.mapMax).toDouble();
          }
        });
      }

      applyCfg(aiCfg, res['ai'], true);
      applyCfg(aoCfg, res['ao'], true);
      applyCfg(diCfg, res['di'], false);
      applyCfg(doCfg, res['do'], false);

      setState(() {});
    } catch (e) {
      showMessage(context, 'Erro ao carregar canais: $e', true);
    } finally {
      if (mounted) {
        setState(() => _loadingChannels = false);
        _cancelLoadingTimeoutIfDone();
      }
    }
  }

  Future<void> _loadChannelPrefs() async {
    final prefs = await SharedPreferences.getInstance();

    void apply(List<ChannelConfig> list, String type) {
      for (int i = 0; i < list.length; i++) {
        final key = 'device_${widget.device.deviceId}_${type}_$i';
        final raw = prefs.getString(key);
        if (raw == null) continue;

        final data = jsonDecode(raw) as Map<String, dynamic>;
        final c = list[i];

        c
          ..unit = data['unit'] ?? c.unit
          ..decimals = data['decimals'] ?? c.decimals
          ..visible = data['visible'] ?? c.visible;
      }
    }

    apply(aiCfg, 'ai');
    apply(aoCfg, 'ao');
    apply(diCfg, 'di');
    apply(doCfg, 'do');
  }

  Future<void> _saveChannelPref(ChannelConfig c) async {
    final prefs = await SharedPreferences.getInstance();

    String type;
    int index;

    if (aiCfg.contains(c)) {
      type = 'ai';
      index = aiCfg.indexOf(c);
    } else if (aoCfg.contains(c)) {
      type = 'ao';
      index = aoCfg.indexOf(c);
    } else if (diCfg.contains(c)) {
      type = 'di';
      index = diCfg.indexOf(c);
    } else {
      type = 'do';
      index = doCfg.indexOf(c);
    }

    final key = 'device_${widget.device.deviceId}_${type}_$index';

    await prefs.setString(
      key,
      jsonEncode({
        'name': c.name,
        'unit': c.unit,
        'min': c.min,
        'max': c.max,
        'decimals': c.decimals,
        'visible': c.visible,
        'notifyMobile': c.notifyMobile,
        'notifyEmail': c.notifyEmail,
        'notifySms': c.notifySms,
      }),
    );
  }

  void _trySubscribe() {
    if (mqttManager.isConnected()) {
      _subscribe();
    } else {
      mqttManager.isLoadingNotifier.addListener(() {
        if (!subscribed && mqttManager.isConnected()) _subscribe();
      });
    }
  }

  final List<bool> _aiAlarmState = List.filled(4, false);

  void _checkAlarms() {
    if (last == null) return;

    for (int i = 0; i < 4; i++) {
      final value = last!.ai[i];
      final cfg = aiCfg[i];

      final alarm = value < cfg.min || value > cfg.max;

      if (alarm && !_aiAlarmState[i]) {
        _aiAlarmState[i] = true;

        final event = AlarmEvent(
          time: DateTime.now(),
          channel: cfg.name,
          value: value,
          min: cfg.min,
          max: cfg.max,
          high: value > cfg.max,
        );

        alarmHistory.insert(0, event);
        lastAlarm = event;
      }

      if (!alarm) {
        _aiAlarmState[i] = false;
      }
    }
  }

  void _subscribe() {
    subscribed = true;

    mqttManager.publish(topicControl, jsonEncode({'telemetry': true}));

    _telemetryKeepAlive?.cancel();
    _telemetryKeepAlive = Timer.periodic(const Duration(seconds: 5), (_) {
      mqttManager.publish(topicControl, jsonEncode({'telemetry': true}));
    });

    mqttManager.subscribe(topicTelemetry, (message) {
      try {
        final t = Telemetry.fromJson(message);
        print('telemetry: $message');
        setState(() {
          _loadingMQTT = false;
          last = t;
          lastRx = DateTime.now();
          _watchdogStart = lastRx;

          // Telemetry actually arrived, so the device is alive again.
          // Reset the retry throttle here so the next stall starts a
          // fresh retry cadence instead of inheriting an old timestamp.
          _lastRetryAt = null;

          for (int i = 0; i < 4; i++) {
            aiHistory[i].add(SparkPoint(t.ai[i], DateTime.now()));
            aoHistory[i].add(SparkPoint(t.ao[i], DateTime.now()));
            diHistory[i].add(SparkPoint(t.di[i].toDouble(), DateTime.now()));
            doHistory[i].add(SparkPoint(t.doo[i].toDouble(), DateTime.now()));

            if (aiHistory[i].length > 300) aiHistory[i].removeAt(0);
            if (aoHistory[i].length > 300) aoHistory[i].removeAt(0);
            if (diHistory[i].length > 300) diHistory[i].removeAt(0);
            if (doHistory[i].length > 300) doHistory[i].removeAt(0);
          }
          _checkAlarms();
        });
        _cancelLoadingTimeoutIfDone();
      } catch (_) {}
    });

    // NEW: same status topic + payload shape CardsPage._handleStatusMessage
    // already parses ('uptime' field). This is what actually keeps the
    // Uptime chip live — without this subscription, uptimeSec never gets
    // a fresh value no matter how often the screen rebuilds.
    mqttManager.subscribe(topicStatus, _onStatusMessage);

    _watchdogStart = DateTime.now();
    _startWatchdog();
  }

  // NEW: parses the device's status payload and updates the live uptime
  // shown in the AppBar. Mirrors CardsPage._handleStatusMessage, but only
  // cares about the 'uptime' field here — online/ip are already tracked
  // via widget.device / the watchdog on this screen.
  void _onStatusMessage(String payload) {
    try {
      final decoded = jsonDecode(payload);
      if (decoded is! Map<String, dynamic>) return;

      final uptime = decoded['uptime'] as int?;
      final fwVersion = decoded['fwVersion'] as String?; // NEW

      if (!mounted) return;
      setState(() {
        if (uptime != null) _uptimeSec = uptime;
        if (fwVersion != null) _currentFwVersion = fwVersion; // NEW
      });
    } catch (_) {}
  }

  void _startWatchdog() {
    _watchdogTimer?.cancel();
    _lastRetryAt = null;

    _watchdogTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;

      final now = DateTime.now();

      // If nothing has been received yet, use the start time.
      final referenceTime = lastRx ?? _watchdogStart;

      if (referenceTime == null) return;

      final diffSinceLastData = now.difference(referenceTime).inSeconds;

      // Past the hard timeout: stop retrying and leave the screen. This
      // is a deliberate give-up point — below it we keep nudging the
      // device indefinitely, but a device that's still unreachable after
      // disconnectTimeoutSec is treated as actually disconnected, and the
      // operator is taken back instead of watching a stale dashboard.
      if (diffSinceLastData >= disconnectTimeoutSec) {
        _leaveScreen('Conexão com o dispositivo perdida.');
        return;
      }

      if (diffSinceLastData < telemetryTimeoutSec) {
        // Telemetry hasn't timed out — nothing to do.
        return;
      }

      // We're past the timeout. Only fire a new retry if enough time has
      // passed since the previous one.
      final canRetryNow =
          _lastRetryAt == null ||
          now.difference(_lastRetryAt!).inSeconds >= retryIntervalSec;

      if (!canRetryNow) return;

      _lastRetryAt = now;

      // Refresh the UI so the "sem dados recentes" banner reflects the
      // current stale state, and keep nudging the device while we're
      // still under disconnectTimeoutSec: the connection can come back on
      // its own (mqtt_manager already handles socket-level auto-reconnect)
      // and when it does, this same command is what brings telemetry back
      // without any manual step.
      setState(() {});
      mqttManager.publish(topicControl, jsonEncode({'telemetry': true}));
    });
  }

  Future<void> _confirmSendCommand() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: const [
            Icon(Icons.warning_amber_rounded, color: Colors.orange),
            SizedBox(width: 8),
            Text('Atenção'),
          ],
        ),
        content: const Text(
          'O envio de comandos pode causar alterações físicas no equipamento.\n\n'
          'Prossiga somente se tiver certeza do que está fazendo.\n\n'
          'A responsabilidade pelo uso é inteiramente do operador.\n\n'
          'Ao entrar nessa tela você entrará no modo manual,\nque desabilita a lógica automática e as saídas responderão somente aos comandos manuais.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color.fromARGB(255, 63, 146, 66),
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              'Entendi, continuar',
              style: TextStyle(color: Colors.white),
            ),
          ),
        ],
      ),
    );

    if (confirm == true) {
      _pauseWatchdog();

      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => DeviceCommandPage(
            device: widget.device,
            aoCfg: aoCfg,
            doCfg: doCfg,
          ),
        ),
      );

      // When returning from the command screen.
      _resumeWatchdog();
    }
  }

  void _pauseWatchdog() {
    _watchdogTimer?.cancel();
    _watchdogTimer = null;
  }

  void _resumeWatchdog() {
    _watchdogStart = DateTime.now();

    mqttManager.publish(topicControl, jsonEncode({'telemetry': true}));

    _telemetryKeepAlive?.cancel();
    _telemetryKeepAlive = Timer.periodic(const Duration(seconds: 5), (_) {
      mqttManager.publish(topicControl, jsonEncode({'telemetry': true}));
    });

    _startWatchdog();
  }

  @override
  void dispose() {
    _watchdogTimer?.cancel();
    _telemetryKeepAlive?.cancel();
    _loadingTimeoutTimer?.cancel();
    mqttManager.isReconnectingNotifier.removeListener(_onReconnectingChanged);

    if (subscribed) {
      mqttManager.publish(topicControl, jsonEncode({'telemetry': false}));
      mqttManager.unsubscribe(topicTelemetry);
      mqttManager.unsubscribe(topicStatus);
      // Do not disconnect here because CardsPage shares the MQTT connection.
    }
    super.dispose();
  }

  // Small pill-style badge used in the AppBar title (status / firmware).
  // Uses a plain painted circle for the leading dot instead of an Icon
  // glyph — tiny icon glyphs can fail to render on web at this size,
  // leaving a blank gap or nothing at all, while a Container always
  // paints regardless of icon font loading.
  Widget _appBarChip({
    required String label,
    required Color color,
    bool dot = false,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withOpacity(0.4), width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (dot) ...[
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 5),
          ],
          SelectableText(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w500,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  void _showAlarmHistory() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Histórico de alertas'),
        content: SizedBox(
          width: 500,
          height: 400,
          child: ListView.builder(
            itemCount: alarmHistory.length,
            itemBuilder: (_, i) {
              final a = alarmHistory[i];

              return ListTile(
                leading: const Icon(
                  Icons.warning_amber_rounded,
                  color: Colors.red,
                ),
                title: Text(a.channel),
                subtitle: Text(
                  '${a.high ? "Acima" : "Abaixo"} do limite\n'
                  'Valor: ${a.value.toStringAsFixed(2)}',
                ),
                trailing: Text(
                  '${a.time.hour.toString().padLeft(2, '0')}:'
                  '${a.time.minute.toString().padLeft(2, '0')}:'
                  '${a.time.second.toString().padLeft(2, '0')}',
                ),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              setState(() {
                alarmHistory.clear();
                lastAlarm = null;
              });
              Navigator.pop(context);
            },
            child: const Text('Limpar histórico'),
          ),

          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Fechar'),
          ),
        ],
      ),
    );
  }

  String formatUptime(int seconds) {
    final d = Duration(seconds: seconds);

    if (d.inDays > 0) {
      return '${d.inDays}d ${d.inHours.remainder(24)}h';
    }

    if (d.inHours > 0) {
      return '${d.inHours}h ${d.inMinutes.remainder(60)}m';
    }

    if (d.inMinutes > 0) {
      return '${d.inMinutes}m ${d.inSeconds.remainder(60)}s';
    }

    return '${d.inSeconds}s';
  }

  String _formatAlarmTime(DateTime t) {
    return '${t.day.toString().padLeft(2, '0')}/'
        '${t.month.toString().padLeft(2, '0')}/'
        '${t.year} '
        '${t.hour.toString().padLeft(2, '0')}:'
        '${t.minute.toString().padLeft(2, '0')}:'
        '${t.second.toString().padLeft(2, '0')}';
  }

  // Two-line AppBar title: device name on top, status + firmware chips
  // below. The IP address is intentionally left out of the AppBar — it's
  // not something the operator needs to see at a glance; it can live in
  // a "device information" panel/dialog instead if needed later.
  //
  // uptimeLabel now reads _uptimeSec, which is kept live by
  // _onStatusMessage (subscribed to topicStatus in _subscribe) — the same
  // 'uptime' field CardsPage already parses from device/{id}/status —
  // instead of the frozen widget.device.uptimeSec snapshot taken when this
  // screen was pushed.
  Widget _buildAppBarTitle() {
    final connected = widget.device.isConnected;
    final statusColor = connected ? Colors.greenAccent : Colors.redAccent;
    final statusLabel = connected ? 'Conectado' : 'Desconectado';
    final fwLabel = 'FW ${_currentFwVersion ?? 'v1.0.0'}';

    final uptimeLabel = _uptimeSec != null
        ? 'Uptime ${formatUptime(_uptimeSec!)}'
        : 'Uptime N/D';

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          widget.device.name,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
        ),

        const SizedBox(height: 2),

        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _appBarChip(label: statusLabel, color: statusColor, dot: true),

            const SizedBox(width: 6),

            _appBarChip(label: fwLabel, color: Colors.white60),

            const SizedBox(width: 6),

            _appBarChip(label: uptimeLabel, color: Colors.white60),

            if (lastAlarm != null) ...[
              const SizedBox(width: 6),

              MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  onTap: _showAlarmHistory,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 0,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.redAccent.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: Colors.redAccent.withOpacity(0.4),
                        width: 1,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.warning_amber_rounded,
                          color: Colors.redAccent,
                          size: 14,
                        ),

                        const SizedBox(width: 5),

                        Flexible(
                          child: Text(
                            '${lastAlarm!.channel} acima do limite '
                            '• ${_formatAlarmTime(lastAlarm!.time)} '
                            '(${alarmHistory.length})',
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 11,
                              color: Colors.redAccent,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),

                        const SizedBox(width: 4),

                        InkWell(
                          borderRadius: BorderRadius.circular(20),
                          onTap: () {
                            setState(() {
                              lastAlarm = null;
                            });
                          },
                          child: const Padding(
                            padding: EdgeInsets.all(2),
                            child: Icon(
                              Icons.delete_outline,
                              size: 16,
                              color: Colors.white60,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }

  // Slim banner shown when telemetry is stale and/or the socket is
  // actively reconnecting, so the operator knows the app is still trying
  // instead of assuming it silently gave up. Once diffSinceLastData
  // crosses disconnectTimeoutSec the watchdog leaves the screen instead,
  // so this banner only needs to cover the "still retrying" window.
  Widget? _connectionBanner() {
    final reconnectingSocket = mqttManager.isReconnectingNotifier.value;
    final staleData =
        lastRx != null &&
        DateTime.now().difference(lastRx!).inSeconds >= telemetryTimeoutSec;

    if (!reconnectingSocket && !staleData) return null;

    final label = reconnectingSocket
        ? 'Reconectando ao servidor...'
        : 'Sem dados recentes do dispositivo — tentando reconectar...';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      color: Colors.orange.withOpacity(0.15),
      child: Row(
        children: [
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: Colors.orangeAccent,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
                color: Colors.orangeAccent,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return _loadingChannels || _loadingMQTT
        ? Scaffold(
            backgroundColor: const Color(0xFF0F0F0F),
            body: Center(
              child: Container(
                width: 360,
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E1E1E),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: Colors.white12),
                  boxShadow: const [
                    BoxShadow(
                      color: Colors.black54,
                      blurRadius: 12,
                      offset: Offset(0, 6),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: const [
                    CircularProgressIndicator(
                      strokeWidth: 3,
                      color: Color.fromARGB(255, 63, 146, 66),
                    ),
                    SizedBox(height: 20),
                    Text(
                      'Carregando configurações do dispositivo\ne tentando conectar',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 16,
                        color: Colors.white70,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          )
        : Scaffold(
            appBar: AppBar(
              backgroundColor: const Color.fromARGB(255, 35, 35, 35),
              toolbarHeight: 72,
              title: _buildAppBarTitle(),
              leading: IconButton(
                tooltip: 'Voltar',
                icon: const Icon(Icons.arrow_back),
                onPressed: () => Navigator.of(context).maybePop(),
              ),
              actions: [
                IconButton(
                  tooltip: 'Histórico',
                  splashRadius: 24,
                  iconSize: 24,
                  icon: const Icon(Icons.history, color: Colors.white70),
                  onPressed: _showAlarmHistory,
                ),
                IconButton(
                  tooltip: 'Exportar trace (MATLAB)',
                  icon: const Icon(Icons.insert_chart_outlined),
                  onPressed: () => showExportMatlabDialog(
                    context: context,
                    deviceName: widget.device.name,
                    deviceId: widget.device.deviceId,
                    aiHistory: aiHistory,
                    aoHistory: aoHistory,
                    diHistory: diHistory,
                    doHistory: doHistory,
                    aiCfg: aiCfg,
                    aoCfg: aoCfg,
                    diCfg: diCfg,
                    doCfg: doCfg,
                  ),
                ),
                IconButton(
                  tooltip: 'Gerenciar cards',
                  icon: const Icon(Icons.tune),
                  onPressed: _manageVisibility,
                ),
                IconButton(
                  tooltip: viewMode == ViewMode.compact
                      ? 'Modo detalhado'
                      : 'Modo compacto',
                  icon: Icon(
                    viewMode == ViewMode.compact
                        ? Icons.view_agenda
                        : Icons.view_module,
                  ),
                  onPressed: () {
                    setState(() {
                      viewMode = viewMode == ViewMode.compact
                          ? ViewMode.detailed
                          : ViewMode.compact;
                    });
                  },
                ),
                IconButton(
                  tooltip: 'Enviar comando',
                  icon: const Icon(Icons.near_me_rounded),
                  onPressed: _confirmSendCommand,
                ),
                IconButton(
                  tooltip: 'Programar dispositivo',
                  icon: const Icon(Icons.settings_applications_sharp),
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => VisualLogicBuilderPage(
                          device: widget.device,
                          aiCfg: aiCfg,
                          diCfg: diCfg,
                          aoCfg: aoCfg,
                          doCfg: doCfg,
                        ),
                      ),
                    );
                  },
                ),
                IconButton(
                  tooltip: 'Upload de firmware',
                  icon: const Icon(Icons.cloud_upload),
                  onPressed: () {
                    showDialog(
                      context: context,
                      barrierDismissible: false,
                      builder: (_) => FirmwareUploadDialog(
                        deviceId: widget.device.deviceId,
                      ),
                    );
                  },
                ),
                SizedBox(width: 8),
              ],
            ),
            body: Stack(
              children: [
                Builder(
                  builder: (_) {
                    final banner = _connectionBanner();
                    return GradientBackground(
                      image: false,
                      child: Column(
                        children: [
                          if (banner != null) banner,
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Column(
                                children: [Expanded(child: _ioTab(last))],
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),

                if (_loadingChannels)
                  Container(
                    color: Colors.black.withOpacity(0.6),
                    child: const Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CircularProgressIndicator(),
                          SizedBox(height: 14),
                          Text(
                            'Carregando configurações do dispositivo...',
                            style: TextStyle(color: Colors.white70),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          );
  }

  void _manageVisibility() {
    showDialog(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Gerenciar cards'),
          content: SizedBox(
            width: 360,
            child: ListView(
              shrinkWrap: true,
              children: [
                // Analog inputs
                if (aiCfg.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  const Padding(
                    padding: EdgeInsets.fromLTRB(12, 8, 12, 4),
                    child: Text(
                      'Entradas Analógicas',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const Divider(height: 8),
                  ...aiCfg.map(
                    (c) => CheckboxListTile(
                      title: Text(c.name),
                      value: c.visible,
                      onChanged: (v) {
                        setLocal(() => c.visible = v ?? true);
                        setState(() {});
                        _saveChannelPref(c);
                      },
                    ),
                  ),
                ],

                // Analog outputs
                if (aoCfg.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  const Padding(
                    padding: EdgeInsets.fromLTRB(12, 8, 12, 4),
                    child: Text(
                      'Saídas Analógicas',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const Divider(height: 8),
                  ...aoCfg.map(
                    (c) => CheckboxListTile(
                      title: Text(c.name),
                      value: c.visible,
                      onChanged: (v) {
                        setLocal(() => c.visible = v ?? true);
                        setState(() {});
                        _saveChannelPref(c);
                      },
                    ),
                  ),
                ],

                // Digital inputs
                if (diCfg.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  const Padding(
                    padding: EdgeInsets.fromLTRB(12, 8, 12, 4),
                    child: Text(
                      'Entradas Digitais',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const Divider(height: 8),
                  ...diCfg.map(
                    (c) => CheckboxListTile(
                      title: Text(c.name),
                      value: c.visible,
                      onChanged: (v) {
                        setLocal(() => c.visible = v ?? true);
                        setState(() {});
                        _saveChannelPref(c);
                      },
                    ),
                  ),
                ],

                // Digital outputs
                if (doCfg.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  const Padding(
                    padding: EdgeInsets.fromLTRB(12, 8, 12, 4),
                    child: Text(
                      'Saídas Digitais',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const Divider(height: 8),
                  ...doCfg.map(
                    (c) => CheckboxListTile(
                      title: Text(c.name),
                      value: c.visible,
                      onChanged: (v) {
                        setLocal(() => c.visible = v ?? true);
                        setState(() {});
                        _saveChannelPref(c);
                      },
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Fechar'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _ioTab(Telemetry? t) {
    return SingleChildScrollView(
      child: Column(
        children: [
          _section('Entradas Analógicas', aiCfg, t?.ai, _aiCard),
          const SizedBox(height: 12),
          _section('Saídas Analógicas', aoCfg, t?.ao, _aoCard),
          const SizedBox(height: 12),
          _section('Entradas Digitais', diCfg, t?.di, _diCard),
          const SizedBox(height: 12),
          _section('Saídas Digitais', doCfg, t?.doo, _doCard),
        ],
      ),
    );
  }

  Widget _section<T>(
    String title,
    List<ChannelConfig> cfg,
    List<T>? values,
    Widget Function(int, T?) builder,
  ) {
    final visibleIdx = [
      for (int i = 0; i < cfg.length; i++)
        if (cfg[i].visible) i,
    ];

    if (visibleIdx.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
        ),
        const SizedBox(height: 10),
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: viewMode == ViewMode.compact ? 4 : 2,
            childAspectRatio: viewMode == ViewMode.compact ? 3.8 : 2.2,
            crossAxisSpacing: 10,
            mainAxisSpacing: 10,
          ),
          itemCount: visibleIdx.length,
          itemBuilder: (_, j) {
            final i = visibleIdx[j];
            return builder(
              i,
              (values != null && i < values.length) ? values[i] : null,
            );
          },
        ),
        const SizedBox(height: 14),
      ],
    );
  }

  Widget _cardShell({
    required Widget child,
    bool alert = false,
    VoidCallback? onTap,
  }) {
    return Material(
      color: const Color(0xFF1B1B1B),
      elevation: 6,
      shadowColor: Colors.black54,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: alert ? Colors.red : Colors.white10, width: 2),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(padding: const EdgeInsets.all(10), child: child),
      ),
    );
  }

  Widget _sparkline(List<SparkPoint> data) {
    return CustomPaint(painter: SparklinePainter(data), size: Size.infinite);
  }

  void _openFullscreenGraph(String title, List<SparkPoint> data) {
    showDialog(
      context: context,
      builder: (_) => Dialog(
        insetPadding: const EdgeInsets.all(12),
        child: StatefulBuilder(
          builder: (ctx, setLocal) {
            return Column(
              children: [
                AppBar(
                  title: Text(title),
                  backgroundColor: const Color.fromARGB(9, 255, 255, 255),
                  leading: IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(ctx).pop(),
                  ),
                ),
                Expanded(
                  child: AnimatedBuilder(
                    animation: Listenable.merge([
                      mqttManager.isLoadingNotifier,
                    ]),
                    builder: (_, __) {
                      return Padding(
                        padding: const EdgeInsets.all(12),
                        child: CustomPaint(
                          painter: SparklinePainter(data),
                          size: Size.infinite,
                        ),
                      );
                    },
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _aiCard(int i, double? v) {
    final c = aiCfg[i];
    final value = v ?? 0;
    final outOfRange = v != null && (value < c.min || value > c.max);
    final color = outOfRange
        ? Colors.redAccent
        : const Color.fromARGB(255, 167, 167, 167);

    return _cardShell(
      alert: outOfRange,
      onTap: () => showEditChannelDialog(
        deviceId: widget.device.deviceId,
        channelType: 'ai',
        index: i,
        context: context,
        channel: c,
        onSave: () {
          setState(() {});
          _saveChannelPref(c);
        },
      ),
      child: Stack(
        children: [
          // Normal card content
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(c.name, style: const TextStyle(fontSize: 17)),

              SizedBox(
                height:
                    MediaQuery.of(context).size.height *
                    (viewMode == ViewMode.detailed ? 0.01 : 0.028),
              ),

              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 2,
                ),
                decoration: BoxDecoration(
                  color: color.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: color.withOpacity(0.1), width: 1.5),
                ),
                child: Text(
                  '${value.toStringAsFixed(c.decimals)} ${c.unit}'.trim(),
                  style: TextStyle(
                    fontSize: 16,
                    color: outOfRange ? Colors.red : null,
                  ),
                ),
              ),

              if (viewMode == ViewMode.detailed) ...[
                SizedBox(height: MediaQuery.of(context).size.height * 0.028),
                Expanded(
                  child: GestureDetector(
                    onTap: () => _openFullscreenGraph(c.name, aiHistory[i]),
                    child: _sparkline(aiHistory[i]),
                  ),
                ),
              ],
            ],
          ),

          // Alert icon
          if (outOfRange)
            Positioned(
              top: 0,
              right: 0,
              child: Tooltip(
                message:
                    'Valor fora do range configurado (${c.min} – ${c.max})',
                child: const Icon(
                  Icons.warning_amber_rounded,
                  color: Colors.redAccent,
                  size: 18,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _diCard(int i, int? raw) {
    final c = diCfg[i];
    final on = raw == 1;

    return _cardShell(
      onTap: () => showEditChannelDialog(
        deviceId: widget.device.deviceId,
        channelType: 'di',
        index: i,
        context: context,
        channel: c,
        onSave: () {
          setState(() {});
          _saveChannelPref(c);
        },
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(c.name, style: const TextStyle(fontSize: 17)),
          SizedBox(
            height:
                MediaQuery.of(context).size.height *
                (viewMode == ViewMode.detailed ? 0.01 : 0.028),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: on
                  ? Colors.green.withOpacity(0.15)
                  : Colors.red.withOpacity(0.15),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: on ? Colors.green : Colors.redAccent,
                width: 1.2,
              ),
            ),
            child: Text(
              on ? 'ON' : 'OFF',
              style: TextStyle(
                color: on ? Colors.greenAccent : Colors.redAccent,
                fontWeight: FontWeight.bold,
                fontSize: 13,
                letterSpacing: 0.6,
              ),
            ),
          ),
          if (viewMode == ViewMode.detailed) ...[
            SizedBox(height: MediaQuery.of(context).size.height * 0.028),
            Expanded(
              child: GestureDetector(
                onTap: () => _openFullscreenGraph(c.name, diHistory[i]),
                child: _sparkline(diHistory[i]),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _doCard(int i, int? raw) {
    final c = doCfg[i];
    final on = raw == 1;

    return _cardShell(
      onTap: () => showEditChannelDialog(
        deviceId: widget.device.deviceId,
        channelType: 'do',
        index: i,
        context: context,
        channel: c,
        onSave: () {
          setState(() {});
          _saveChannelPref(c);
        },
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(c.name, style: const TextStyle(fontSize: 17)),

          SizedBox(
            height:
                MediaQuery.of(context).size.height *
                (viewMode == ViewMode.detailed ? 0.01 : 0.028),
          ),

          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: on
                  ? Colors.green.withOpacity(0.15)
                  : Colors.red.withOpacity(0.15),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: on ? Colors.green : Colors.redAccent,
                width: 1.2,
              ),
            ),
            child: Text(
              on ? 'ON' : 'OFF',
              style: TextStyle(
                color: on ? Colors.greenAccent : Colors.redAccent,
                fontWeight: FontWeight.bold,
                fontSize: 13,
                letterSpacing: 0.6,
              ),
            ),
          ),
          if (viewMode == ViewMode.detailed) ...[
            SizedBox(height: MediaQuery.of(context).size.height * 0.028),
            Expanded(
              child: GestureDetector(
                onTap: () => _openFullscreenGraph(c.name, diHistory[i]),
                child: _sparkline(diHistory[i]),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _aoCard(int i, double? v) {
    final c = aoCfg[i];
    final value = v ?? 0;
    final outOfRange = v != null && (value < c.min || value > c.max);
    final color = outOfRange
        ? Colors.redAccent
        : const Color.fromARGB(255, 167, 167, 167);

    return _cardShell(
      alert: outOfRange,
      onTap: () => showEditChannelDialog(
        deviceId: widget.device.deviceId,
        channelType: 'ao',
        index: i,
        context: context,
        channel: c,
        onSave: () {
          setState(() {});
          _saveChannelPref(c);
        },
      ),
      child: Stack(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(c.name, style: const TextStyle(fontSize: 17)),

              SizedBox(
                height:
                    MediaQuery.of(context).size.height *
                    (viewMode == ViewMode.detailed ? 0.01 : 0.028),
              ),

              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 2,
                ),
                decoration: BoxDecoration(
                  color: color.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: color.withOpacity(0.1), width: 1.5),
                ),
                child: Text(
                  '${value.toStringAsFixed(c.decimals)} ${c.unit}'.trim(),
                  style: TextStyle(
                    color: outOfRange ? Colors.red : null,
                    fontSize: 16,
                  ),
                ),
              ),

              if (viewMode == ViewMode.detailed) ...[
                SizedBox(height: MediaQuery.of(context).size.height * 0.028),
                Expanded(
                  child: GestureDetector(
                    onTap: () => _openFullscreenGraph(c.name, aoHistory[i]),
                    child: _sparkline(aoHistory[i]),
                  ),
                ),
              ],
            ],
          ),

          if (outOfRange)
            Positioned(
              top: 0,
              right: 0,
              child: Tooltip(
                message:
                    'Valor fora do range configurado (${c.min} – ${c.max})',
                child: const Icon(
                  Icons.warning_amber_rounded,
                  color: Colors.redAccent,
                  size: 18,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

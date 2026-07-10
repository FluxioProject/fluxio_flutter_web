import 'dart:async';
import 'package:flutter/material.dart';
import 'package:tcc_flutter/backend_api/api_communication.dart';
import 'package:tcc_flutter/pages/dashboard_screen/device_command_page.dart';
import 'package:tcc_flutter/pages/dashboard_screen/drag_n_drop.dart';
import 'package:tcc_flutter/pages/dashboard_screen/edit_channel.dart';
import 'package:tcc_flutter/pages/dashboard_screen/fw_upload.dart';
import 'package:tcc_flutter/pages/dashboard_screen/widgets/graph.dart';
import 'package:tcc_flutter/widgets/show_message.dart';
import 'package:tcc_flutter/models/channel_config.dart';
import 'package:tcc_flutter/models/device.dart';
import 'package:tcc_flutter/models/telemetry.dart';
import 'package:tcc_flutter/widgets/gradient_bg.dart';
import '../../services/mqtt_manager.dart';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

enum ViewMode { compact, detailed }

class DeviceDetailsPage extends StatefulWidget {
  final Device device;
  const DeviceDetailsPage({super.key, required this.device});

  @override
  State<DeviceDetailsPage> createState() => _DeviceDetailsPageState();
}

class _DeviceDetailsPageState extends State<DeviceDetailsPage> {
  late final String topicTelemetry;
  late final String topicControl;

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
  bool _connectionLostHandled = false;
  static const int telemetryTimeoutSec = 5;
  DateTime? _watchdogStart;
  bool _loadingChannels = true;
  bool _loadingMQTT = true;

  bool get isStale =>
      lastRx == null || DateTime.now().difference(lastRx!).inSeconds >= 2;

  // Watchdog retry logic
  int _retryCount = 0;
  static const int maxRetries = 3;
  static const int retryIntervalSec = 3;

  // Timestamp of the last retry attempt, tracked separately from
  // _watchdogStart so that sending a retry doesn't distort the timeout
  // math used to decide whether telemetry is still flowing.
  DateTime? _lastRetryAt;

  @override
  void initState() {
    super.initState();

    topicTelemetry = 'device/${widget.device.deviceId}/telemetry';
    topicControl = 'device/${widget.device.deviceId}/control';

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await mqttManager.initializeMqtt(context, true);
      await _loadAllChannelsFromBackend();
      await _loadChannelPrefs();
      _trySubscribe();
    });
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
          // Reset the retry counter here — this is the only place it
          // should be reset, since it reflects real data flow rather
          // than a timing window that retries themselves can distort.
          _retryCount = 0;
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
        });
      } catch (_) {}
    });
    _watchdogStart = DateTime.now();
    _startWatchdog();
  }

  void _startWatchdog() {
    _watchdogTimer?.cancel();
    _retryCount = 0;
    _lastRetryAt = null;

    _watchdogTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || _connectionLostHandled) return;

      final now = DateTime.now();

      // If nothing has been received yet, use the start time.
      final referenceTime = lastRx ?? _watchdogStart;

      if (referenceTime == null) return;

      // How long it's actually been since real data last arrived. This is
      // never mutated by a retry attempt, so it keeps climbing every
      // second the device stays silent — that's what lets the retry
      // counter actually reach maxRetries instead of resetting itself.
      final diffSinceLastData = now.difference(referenceTime).inSeconds;

      if (diffSinceLastData < telemetryTimeoutSec) {
        // Telemetry hasn't timed out — nothing to do. Do NOT reset
        // _retryCount here; it's only reset when data actually resumes,
        // inside the telemetry subscription callback above.
        return;
      }

      // We're past the timeout. Only fire a new retry if enough time has
      // passed since the previous one.
      final canRetryNow = _lastRetryAt == null ||
          now.difference(_lastRetryAt!).inSeconds >= retryIntervalSec;

      if (!canRetryNow) return;

      if (_retryCount < maxRetries) {
        _retryCount++;
        _lastRetryAt = now;

        showMessage(
          context,
          'Sem resposta do dispositivo, tentando reconectar ($_retryCount/$maxRetries)...',
          true,
        );

        // Try to resend the telemetry command. If MQTT has already
        // reconnected in the background, this restarts the data stream.
        mqttManager.publish(topicControl, jsonEncode({'telemetry': true}));
        return;
      }

      // Retry attempts are exhausted.
      _connectionLostHandled = true;

      mqttManager.publish(topicControl, jsonEncode({'telemetry': false}));

      showMessage(context, 'Sem conexão com dispositivo', true);
      setState(() {
        _loadingMQTT = false;
      });

      _telemetryKeepAlive?.cancel();

      // Leave the screen automatically.
      Future.delayed(const Duration(milliseconds: 400), () {
        if (mounted) {
          Navigator.of(context).pop();
        }
      });
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
    _connectionLostHandled = false;
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

    if (subscribed) {
      mqttManager.publish(topicControl, jsonEncode({'telemetry': false}));
      mqttManager.unsubscribe(topicTelemetry);
      // Do not disconnect here because CardsPage shares the MQTT connection.
    }
    super.dispose();
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
              title: Text(widget.device.name),
              leading: IconButton(
                tooltip: 'Voltar',
                icon: const Icon(Icons.arrow_back),
                onPressed: () => Navigator.of(context).maybePop(),
              ),
              actions: [
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
                GradientBackground(
                  image: false,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(children: [Expanded(child: _ioTab(last))]),
                  ),
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
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tcc_flutter/backend_api/api_communication.dart';
import 'package:tcc_flutter/models/channel_config.dart';
import 'package:tcc_flutter/pages/main_screen/manage_devices/add_device.dart';
import 'package:tcc_flutter/pages/first_screens/login.dart';
import 'package:tcc_flutter/pages/main_screen/manage_user/edit_account.dart';
import 'package:tcc_flutter/pages/main_screen/widgets/device_card.dart';
import 'package:tcc_flutter/models/device.dart';
import 'package:tcc_flutter/services/app_state.dart';
import 'package:tcc_flutter/services/mqtt_manager.dart';
import 'package:tcc_flutter/widgets/gradient_bg.dart';
import 'package:tcc_flutter/widgets/show_message.dart';

class CardsPage extends StatefulWidget {
  const CardsPage({super.key});

  @override
  State<CardsPage> createState() => _CardsPageState();
}

class _CardsPageState extends State<CardsPage> {
  final TextEditingController _searchCtrl = TextEditingController();
  String _query = '';
  final Set<String> _subscribedDeviceIds = {};
  Timer? _freshnessTicker;

  // Tracks whether a manual refresh is currently in progress, so the
  // button can show a spinner and avoid firing multiple times at once.
  bool _refreshing = false;

  DateTime? _lastAnyStatusRx;
  bool _forcingReconnect = false;

  List<Device> get filteredDevices {
    final devices = appState.devices;

    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return devices;

    return devices.where((d) {
      return d.name.toLowerCase().contains(q) ||
          d.deviceId.toLowerCase().contains(q);
    }).toList();
  }

  @override
  void initState() {
    super.initState();
    appState.addListener(_onUserUpdated);
    _setupMqtt();

    // Re-renders every second so a device whose heartbeat stopped
    // arriving flips to "Desconectado" on its own, without waiting for
    // another MQTT message to trigger a rebuild.
    _freshnessTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() {});
        _watchdogCheckConnection();
      }
    });
  }

  void _watchdogCheckConnection() {
    if (_forcingReconnect) return;
    if (appState.devices.isEmpty) return;

    final last = _lastAnyStatusRx;
    final staleForTooLong = last == null
        ? false
        : DateTime.now().difference(last).inSeconds > 15;

    if (staleForTooLong) {
      _forcingReconnect = true;
      debugPrint('[Watchdog] Sem status há >15s, forçando reconexão MQTT');

      // NOVO: limpa a marca de "já inscrito" JUNTO com o disconnect, já
      // que clearSubscriptions() no MqttManager já apaga os handlers reais
      // — sem isso, _syncDeviceSubscriptions() acha que já está tudo
      // inscrito e pula o subscribe() de verdade, deixando o app "conectado"
      // mas surdo pra sempre (loop de reconexão infinito).
      _subscribedDeviceIds.clear();

      // NOVO: dá uma folga antes de checar de novo, pra não repetir o
      // watchdog no próximo tick de 1s enquanto ainda estamos no meio da
      // reconexão.
      _lastAnyStatusRx = DateTime.now();

      mqttManager.disconnect();
      mqttManager.initializeMqtt(context, true).then((_) {
        if (!mounted) return;
        _syncDeviceSubscriptions();
        _forcingReconnect = false;
      });
    }
  }

  Future<void> _setupMqtt() async {
    await mqttManager.initializeMqtt(context, true);
    if (!mounted) return;
    _syncDeviceSubscriptions();
  }

  // Subscribes to each device status topic that is not subscribed yet.
  void _syncDeviceSubscriptions() {
    for (final d in appState.devices) {
      if (_subscribedDeviceIds.contains(d.deviceId)) continue;
      _subscribedDeviceIds.add(d.deviceId);

      final topic = 'device/${d.deviceId}/status';
      mqttManager.subscribe(topic, (payload) {
        _handleStatusMessage(d.deviceId, payload);
      });
    }
  }

  // Forces the broker to redeliver the retained status message for every
  // device we already know about, by unsubscribing and resubscribing.
  // Regular MQTT status updates are retained-only (published once when the
  // device connects), so this is the only way to pull a fresh snapshot
  // without waiting for the device to reconnect on its own.
  void _refreshDeviceStatuses() {
    for (final d in appState.devices) {
      final topic = 'device/${d.deviceId}/status';
      mqttManager.unsubscribe(topic);
      mqttManager.subscribe(topic, (payload) {
        _handleStatusMessage(d.deviceId, payload);
      });
    }
  }

  void _handleStatusMessage(String deviceId, String payload) {
    _lastAnyStatusRx = DateTime.now();
    try {
      final decoded = jsonDecode(payload);
      if (decoded is! Map<String, dynamic>) return;

      final online = decoded['online'] as bool?;
      final ip = decoded['ip'] as String?;
      final uptime = decoded['uptime'] as int?;
      final fwVersion = decoded['fwVersion'] as String?; // NEW

      appState.updateDeviceStatus(
        deviceId: deviceId,
        isConnected: online,
        ipAddress: ip,
        uptimeSec: uptime,
        fwVersion: fwVersion, // NEW
      );
    } catch (_) {
      // Ignore invalid payloads.
    }
  }

  void _onUserUpdated() {
    if (!mounted) return;
    setState(() {});
    _syncDeviceSubscriptions();
  }

  // Manual refresh: forces an MQTT reconnect if the socket is down (as a
  // fallback in case autoReconnect misbehaves), reloads the device list
  // from the backend, and re-requests status for every device.
  Future<void> _handleRefresh() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);

    try {
      if (!mqttManager.isConnected()) {
        // NOTE: adjust this call if your MqttManager exposes a dedicated
        // "forceReconnect" method instead of reusing initializeMqtt.
        await mqttManager.initializeMqtt(context, true);
      }

      if (!mounted) return;

      // NOTE: assuming appState exposes a getDevices(context) method that
      // refetches the device list from the backend, matching the naming
      // used elsewhere in this file (createDevice, deleteDevice, etc).
      // Rename this call if the actual method differs.
      await appState.getDevices(context);

      if (!mounted) return;

      _syncDeviceSubscriptions();
      _refreshDeviceStatuses();

      if (mounted) {
        showMessage(context, 'Lista atualizada', false);
      }
    } catch (e) {
      if (mounted) {
        showMessage(
          context,
          e.toString().replaceAll('Exception:', '').trim(),
          true,
        );
      }
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  @override
  void dispose() {
    _freshnessTicker?.cancel();
    _searchCtrl.dispose();
    appState.removeListener(_onUserUpdated);

    for (final id in _subscribedDeviceIds) {
      mqttManager.unsubscribe('device/$id/status');
    }

    super.dispose();
  }

  Widget _channelEditRow({
    required TextEditingController nameCtrl,
    required ChannelConfig channel,
    required void Function(void Function()) setLocal,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: nameCtrl,
              decoration: const InputDecoration(
                isDense: true,
                border: OutlineInputBorder(),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Checkbox(
            value: channel.visible,
            onChanged: (v) => setLocal(() => channel.visible = v ?? true),
          ),
          const Text('Visível', style: TextStyle(fontSize: 12)),
        ],
      ),
    );
  }

  Widget _channelGroupSection(
    String title,
    List<ChannelConfig> list,
    List<TextEditingController> ctrls,
    void Function(void Function()) setLocal,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Colors.white70,
            ),
          ),
          const SizedBox(height: 8),
          for (int i = 0; i < list.length; i++)
            _channelEditRow(
              nameCtrl: ctrls[i],
              channel: list[i],
              setLocal: setLocal,
            ),
        ],
      ),
    );
  }

  Future<void> _editDeviceName(BuildContext context, Device device) async {
    final nameCtrl = TextEditingController(text: device.name);

    // Mesma estrutura usada em DeviceDetailsPage: 4 canais fixos por tipo.
    final aiCfg = List.generate(4, (i) => ChannelConfig(name: 'AI ${i + 1}'));
    final aoCfg = List.generate(4, (i) => ChannelConfig(name: 'AO ${i + 1}'));
    final diCfg = List.generate(
      4,
      (i) => ChannelConfig(name: 'DI ${i + 1}', analog: false),
    );
    final doCfg = List.generate(
      4,
      (i) => ChannelConfig(name: 'DO ${i + 1}', analog: false),
    );

    bool channelsLoaded = false;

    // 1) Nome dos canais vem do backend (mesma chamada usada em
    // DeviceDetailsPage._loadAllChannelsFromBackend).
    try {
      final res = await Session().getObj(
        'devices/get-all-channels?deviceId=${device.deviceId}',
        context,
      );

      if (res is Map<String, dynamic>) {
        void applyNames(List<ChannelConfig> list, Map<String, dynamic>? data) {
          if (data == null) return;
          data.forEach((key, value) {
            final index = int.tryParse(key);
            if (index == null || index >= list.length) return;
            list[index].name =
                value['channelName']?.toString() ?? list[index].name;
          });
        }

        applyNames(aiCfg, res['ai']);
        applyNames(aoCfg, res['ao']);
        applyNames(diCfg, res['di']);
        applyNames(doCfg, res['do']);
        channelsLoaded = true;
      }
    } catch (e) {
      // Segue sem os canais; o dialog avisa que não deu pra carregar.
    }

    // 2) 'visible' é local (mesma leitura usada em
    // DeviceDetailsPage._loadChannelPrefs).
    final prefs = await SharedPreferences.getInstance();

    void applyVisible(List<ChannelConfig> list, String type) {
      for (int i = 0; i < list.length; i++) {
        final key = 'device_${device.deviceId}_${type}_$i';
        final raw = prefs.getString(key);
        if (raw == null) continue;
        final data = jsonDecode(raw) as Map<String, dynamic>;
        list[i].visible = data['visible'] ?? list[i].visible;
      }
    }

    applyVisible(aiCfg, 'ai');
    applyVisible(aoCfg, 'ao');
    applyVisible(diCfg, 'di');
    applyVisible(doCfg, 'do');

    if (!mounted) return;

    final groups = <String, List<ChannelConfig>>{
      'ai': aiCfg,
      'ao': aoCfg,
      'di': diCfg,
      'do': doCfg,
    };

    // Controllers por canal, pra edição de nome sem perder o texto
    // digitado a cada rebuild do checkbox.
    final ctrls = {
      for (final entry in groups.entries)
        entry.key: [
          for (final c in entry.value) TextEditingController(text: c.name),
        ],
    };

    // Guarda os nomes originais pra saber depois o que realmente mudou.
    final oldNames = {
      for (final entry in groups.entries)
        entry.key: entry.value.map((c) => c.name).toList(),
    };

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Editar dispositivo'),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              padding: const EdgeInsets.only(top: 8, right: 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: nameCtrl,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => Navigator.pop(ctx, true),
                    decoration: const InputDecoration(
                      label: Text('Nome do dispositivo'),
                      hintText: 'Digite o novo nome',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'ID: ${device.deviceId}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  if (!channelsLoaded) ...[
                    const SizedBox(height: 16),
                    const Text(
                      'Não foi possível carregar os canais deste dispositivo.',
                      style: TextStyle(
                        color: Colors.orangeAccent,
                        fontSize: 12,
                      ),
                    ),
                  ] else ...[
                    const Divider(height: 28),
                    const Text(
                      'Canais',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                      ),
                    ),
                    const SizedBox(height: 8),
                    _channelGroupSection(
                      'Entradas Analógicas',
                      aiCfg,
                      ctrls['ai']!,
                      setLocal,
                    ),
                    _channelGroupSection(
                      'Saídas Analógicas',
                      aoCfg,
                      ctrls['ao']!,
                      setLocal,
                    ),
                    _channelGroupSection(
                      'Entradas Digitais',
                      diCfg,
                      ctrls['di']!,
                      setLocal,
                    ),
                    _channelGroupSection(
                      'Saídas Digitais',
                      doCfg,
                      ctrls['do']!,
                      setLocal,
                    ),
                  ],
                ],
              ),
            ),
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
                'Salvar',
                style: TextStyle(color: Colors.white),
              ),
            ),
          ],
        ),
      ),
    );

    if (confirm != true) return;

    // Aplica o texto final dos controllers nos ChannelConfig antes de salvar.
    for (final entry in groups.entries) {
      final list = entry.value;
      final typeCtrls = ctrls[entry.key]!;
      for (int i = 0; i < list.length; i++) {
        final typed = typeCtrls[i].text.trim();
        if (typed.isNotEmpty) list[i].name = typed;
      }
    }

    // 1) Nome do dispositivo — fluxo já existente, sem mudanças.
    final newDeviceName = nameCtrl.text.trim();
    if (newDeviceName.isNotEmpty && newDeviceName != device.name) {
      try {
        await appState.updateDeviceName(
          deviceId: device.deviceId,
          newName: newDeviceName,
          context: context,
        );
        if (mounted) {
          showMessage(context, 'Nome do dispositivo atualizado', false);
        }
      } catch (e) {
        if (mounted) {
          showMessage(
            context,
            e.toString().replaceAll('Exception:', '').trim(),
            true,
          );
        }
        return;
      }
    }

    if (!channelsLoaded) return;

    bool anyChannelNameChanged = false;

    for (final entry in groups.entries) {
      final type = entry.key;
      final list = entry.value;

      for (int i = 0; i < list.length; i++) {
        final c = list[i];
        final nameChanged = c.name != oldNames[type]![i];

        // 2) Nome do canal -> mesmo endpoint usado em edit_channel.dart.
        if (nameChanged) {
          anyChannelNameChanged = true;
          try {
            final res = await Session().patchObj('devices/update-channel', {
              'deviceId': device.deviceId,
              'type': type,
              'index': i,
              'channelName': c.name,
            }, context);

            final msg = (res['message'] ?? 'Canal atualizado com sucesso.')
                .toString();
            showMessage(context, msg, false);
          } catch (e) {
            if (mounted) {
              showMessage(
                context,
                e.toString().replaceAll('Exception:', '').trim(),
                true,
              );
            }
          }
        }

        // 3) 'visible' é só local — mesmo formato de
        // DeviceDetailsPage._saveChannelPref, senão o dashboard e este
        // popup ficam fora de sincronia.
        final key = 'device_${device.deviceId}_${type}_$i';
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
    }

    if (anyChannelNameChanged) {
      mqttManager.publish(
        'device/${device.deviceId}/control',
        '{"type":"get_channels"}',
      );
    }

    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final user = appState.current;

    return Scaffold(
      appBar: AppBar(
        actionsPadding: EdgeInsets.only(right: 8),
        backgroundColor: Color(0xFF1E1E1E),
        title: Row(
          children: [
            SizedBox(width: 8),
            const Text('Dispositivos'),
            Spacer(),
            SizedBox(
              height: 40,
              width: 350,
              child: TextField(
                controller: _searchCtrl,
                onChanged: (v) => setState(() => _query = v),
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  hintText: 'Pesquisar por nome ou ID...',
                  isDense: true,
                  prefixIcon: const Icon(Icons.search, size: 20),
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'Limpar',
                          icon: const Icon(Icons.close, size: 18),
                          onPressed: () {
                            _searchCtrl.clear();
                            setState(() => _query = '');
                          },
                        ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              height: 40,
              width: 40,
              child: IconButton(
                tooltip: 'Atualizar (reconecta MQTT e recarrega dispositivos)',
                onPressed: _refreshing ? null : _handleRefresh,
                icon: _refreshing
                    ? const SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh),
              ),
            ),
            Spacer(),
          ],
        ),
        actions: [
          Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: Colors.white.withOpacity(0.18),
                width: 1,
              ),
              color: Colors.white.withOpacity(0.04),
            ),
            child: TextButton.icon(
              onPressed: () async {
                final currentUser = appState.current;
                if (currentUser == null) return;

                final newName = await showDialog<String>(
                  context: context,
                  builder: (_) => EditUserDialog(usuario: currentUser),
                );

                if (newName != null && newName != currentUser.nome) {
                  await appState.updateName(newName, context);

                  showMessage(context, 'Nome atualizado com sucesso', false);

                  if (mounted) setState(() {});
                }
              },
              icon: const Icon(Icons.person_outline, size: 22),
              label: Text(
                (user?.nome.trim().isNotEmpty ?? false)
                    ? user!.nome.trim()
                    : 'Conta',
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w400,
                ),
              ),
              style: TextButton.styleFrom(
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                minimumSize: const Size(0, 44),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                backgroundColor: Colors.transparent,
              ),
            ),
          ),
          SizedBox(width: 5),
          IconButton(
            tooltip: 'Logout',
            icon: const Icon(Icons.logout),
            onPressed: () {
              appState.logout();

              Navigator.pushAndRemoveUntil(
                context,
                MaterialPageRoute(builder: (_) => const LoginPage()),
                (_) => false,
              );
            },
          ),
        ],
      ),
      body: GradientBackground(
        image: false,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: GridView.builder(
            itemCount: filteredDevices.length,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              mainAxisSpacing: 16,
              crossAxisSpacing: 16,
              childAspectRatio: 4.5,
            ),
            itemBuilder: (context, index) {
              final dev = filteredDevices[index];
              final effectivelyConnected =
                  dev.isConnected && appState.isDeviceFresh(dev.deviceId);
              return DeviceCard(
                device: dev.copyWith(isConnected: effectivelyConnected),
                onDelete: () async {
                  final confirm = await showDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: const Text('Excluir dispositivo?'),
                      content: Text(
                        'Tem certeza que deseja excluir "${dev.name}"?\n\n'
                        'ID: ${dev.deviceId}',
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(ctx, false),
                          child: const Text('Cancelar'),
                        ),
                        FilledButton(
                          style: FilledButton.styleFrom(
                            backgroundColor: const Color.fromARGB(
                              255,
                              180,
                              49,
                              39,
                            ),
                          ),
                          onPressed: () => Navigator.pop(ctx, true),
                          child: const Text(
                            'Excluir',
                            style: TextStyle(color: Colors.white),
                          ),
                        ),
                      ],
                    ),
                  );

                  if (confirm == true) {
                    try {
                      mqttManager.unsubscribe('device/${dev.deviceId}/status');
                      _subscribedDeviceIds.remove(dev.deviceId);

                      await appState.deleteDevice(
                        deviceId: dev.deviceId,
                        context: context,
                      );

                      showMessage(context, 'Dispositivo removido', false);
                    } catch (e) {
                      showMessage(
                        context,
                        e.toString().replaceAll('Exception:', '').trim(),
                        true,
                      );
                    }
                  }
                },
                onEdit: () => _editDeviceName(context, dev),
              );
            },
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: Colors.greenAccent,
        foregroundColor: Colors.black,
        shape: const CircleBorder(),
        onPressed: () async {
          final result = await showDialog<Map<String, String>>(
            context: context,
            builder: (_) => const AddDeviceDialog(),
          );

          if (result == null) return;

          try {
            await appState.createDevice(
              name: result['name']!,
              deviceId: result['deviceId']!,
              context: context,
            );

            showMessage(context, 'Dispositivo adicionado com sucesso', false);
            _syncDeviceSubscriptions();
          } catch (e) {
            showMessage(
              context,
              e.toString().replaceAll('Exception:', '').trim(),
              true,
            );
          }
        },
        child: const Icon(Icons.add),
      ),
    );
  }
}

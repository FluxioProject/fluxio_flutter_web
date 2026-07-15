import 'package:flutter/material.dart';
import 'package:tcc_flutter/backend_api/api_communication.dart';
import 'package:tcc_flutter/services/mqtt_manager.dart';
import 'package:tcc_flutter/widgets/show_message.dart';
import '../../models/channel_config.dart';

Future<void> showEditChannelDialog({
  required BuildContext context,
  required ChannelConfig channel,
  required VoidCallback onSave,
  required String deviceId,
  required String channelType, // ai, ao, di, do
  required int index,
}) async {
  final nameCtrl = TextEditingController(text: channel.name);
  final unitCtrl = TextEditingController(text: channel.unit);
  final minCtrl = TextEditingController(text: channel.min.toString());
  final maxCtrl = TextEditingController(text: channel.max.toString());
  final minMapCtrl = TextEditingController(text: channel.mapMin.toString());
  final maxMapCtrl = TextEditingController(text: channel.mapMax.toString());
  final decCtrl = TextEditingController(text: channel.decimals.toString());
  final units = ['°C', 'V', 'A', '%', 'Hz', 'bar', 'rpm', 'm/s', 'lux', 'dB'];

  Future<void> _updateChannelLimits({
    required String deviceId,
    required String channelType,
    required int index,
    double? min,
    double? max,
    double? mapMin,
    double? mapMax,
    bool? notifyMobile,
    bool? notifyEmail,
    bool? notifySms,
    String? channelName,
  }) async {
    try {
      final res = await Session().patchObj('devices/update-channel', {
        'deviceId': deviceId,
        'type': channelType,
        'index': index,
        if (min != null) 'min': min,
        if (max != null) 'max': max,
        if (notifyMobile != null) 'notifyMobile': notifyMobile,
        if (notifyEmail != null) 'notifyEmail': notifyEmail,
        if (notifySms != null) 'notifySms': notifySms,
        if (channelName != null) 'channelName': channelName,
        if (mapMin != null) 'mapMin': mapMin,
        if (mapMax != null) 'mapMax': mapMax,
      }, context);

      final msg = (res['message'] ?? 'Canal atualizado com sucesso.')
          .toString();
      showMessage(context, msg, false);

      mqttManager.publish(
        'device/$deviceId/control',
        '{"type":"get_channels"}',
      );
    } catch (e) {
      showMessage(
        context,
        e.toString().replaceAll('Exception:', '').trim(),
        false,
      );
    }
  }

  Widget borderedCheckbox({
    required String title,
    required bool value,
    required ValueChanged<bool?> onChanged,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.white, width: 1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: CheckboxListTile(
        dense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12),
        title: Text(title),
        value: value,
        onChanged: onChanged,
      ),
    );
  }

  Widget sectionTitle(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w600,
          color: Colors.white70,
        ),
      ),
    );
  }

  final oldMin = channel.min;
  final oldMax = channel.max;
  final oldMobileNotify = channel.notifyMobile;
  final oldChannelName = channel.name;
  final oldNotifyEmail = channel.notifyEmail;
  final oldNotifySms = channel.notifySms;
  final oldMinMap = channel.mapMin;
  final oldMaxMap = channel.mapMax;
  bool localNotifyMobile = channel.notifyMobile;
  bool localNotifyEmail = channel.notifyEmail;
  bool localNotifySms = channel.notifySms;
  localNotifySms = channel.notifySms;
  double localDigitalTrigger = channel.min;

  await showDialog(
    context: context,
    builder: (_) => StatefulBuilder(
      builder: (ctx, setLocal) => AlertDialog(
        title: const Text('Editar canal'),
        content: SizedBox(
          width: 400,
          child: SingleChildScrollView(
            padding: const EdgeInsets.only(right: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 5),
                TextField(
                  controller: nameCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Nome',
                    isDense: true,
                  ),
                ),
                if (channel.analog) ...[
                  const SizedBox(height: 12),
                  Text(
                    'Unidade',
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Colors.white70,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    alignment: WrapAlignment.center,
                    runSpacing: 8,
                    children: units.map((u) {
                      final selected = unitCtrl.text == u;

                      return ChoiceChip(
                        label: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              u,
                              style: TextStyle(
                                color: selected ? Colors.white : Colors.white70,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                        selected: selected,
                        onSelected: (_) {
                          setLocal(() {
                            unitCtrl.text = u;
                          });
                        },
                        selectedColor: const Color.fromARGB(255, 63, 146, 66),
                        backgroundColor: Colors.transparent,
                        side: BorderSide(
                          color: selected
                              ? const Color.fromARGB(255, 63, 146, 66)
                              : Colors.white24,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                      );
                    }).toList(),
                  ),
                ],
                if (channel.analog) ...[
                  SizedBox(height: 20),
                  sectionTitle('Escala (faixa de medição/atuação)'),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: minMapCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Min',
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextField(
                          controller: maxMapCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Max',
                            isDense: true,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: decCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Decimais',
                      isDense: true,
                    ),
                  ),
                ],
                SizedBox(height: 20),
                Row(
                  children: const [
                    Text(
                      'Alertas quando sair da faixa',
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: Colors.white70,
                      ),
                    ),
                    SizedBox(width: 6),
                    Tooltip(
                      message:
                          'Quando o valor ultrapassar o mínimo ou máximo configurado abaixo.\n\nAs notificações serão enviadas de 5 em 5 minutos enquanto o valor permanecer fora dessa faixa.',
                      child: Icon(Icons.info_outline, size: 16),
                    ),
                  ],
                ),
                if (channel.analog) ...[
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: minCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Min',
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextField(
                          controller: maxCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Max',
                            isDense: true,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 10),
                borderedCheckbox(
                  title: 'Mobile',
                  value: localNotifyMobile,
                  onChanged: (v) =>
                      setLocal(() => localNotifyMobile = v ?? false),
                ),
                borderedCheckbox(
                  title: 'Email',
                  value: localNotifyEmail,
                  onChanged: (v) =>
                      setLocal(() => localNotifyEmail = v ?? false),
                ),
                borderedCheckbox(
                  title: 'SMS',
                  value: localNotifySms,
                  onChanged: (v) => setLocal(() => localNotifySms = v ?? false),
                ),
                const SizedBox(height: 6),
                if (!channel.analog) ...[
                  Align(
                    alignment: Alignment.center,
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      alignment: WrapAlignment.center,
                      children: [
                        ChoiceChip(
                          label: const Text('Quando ON (1)'),
                          selected: localDigitalTrigger == 1,
                          onSelected: (_) =>
                              setLocal(() => localDigitalTrigger = 1),
                        ),
                        ChoiceChip(
                          label: const Text('Quando OFF (0)'),
                          selected: localDigitalTrigger == 0,
                          onSelected: (_) =>
                              setLocal(() => localDigitalTrigger = 0),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color.fromARGB(255, 63, 146, 66),
            ),
            onPressed: () {
              channel
                ..name = nameCtrl.text.trim().isEmpty
                    ? channel.name
                    : nameCtrl.text
                ..unit = unitCtrl.text.trim()
                ..min = double.tryParse(minCtrl.text) ?? channel.min
                ..max = double.tryParse(maxCtrl.text) ?? channel.max
                ..decimals = int.tryParse(decCtrl.text) ?? channel.decimals
                ..notifyMobile = localNotifyMobile
                ..notifyEmail = localNotifyEmail
                ..mapMin = double.tryParse(minMapCtrl.text) ?? channel.mapMin
                ..mapMax = double.tryParse(maxMapCtrl.text) ?? channel.mapMax
                ..notifySms = localNotifySms;

              if (!channel.analog) {
                channel.min = localDigitalTrigger;
              }

              onSave();

              final newMin = channel.analog
                  ? double.tryParse(minCtrl.text)
                  : localDigitalTrigger;
              final newMax = double.tryParse(maxCtrl.text);

              final minChanged = newMin != null && newMin != oldMin;

              final maxChanged = newMax != null && newMax != oldMax;
              final mobileNotifyChanged = localNotifyMobile != oldMobileNotify;
              final nameChanged = channel.name != oldChannelName;
              final emailNotifyChanged = localNotifyEmail != oldNotifyEmail;
              final smsNotifyChanged = localNotifySms != oldNotifySms;
              final mapMinChanged =
                  (double.tryParse(minMapCtrl.text) ?? oldMinMap) != oldMinMap;
              final mapMaxChanged =
                  (double.tryParse(maxMapCtrl.text) ?? oldMaxMap) != oldMaxMap;

              if (minChanged ||
                  maxChanged ||
                  mobileNotifyChanged ||
                  nameChanged ||
                  emailNotifyChanged ||
                  smsNotifyChanged ||
                  mapMinChanged ||
                  mapMaxChanged) {
                _updateChannelLimits(
                  deviceId: deviceId,
                  channelName: channel.name,
                  channelType: channelType,
                  index: index,
                  min: newMin,
                  max: newMax,
                  mapMin: double.tryParse(minMapCtrl.text),
                  mapMax: double.tryParse(maxMapCtrl.text),
                  notifyMobile: localNotifyMobile,
                  notifyEmail: localNotifyEmail,
                  notifySms: localNotifySms,
                );
              }

              Navigator.pop(ctx);
            },
            child: const Text('Salvar', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    ),
  );
}

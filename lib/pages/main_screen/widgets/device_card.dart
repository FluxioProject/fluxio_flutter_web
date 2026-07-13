import 'package:flutter/material.dart';
import 'package:tcc_flutter/backend_api/api_communication.dart';
import 'package:tcc_flutter/pages/dashboard_screen/device_details_page.dart';
import 'package:tcc_flutter/models/channel_config.dart';
import 'package:tcc_flutter/models/device.dart';
import 'package:tcc_flutter/pages/dashboard_screen/drag_n_drop.dart';
import 'package:tcc_flutter/pages/dashboard_screen/fw_upload.dart';
import 'package:tcc_flutter/widgets/show_message.dart';

class DeviceCard extends StatelessWidget {
  final Device device;
  final VoidCallback onDelete;
  final VoidCallback onEdit;
  const DeviceCard({
    super.key,
    required this.device,
    required this.onDelete,
    required this.onEdit,
  });

  // Same formatting used in DeviceDetailsPage._buildAppBarTitle, duplicated
  // here so the card and the details screen always show uptime the same
  // way. If this needs to change again, update both places (or move this
  // into a shared util if it starts drifting).
  String _formatUptime(int seconds) {
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

  // Small pill-style badge used for status / firmware / uptime.
  // Uses a plain painted circle for the leading dot (instead of an Icon
  // glyph) because tiny icon glyphs can fail to render on web at this
  // size, leaving either a blank gap or nothing at all — a Container is
  // guaranteed to paint regardless of icon font loading.
  Widget _chip({
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

  // Applies the backend's per-channel data (name, min/max, notify flags,
  // etc.) onto a freshly-created default ChannelConfig list. Mirrors
  // DeviceDetailsPage._loadAllChannelsFromBackend's applyCfg exactly, so
  // the block-programming screen sees the same channel metadata whether
  // it's opened from here or from inside the device details page.
  void _applyChannelData(
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

  // Fetches the device's channel configuration from the backend (same
  // 'devices/get-all-channels' endpoint DeviceDetailsPage uses) and only
  // then opens VisualLogicBuilderPage — previously this navigated with
  // empty channel lists, so the block palette had nothing to program
  // with.
  Future<void> _openLogicBuilder(BuildContext context) async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );

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

    try {
      final res = await Session().getObj(
        'devices/get-all-channels?deviceId=${device.deviceId}',
        context,
      );

      if (res is Map<String, dynamic>) {
        _applyChannelData(aiCfg, res['ai'], true);
        _applyChannelData(aoCfg, res['ao'], true);
        _applyChannelData(diCfg, res['di'], false);
        _applyChannelData(doCfg, res['do'], false);
      }
    } catch (e) {
      if (context.mounted) {
        showMessage(context, 'Erro ao carregar canais: $e', true);
      }
    } finally {
      // Close the loading dialog regardless of success/failure. Uses the
      // root navigator since a plain Navigator.pop(context) here could
      // accidentally target something else if a route change happened
      // while we were awaiting.
      if (context.mounted) {
        Navigator.of(context, rootNavigator: true).pop();
      }
    }

    if (!context.mounted) return;

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => VisualLogicBuilderPage(
          device: device,
          aiCfg: aiCfg,
          diCfg: diCfg,
          aoCfg: aoCfg,
          doCfg: doCfg,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final connected = device.isConnected;
    final statusColor = connected ? Colors.greenAccent : Colors.redAccent;
    final statusLabel = connected ? 'Conectado' : 'Desconectado';
    final fwLabel = 'FW ${device.fwVersion ?? 'v1.0.0'}';

    // Wired to device.uptimeSec now, same source and same formatting as
    // DeviceDetailsPage — this used to be a hardcoded 'Uptime: N/D'
    // placeholder because the MQTT payload with uptime didn't exist yet.
    final uptimeLabel = device.uptimeSec != null
        ? 'Uptime ${_formatUptime(device.uptimeSec!)}'
        : 'Uptime N/D';

    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: connected
          ? () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => DeviceDetailsPage(device: device),
                ),
              );
            }
          : null,
      child: Container(
        height: 140,
        decoration: BoxDecoration(
          color: const Color(0xFF1B1B1B),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white10, width: 2),
          boxShadow: const [
            BoxShadow(
              color: Colors.black54,
              blurRadius: 10,
              offset: Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          children: [
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SelectableText(
                    device.name,
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  SelectableText(
                    device.deviceId,
                    style: const TextStyle(
                      fontWeight: FontWeight.w500,
                      fontSize: 13,
                      color: Colors.white54,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      _chip(label: statusLabel, color: statusColor, dot: true),
                      _chip(label: fwLabel, color: Colors.white60),
                      _chip(label: uptimeLabel, color: Colors.white60),
                    ],
                  ),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Excluir dispositivo',
              onPressed: onDelete,
            ),
            IconButton(
              icon: const Icon(Icons.edit_outlined),
              tooltip: 'Editar dispositivo',
              onPressed: onEdit,
            ),
            IconButton(
              tooltip: 'Programar dispositivo',
              icon: const Icon(Icons.settings_applications_sharp),
              onPressed: () => _openLogicBuilder(context),
            ),
            IconButton(
              tooltip: 'Upload de firmware',
              icon: const Icon(Icons.cloud_upload),
              onPressed: () {
                showDialog(
                  context: context,
                  barrierDismissible: false,
                  builder: (_) =>
                      FirmwareUploadDialog(deviceId: device.deviceId),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

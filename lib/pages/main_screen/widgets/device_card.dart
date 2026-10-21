import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:tcc_flutter/theme/app_theme.dart';
import 'package:tcc_flutter/models/device.dart';
import 'package:tcc_flutter/pages/dashboard_screen/fw_upload.dart';
import 'package:tcc_flutter/routing/app_router.dart';

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
              fontSize: AppFontSize.xs,
              fontWeight: FontWeight.w500,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final connected = device.isConnected;
    final statusColor = connected ? AppColors.accent : AppColors.danger;
    final statusLabel = connected ? 'Conectado' : 'Desconectado';
    final fwLabel = 'FW ${device.fwVersion ?? 'v1.0.0'}';

    // Wired to device.uptimeSec now, same source and same formatting as
    // DeviceDetailsPage — this used to be a hardcoded 'Uptime: N/D'
    // placeholder because the MQTT payload with uptime didn't exist yet.
    final uptimeLabel = device.uptimeSec != null
        ? 'Uptime ${_formatUptime(device.uptimeSec!)}'
        : 'Uptime N/D';
    final ipLabel = device.ipAddress?.isNotEmpty == true
        ? 'IP ${device.ipAddress}'
        : 'IP N/D';

    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: connected
          ? () => context.go(AppRoutes.device(device.deviceId))
          : null,
      child: Container(
        height: 140,
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.border, width: 2),
          boxShadow: const [
            BoxShadow(
              color: AppColors.shadow,
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
                      fontSize: AppFontSize.xxl,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  SelectableText(
                    device.deviceId,
                    style: const TextStyle(
                      fontWeight: FontWeight.w500,
                      fontSize: AppFontSize.md,
                      color: AppColors.foregroundMuted,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      _chip(label: statusLabel, color: statusColor, dot: true),
                      _chip(label: fwLabel, color: AppColors.foregroundMuted),
                      _chip(
                        label: uptimeLabel,
                        color: AppColors.foregroundMuted,
                      ),
                      _chip(label: ipLabel, color: AppColors.foregroundMuted),
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
              onPressed: () =>
                  context.go(AppRoutes.deviceLogic(device.deviceId)),
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

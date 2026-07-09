import 'package:flutter/material.dart';
import 'package:tcc_flutter/pages/dashboard_screen/device_details_page.dart';
import 'package:tcc_flutter/models/device.dart';

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

  @override
  Widget build(BuildContext context) {
    final connected = device.isConnected;
    final statusColor = connected ? Colors.greenAccent : Colors.redAccent;
    final statusText = connected
        ? 'Conectado${device.ipAddress != null ? ' - ${device.ipAddress}' : ''}'
        : 'Desconectado';

    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () {
        // Clickable even when disconnected for testing.
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => DeviceDetailsPage(device: device)),
        );
      },
      child: Container(
        height: 120,
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
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  SelectableText(
                    'ID: ' + device.deviceId,
                    style: const TextStyle(
                      fontWeight: FontWeight.w500,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: statusColor,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 6),
                      SelectableText(
                        'Status: $statusText',
                        style: TextStyle(
                          color: statusColor,
                          fontWeight: FontWeight.w500,
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline),
              onPressed: onDelete,
            ),
            IconButton(
              icon: const Icon(Icons.edit_outlined),
              onPressed: onEdit,
            ),
          ],
        ),
      ),
    );
  }
}

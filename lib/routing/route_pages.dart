import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:tcc_flutter/models/device.dart';
import 'package:tcc_flutter/pages/dashboard_screen/drag_n_drop.dart';
import 'package:tcc_flutter/routing/app_router.dart';
import 'package:tcc_flutter/services/app_state.dart';
import 'package:tcc_flutter/services/device_channels.dart';
import 'package:tcc_flutter/theme/app_theme.dart';

/// Resolves the device named in the URL from [appState] and keeps the
/// screen in sync with live status updates, so deep links and page
/// reloads land on the same screen as navigating from the device list.
class DeviceRoute extends StatelessWidget {
  final String deviceId;
  final Widget Function(Device device) builder;

  const DeviceRoute({super.key, required this.deviceId, required this.builder});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: appState,
      builder: (context, _) {
        final device = appState.devices
            .where((d) => d.deviceId == deviceId)
            .firstOrNull;

        if (device == null) {
          return const NotFoundPage(message: 'Dispositivo não encontrado.');
        }

        // Same rule the device list uses: a device only counts as
        // connected while its status heartbeat is fresh.
        final connected =
            device.isConnected && appState.isDeviceFresh(device.deviceId);
        return builder(device.copyWith(isConnected: connected));
      },
    );
  }
}

/// Loads the device's channel configuration before opening the logic
/// editor, so the editor can be reached directly by URL.
class LogicBuilderLoader extends StatefulWidget {
  final Device device;

  const LogicBuilderLoader({super.key, required this.device});

  @override
  State<LogicBuilderLoader> createState() => _LogicBuilderLoaderState();
}

class _LogicBuilderLoaderState extends State<LogicBuilderLoader> {
  DeviceChannels? _channels;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final channels = await loadDeviceChannels(
        widget.device.deviceId,
        context,
      );
      if (mounted) setState(() => _channels = channels);
    });
  }

  @override
  Widget build(BuildContext context) {
    final channels = _channels;
    if (channels == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return VisualLogicBuilderPage(
      device: widget.device,
      aiCfg: channels.ai,
      diCfg: channels.di,
      aoCfg: channels.ao,
      doCfg: channels.doo,
    );
  }
}

/// Shown for unknown URLs and for devices that are not in the user's list.
class NotFoundPage extends StatelessWidget {
  final String message;

  const NotFoundPage({super.key, this.message = 'Página não encontrada.'});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.search_off,
              size: 48,
              color: AppColors.foregroundMuted,
            ),
            const SizedBox(height: 16),
            Text(
              message,
              style: const TextStyle(
                fontSize: AppFontSize.lg,
                color: AppColors.foregroundSecondary,
              ),
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: () => context.go(AppRoutes.devices),
              child: const Text('Voltar para os dispositivos'),
            ),
          ],
        ),
      ),
    );
  }
}

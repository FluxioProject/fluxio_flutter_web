import 'package:flutter/material.dart';
import 'package:tcc_flutter/backend_api/api_communication.dart';
import 'package:tcc_flutter/models/channel_config.dart';
import 'package:tcc_flutter/widgets/show_message.dart';

/// Channel configuration of one device, grouped by IO type.
class DeviceChannels {
  final List<ChannelConfig> ai = List.generate(
    4,
    (i) => ChannelConfig(name: 'AI ${i + 1}'),
  );
  final List<ChannelConfig> ao = List.generate(
    4,
    (i) => ChannelConfig(name: 'AO ${i + 1}'),
  );
  final List<ChannelConfig> di = List.generate(
    4,
    (i) => ChannelConfig(name: 'DI ${i + 1}', analog: false),
  );
  final List<ChannelConfig> doo = List.generate(
    4,
    (i) => ChannelConfig(name: 'DO ${i + 1}', analog: false),
  );
}

// Applies the backend's per-channel data (name, min/max, notify flags,
// etc.) onto a default ChannelConfig list. Mirrors
// DeviceDetailsPage._loadAllChannelsFromBackend's applyCfg, so the logic
// editor sees the same channel metadata as the dashboard.
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

/// Fetches the device's channel configuration from the backend and applies
/// the locally saved visibility preferences.
///
/// Falls back to the default channel names when the backend call fails, so
/// the caller can still open the screen.
Future<DeviceChannels> loadDeviceChannels(
  String deviceId,
  BuildContext context,
) async {
  final channels = DeviceChannels();

  try {
    final res = await Session().getObj(
      'devices/get-all-channels?deviceId=$deviceId',
      context,
    );

    if (res is Map<String, dynamic>) {
      _applyChannelData(channels.ai, res['ai'], true);
      _applyChannelData(channels.ao, res['ao'], true);
      _applyChannelData(channels.di, res['di'], false);
      _applyChannelData(channels.doo, res['do'], false);
    }
  } catch (e) {
    if (context.mounted) {
      showMessage(context, 'Erro ao carregar canais: $e', true);
    }
  }

  await applyChannelVisibilityPrefs(deviceId, {
    'ai': channels.ai,
    'ao': channels.ao,
    'di': channels.di,
    'do': channels.doo,
  });

  return channels;
}

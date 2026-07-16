import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class ChannelConfig {
  String name;
  String unit;
  double mapMin; // physical value mapped to 4mA
  double mapMax; // physical value mapped to 20mA
  double min;
  double max;
  int decimals;
  bool visible;
  final bool analog;
  bool notifyMobile;
  bool notifyEmail;
  bool notifySms;

  // Dedicated field for digital channels (DI/DO): 0 = fires on OFF,
  // 1 = fires on ON. Kept separate from min/max, which are meaningless
  // for digital channels and only apply to analog ones.
  int trigger;

  ChannelConfig({
    required this.name,
    this.unit = '',
    this.min = 0,
    this.max = 100,
    this.decimals = 2,
    this.visible = true,
    this.analog = true,
    this.notifyMobile = false,
    this.notifyEmail = false,
    this.notifySms = false,
    this.mapMin = 0,
    this.mapMax = 100,
    this.trigger = 1,
  });
}

Future<void> applyChannelVisibilityPrefs(
  String deviceId,
  Map<String, List<ChannelConfig>> groups,
) async {
  final prefs = await SharedPreferences.getInstance();
  for (final entry in groups.entries) {
    final type = entry.key;
    final list = entry.value;
    for (int i = 0; i < list.length; i++) {
      final key = 'device_${deviceId}_${type}_$i';
      final raw = prefs.getString(key);
      if (raw == null) continue;
      final data = jsonDecode(raw) as Map<String, dynamic>;
      list[i].visible = data['visible'] ?? list[i].visible;
    }
  }
}
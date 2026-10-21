class Device {
  final String name;
  final String deviceId;
  final bool isConnected;
  final String? ipAddress;

  // Current version actually running on the device — kept live via the
  // MQTT status topic (see AppState.updateDeviceStatus).
  final String? fwVersion;

  // Latest version committed in the backend for this device — fetched
  // on demand via AppState.getLatestFirmwareVersion. Null until fetched.
  final String? latestFwVersion;

  final int? uptimeSec;

  Device({
    required this.name,
    required this.deviceId,
    this.isConnected = false,
    this.ipAddress,
    this.fwVersion,
    this.latestFwVersion,
    this.uptimeSec,
  });

  bool get updateAvailable =>
      latestFwVersion != null &&
      fwVersion != null &&
      latestFwVersion != fwVersion;

  // The firmware derives the ID from the ESP32 eFuse MAC: "esp32_"
  // followed by 12 hex digits (see updateDeviceID() in the firmware).
  static final RegExp _idPattern = RegExp(
    r'^esp32_[0-9a-f]{12}$',
    caseSensitive: false,
  );

  /// Example shown to users typing a device ID by hand.
  static const String idExample = 'esp32_A1B2C3D4E5F6';

  /// Returns [input] in the exact form the firmware reports it (lowercase
  /// prefix, uppercase hex digits), or null when it is not a valid ID.
  static String? normalizeId(String input) {
    final id = input.trim();
    if (!_idPattern.hasMatch(id)) return null;
    return 'esp32_${id.substring(6).toUpperCase()}';
  }

  factory Device.fromBackend(Map<String, dynamic> json) {
    return Device(
      name: json['name'] as String,
      deviceId: json['deviceId'] as String,
      fwVersion: json['fwVersion'] as String?,
    );
  }

  Device copyWith({
    String? name,
    bool? isConnected,
    String? ipAddress,
    int? uptimeSec,
    String? fwVersion,
    String? latestFwVersion,
  }) {
    return Device(
      name: name ?? this.name,
      deviceId: deviceId,
      isConnected: isConnected ?? this.isConnected,
      ipAddress: ipAddress ?? this.ipAddress,
      uptimeSec: uptimeSec ?? this.uptimeSec,
      fwVersion: fwVersion ?? this.fwVersion,
      latestFwVersion: latestFwVersion ?? this.latestFwVersion,
    );
  }
}
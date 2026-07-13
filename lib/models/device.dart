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
class Device {
  final String name;
  final String deviceId;
  final bool isConnected;
  final String? ipAddress;
  // Firmware version reported by the backend. Nullable because the
  // backend may not send this field yet — the UI falls back to a
  // placeholder whenever this is null.
  final String? fwVersion;

  Device({
    required this.name,
    required this.deviceId,
    this.isConnected = false,
    this.ipAddress,
    this.fwVersion,
  });

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
    String? fwVersion,
  }) {
    return Device(
      name: name ?? this.name,
      deviceId: deviceId,
      isConnected: isConnected ?? this.isConnected,
      ipAddress: ipAddress ?? this.ipAddress,
      fwVersion: fwVersion ?? this.fwVersion,
    );
  }
}
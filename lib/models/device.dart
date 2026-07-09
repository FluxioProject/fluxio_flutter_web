class Device {
  final String name;
  final String deviceId;
  final bool isConnected;
  final String? ipAddress;

  Device({
    required this.name,
    required this.deviceId,
    this.isConnected = false,
    this.ipAddress,
  });

  factory Device.fromBackend(Map<String, dynamic> json) {
    return Device(
      name: json['name'] as String,
      deviceId: json['deviceId'] as String,
    );
  }

  Device copyWith({String? name, bool? isConnected, String? ipAddress}) {
    return Device(
      name: name ?? this.name,
      deviceId: deviceId,
      isConnected: isConnected ?? this.isConnected,
      ipAddress: ipAddress ?? this.ipAddress,
    );
  }
}
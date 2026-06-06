class Device {
  final String name;
  final String deviceId;

  Device({
    required this.name,
    required this.deviceId,
  });

  factory Device.fromBackend(Map<String, dynamic> json) {
    return Device(
      name: json['name'] as String,
      deviceId: json['deviceId'] as String,
    );
  }

  Device copyWith({String? name}) {
    return Device(
      name: name ?? this.name,
      deviceId: deviceId,
    );
  }
}
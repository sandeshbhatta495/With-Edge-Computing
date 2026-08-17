class GpsData {
  final String deviceId;
  final double battery;
  final double latitude;
  final double longitude;
  final double altitude;
  final int satellites;
  final double speed;
  final bool moving;
  final String timestamp;
  final int rssi;
  final double snr;

  GpsData({
    required this.deviceId,
    required this.battery,
    required this.latitude,
    required this.longitude,
    required this.altitude,
    required this.satellites,
    required this.speed,
    required this.moving,
    required this.timestamp,
    required this.rssi,
    required this.snr,
  });

  factory GpsData.fromJson(Map<String, dynamic> json) {
    return GpsData(
      deviceId: json['device_id']?.toString() ?? '',
      battery: (json['battery'] as num).toDouble(),
      latitude: (json['latitude'] as num).toDouble(),
      longitude: (json['longitude'] as num).toDouble(),
      altitude: (json['altitude'] as num?)?.toDouble() ?? 0.0,
      satellites: (json['satellites'] as num?)?.toInt() ?? 0,
      speed: (json['speed'] as num?)?.toDouble() ?? 0.0,
      moving: (json['movement'] as num?)?.toInt() == 1,
      timestamp: json['timestamp']?.toString() ?? '',
      rssi: (json['rssi'] as num?)?.toInt() ?? 0,
      snr: (json['snr'] as num?)?.toDouble() ?? 0.0,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'device_id': deviceId,
      'latitude': latitude,
      'longitude': longitude,
      'battery': battery,
      'timestamp': timestamp,
    };
  }
}

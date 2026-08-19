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

  // Collar-reported boundary status.
  // Expected values: INSIDE / OUTSIDE.
  final String boundaryStatus;

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
    this.boundaryStatus = 'UNKNOWN',
  });

  factory GpsData.fromJson(Map<String, dynamic> json) {
    return GpsData(
      deviceId: json['device_id']?.toString() ?? '',

      battery: (json['battery'] as num?)?.toDouble() ?? 0.0,

      latitude: (json['latitude'] as num?)?.toDouble() ?? 0.0,

      longitude: (json['longitude'] as num?)?.toDouble() ?? 0.0,

      altitude: (json['altitude'] as num?)?.toDouble() ?? 0.0,

      satellites: (json['satellites'] as num?)?.toInt() ?? 0,

      speed: (json['speed'] as num?)?.toDouble() ?? 0.0,

      moving: (json['movement'] as num?)?.toInt() == 1,

      timestamp: json['timestamp']?.toString() ?? '',

      rssi: (json['rssi'] as num?)?.toInt() ?? 0,

      snr: (json['snr'] as num?)?.toDouble() ?? 0.0,

      // Collar boundary status.
      boundaryStatus:
          json['boundaryStatus']?.toString().toUpperCase() ?? 'UNKNOWN',
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'device_id': deviceId,
      'latitude': latitude,
      'longitude': longitude,
      'battery': battery,
      'timestamp': timestamp,
      'boundaryStatus': boundaryStatus,
    };
  }
}

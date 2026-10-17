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
  final int zone;
  final int flags;
  final String reportedTime;
  final int hop;
  final int ageSec;

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
    this.zone = 0,
    this.flags = 0,
    this.reportedTime = ' ',
    this.hop = 0,
    this.ageSec = 0,
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
      zone: (json['zone'] as num?)?.toInt() ?? 0,
      flags: (json['flags'] as num?)?.toInt() ?? 0,
      reportedTime: json['reported_time']?.toString() ?? '',
    );
  }

  /// Parses the base-station telemetry format:
  /// DATA,A01,battery,lat,lon,altitude,satellites,speed,movement
  factory GpsData.fromCsv(String packet, {int rssi = 0, double snr = 0.0}) {
    final fields = packet.split(',').map((field) => field.trim()).toList();
    if (fields.length < 9 || fields[0] != 'DATA') {
      throw const FormatException('Invalid DATA packet');
    }

    final zone = fields.length > 9 ? int.tryParse(fields[9]) ?? 0 : 0;
    final flags = fields.length > 10 ? int.tryParse(fields[10]) ?? 0 : 0;
    final reportedTime = fields.length > 11 ? fields[11] : '';
    final boundaryStatus = switch (zone) {
      1 => 'INSIDE',
      2 => 'NEAR_FENCE',
      3 => 'OUTSIDE',
      _ => 'UNKNOWN',
    };

    return GpsData(
      deviceId: fields[1],
      battery: double.tryParse(fields[2]) ?? 0.0,
      latitude: double.tryParse(fields[3]) ?? 0.0,
      longitude: double.tryParse(fields[4]) ?? 0.0,
      altitude: double.tryParse(fields[5]) ?? 0.0,
      satellites: int.tryParse(fields[6]) ?? 0,
      speed: double.tryParse(fields[7]) ?? 0.0,
      moving: fields[8] == '1',
      timestamp: DateTime.now().toUtc().toIso8601String(),
      rssi: rssi,
      snr: snr,
      boundaryStatus: boundaryStatus,
      zone: zone,
      flags: flags,
      reportedTime: reportedTime,
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
      'zone': zone,
      'flags': flags,
      'reported_time': reportedTime,
    };
  }
}

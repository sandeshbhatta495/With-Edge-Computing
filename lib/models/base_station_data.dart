class BaseStationData {
  final String deviceId;
  final double battery;
  final int uptime;

  BaseStationData({
    required this.deviceId,
    required this.battery,
    required this.uptime,
  });

  factory BaseStationData.fromJson(Map<String, dynamic> json) {
    return BaseStationData(
      deviceId: json['device_id']?.toString() ?? 'BASE01',
      battery: (json['battery'] as num).toDouble(),
      uptime: (json['uptime'] as num?)?.toInt() ?? 0,
    );
  }
}

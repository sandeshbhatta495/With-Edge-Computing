class DashboardRecord {
  final String animalId;
  final double latitude;
  final double longitude;
  final String status;
  final DateTime timestamp;

  DashboardRecord({
    required this.animalId,
    required this.latitude,
    required this.longitude,
    required this.status,
    required this.timestamp,
  });

  factory DashboardRecord.fromMap(Map<String, dynamic> map) {
    return DashboardRecord(
      animalId: map["Animal_ID"],
      latitude: map["Latitude"],
      longitude: map["Longitude"],
      status: map["Geofence_Status"],
      timestamp: DateTime.parse(
        map["Last_Updated"] ?? map["Timestamp"],
      ),
    );
  }
}
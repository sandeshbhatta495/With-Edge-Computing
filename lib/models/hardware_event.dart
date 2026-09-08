class HardwareAlert {
  final String animalId;
  final String type;
  final String data;

  const HardwareAlert({
    required this.animalId,
    required this.type,
    required this.data,
  });

  factory HardwareAlert.fromCsv(String packet) {
    final fields = packet.split(',').map((field) => field.trim()).toList();
    if (fields.length < 4 || fields[0] != 'ALERT') {
      throw const FormatException('Invalid ALERT packet');
    }
    return HardwareAlert(
      animalId: fields[1],
      type: fields[2],
      data: fields.sublist(3).join(','),
    );
  }
}

class StoredHardwareEvent {
  final int id;
  final String animalId;
  final String packetId;
  final String type;
  final String data;

  const StoredHardwareEvent({
    required this.id,
    required this.animalId,
    required this.packetId,
    required this.type,
    required this.data,
  });

  factory StoredHardwareEvent.fromCsv(String packet) {
    final fields = packet.split(',').map((field) => field.trim()).toList();
    if (fields.length < 6 || fields[0] != 'EVENT') {
      throw const FormatException('Invalid EVENT packet');
    }
    return StoredHardwareEvent(
      id: int.tryParse(fields[1]) ?? 0,
      animalId: fields[2],
      packetId: fields[3],
      type: fields[4],
      data: fields.sublist(5).join(','),
    );
  }
}

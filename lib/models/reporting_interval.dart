enum ReportingInterval { oneMinute, fiveMinutes, thirtyMinutes, movementBased }

extension ReportingIntervalX on ReportingInterval {
  String get label {
    switch (this) {
      case ReportingInterval.oneMinute:
        return '1 minute';
      case ReportingInterval.fiveMinutes:
        return '5 minutes';
      case ReportingInterval.thirtyMinutes:
        return '30 minutes';
      case ReportingInterval.movementBased:
        return 'Movement-based';
    }
  }

  /// Seconds between transmissions. Not meaningful for movementBased.
  int get seconds {
    switch (this) {
      case ReportingInterval.oneMinute:
        return 60;
      case ReportingInterval.fiveMinutes:
        return 300;
      case ReportingInterval.thirtyMinutes:
        return 1800;
      case ReportingInterval.movementBased:
        return 0;
    }
  }

  static ReportingInterval fromStorageKey(String? key) {
    return ReportingInterval.values.firstWhere(
      (e) => e.name == key,
      orElse: () => ReportingInterval.oneMinute,
    );
  }
}

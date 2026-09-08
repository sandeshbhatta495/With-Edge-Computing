import 'package:flutter_riverpod/legacy.dart'; // <-- add this
import 'package:shared_preferences/shared_preferences.dart';

import '../models/reporting_interval.dart';

const _prefsKey = 'reporting_interval';

class ReportingIntervalNotifier extends StateNotifier<ReportingInterval> {
  ReportingIntervalNotifier() : super(ReportingInterval.oneMinute) {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_prefsKey);
    if (saved != null) {
      state = ReportingIntervalX.fromStorageKey(saved);
    }
  }

  /// Updates the interval, persists it, and — if connected — sends
  /// the configuration command to the base station. The base station
  /// and collar don't act on this command yet; this is prepared ahead
  /// of that firmware work.
  Future<void> setInterval(ReportingInterval interval) async {
    state = interval;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, interval.name);

    // The multihop firmware uses scheduled POLL packets and LIVE on/off;
    // it does not implement the legacy SET_INTERVAL command.
  }
}

final reportingIntervalProvider =
    StateNotifierProvider<ReportingIntervalNotifier, ReportingInterval>(
      (ref) => ReportingIntervalNotifier(),
    );

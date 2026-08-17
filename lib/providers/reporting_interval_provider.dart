import 'package:flutter_riverpod/legacy.dart'; // <-- add this
import 'package:shared_preferences/shared_preferences.dart';

import '../models/reporting_interval.dart';
import '../services/livestock_websocket_service.dart';

const _prefsKey = 'reporting_interval';

class ReportingIntervalNotifier extends StateNotifier<ReportingInterval> {
  ReportingIntervalNotifier() : super(ReportingInterval.oneMinute) {
    _load();
  }

  final LivestockWebSocketService _esp = LivestockWebSocketService();

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

    if (_esp.isConnected) {
      _esp.send(interval.command);
    }
  }
}

final reportingIntervalProvider =
    StateNotifierProvider<ReportingIntervalNotifier, ReportingInterval>(
      (ref) => ReportingIntervalNotifier(),
    );

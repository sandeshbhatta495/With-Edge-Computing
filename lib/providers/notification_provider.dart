import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/foundation.dart';

import '../database/database_helper.dart';
import '../services/background_service.dart';

enum LogEventType {
  boundaryCreated,
  boundaryAdjusted,
  boundaryDeleted,
  mapDownloaded,
  boundaryBreached,
  deviceConnected,
  deviceDisconnected,
  geofence,
  battery,
}

class LogEvent {
  final LogEventType type;
  final String message;
  final DateTime timestamp;

  LogEvent({required this.type, required this.message, DateTime? timestamp})
    : timestamp = timestamp ?? DateTime.now();
}

class NotificationNotifier extends Notifier<List<LogEvent>> {
  int sessionStartCount = 0;
  void clearNotifications() {
    state = [];
  }

  @override
  List<LogEvent> build() {
    _loadLogs();
    return [];
  }

  Future<void> _loadLogs() async {
    try {
      final rows = await DatabaseHelper.instance.getLogs();

      final loadedLogs = <LogEvent>[];

      for (final row in rows) {
        final typeName = row['type'] as String?;

        if (typeName == null) {
          continue;
        }

        final type = LogEventType.values.where(
          (eventType) => eventType.name == typeName,
        );

        if (type.isEmpty) {
          continue;
        }

        final message = row['message'] as String?;

        final timestampString = row['timestamp'] as String?;

        if (message == null || timestampString == null) {
          continue;
        }

        DateTime timestamp;

        try {
          timestamp = DateTime.parse(timestampString);
        } catch (_) {
          timestamp = DateTime.now();
        }

        loadedLogs.add(
          LogEvent(type: type.first, message: message, timestamp: timestamp),
        );
      }

      sessionStartCount = loadedLogs.length;
      state = loadedLogs;
    } catch (e) {
      // Keep the provider alive even if the database
      // cannot be read.
      debugPrint('Failed to load notification logs: $e');
    }
  }

  Future<void> log(LogEventType type, String message) async {
    final event = LogEvent(type: type, message: message);

    // Immediately update the UI.
    state = [...state, event];

    try {
      // Save notification to database.
      await DatabaseHelper.instance.insertLog(
        type.name,
        message,
        event.timestamp,
      );

      // Show system/local notification.
      await BackgroundService.showAlert(title: _titleFor(type), body: message);
    } catch (e) {
      debugPrint('Failed to save/show notification: $e');
    }
  }

  String _titleFor(LogEventType type) {
    switch (type) {
      case LogEventType.boundaryCreated:
        return 'Geofence Created';

      case LogEventType.boundaryAdjusted:
        return 'Geofence Adjusted';

      case LogEventType.boundaryDeleted:
        return 'Geofence Deleted';

      case LogEventType.mapDownloaded:
        return 'Map Downloaded';

      case LogEventType.boundaryBreached:
        return 'Geofence Alert';

      case LogEventType.deviceConnected:
        return 'Device Connected';

      case LogEventType.deviceDisconnected:
        return 'Device Disconnected';

      case LogEventType.geofence:
        return 'Geofence Alert';

      case LogEventType.battery:
        return 'Low Battery';
    }
  }

  Future<void> logBoundaryCreated() async {
    await log(LogEventType.boundaryCreated, 'Boundary created');
  }

  Future<void> logBoundaryAdjusted() async {
    await log(LogEventType.boundaryAdjusted, 'Boundary adjusted');
  }

  Future<void> logBoundaryDeleted() async {
    await log(LogEventType.boundaryDeleted, 'Boundary deleted');
  }

  Future<void> logBoundaryBreached() async {
    await log(LogEventType.boundaryBreached, 'Livestock has left the boundary');
  }

  Future<void> logDeviceConnected() async {
    await log(LogEventType.deviceConnected, 'Device connected');
  }

  Future<void> logDeviceDisconnected() async {
    await log(LogEventType.deviceDisconnected, 'Device disconnected');
  }

  Future<void> logLowBattery() async {
    await log(LogEventType.battery, 'Livestock device battery is low');
  }
}

final notificationProvider =
    NotifierProvider<NotificationNotifier, List<LogEvent>>(
      NotificationNotifier.new,
    );

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:latlong2/latlong.dart';

import '../database/database_helper.dart';
import '../models/reporting_interval.dart';
import '../providers/notification_provider.dart';
import '../providers/provider_container.dart';
import 'package:livestock_tracker/services/geofence_service.dart';
import 'package:livestock_tracker/services/wifi_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'livestock_websocket_service.dart';

final Map<String, bool> _previousGeofenceState = {};
final Map<String, DateTime> _lastHistorySaved = {};
ReportingInterval _reportingInterval = ReportingInterval.oneMinute;
final Map<String, double> _lastBatteryNotification = {};
final Map<String, DateTime> _onlineAnimals = {};

class BackgroundService {
  static final FlutterBackgroundService _service = FlutterBackgroundService();

  static final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();

  // ------------------------------------------------------------
  // SHOW ALERT
  // ------------------------------------------------------------

  static Future<void> showAlert({
    required String title,
    required String body,
  }) async {
    const android = AndroidNotificationDetails(
      'livestock_alerts',
      'Livestock Alerts',
      channelDescription: 'Geofence alerts',
      importance: Importance.max,
      priority: Priority.high,
    );

    await _notifications.show(
      DateTime.now().millisecondsSinceEpoch ~/ 1000,
      title,
      body,
      const NotificationDetails(android: android),
    );
  }

  // ------------------------------------------------------------
  // INITIALIZE BACKGROUND SERVICE
  // ------------------------------------------------------------

  static Future<void> initialize() async {
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');

    await _notifications.initialize(
      const InitializationSettings(android: android),
    );

    await _service.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: onStart,
        autoStart: false,
        isForegroundMode: true,
        foregroundServiceNotificationId: 100,
        initialNotificationTitle: 'Livestock Tracker',
        initialNotificationContent: 'Monitoring livestock...',
      ),
      iosConfiguration: IosConfiguration(),
    );
  }

  // ------------------------------------------------------------
  // START SERVICE
  // ------------------------------------------------------------

  static Future<void> start() async {
    final started = await _service.startService();

    debugPrint('Background service started: $started');
  }

  // ------------------------------------------------------------
  // STOP SERVICE
  // ------------------------------------------------------------

  static Future<void> stop() async {
    _service.invoke('stop');
  }
}

Future<void> _loadReportingInterval() async {
  final prefs = await SharedPreferences.getInstance();

  final saved = prefs.getString('reporting_interval');

  _reportingInterval = ReportingIntervalX.fromStorageKey(saved);

  debugPrint(
    'Reporting interval loaded: '
    '${_reportingInterval.label}',
  );
}

bool _shouldSaveHistory({required String animalId, required bool moving}) {
  final now = DateTime.now();

  final lastSaved = _lastHistorySaved[animalId];

  if (lastSaved == null) {
    _lastHistorySaved[animalId] = now;
    return true;
  }

  switch (_reportingInterval) {
    case ReportingInterval.oneMinute:
      if (now.difference(lastSaved).inMinutes >= 1) {
        _lastHistorySaved[animalId] = now;
        return true;
      }
      break;

    case ReportingInterval.fiveMinutes:
      if (now.difference(lastSaved).inMinutes >= 5) {
        _lastHistorySaved[animalId] = now;
        return true;
      }
      break;

    case ReportingInterval.thirtyMinutes:
      if (now.difference(lastSaved).inMinutes >= 30) {
        _lastHistorySaved[animalId] = now;
        return true;
      }
      break;

    case ReportingInterval.movementBased:
      if (moving) {
        _lastHistorySaved[animalId] = now;
        return true;
      }
      break;
  }

  return false;
}

// ============================================================================
// BACKGROUND SERVICE ENTRY POINT
// ============================================================================

@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  debugPrint('onStart() called');
  await _loadReportingInterval();

  // ------------------------------------------------------------
  // ANDROID FOREGROUND SERVICE
  // ------------------------------------------------------------

  if (service is AndroidServiceInstance) {
    service.setAsForegroundService();

    await service.setForegroundNotificationInfo(
      title: 'Livestock Tracker',
      content: 'No animals online',
    );
  }

  // Listen to live WebSocket telemetry stream for active online animals count
  LivestockWebSocketService().animalStream.listen((animal) async {
    final before = _onlineAnimals.length;
    _onlineAnimals[animal.deviceId] = DateTime.now();
    final after = _onlineAnimals.length;

    if (after != before && service is AndroidServiceInstance) {
      final text = after == 1 ? '1 animal online' : '$after animals online';
      await service.setForegroundNotificationInfo(
        title: 'Livestock Tracker',
        content: text,
      );
    }
  });

  // ------------------------------------------------------------
  // WIFI SERVICE
  // ------------------------------------------------------------

  final wifi = WifiService();

  // Initial connection attempt.
  await connectToEsp(wifi);

  final reconnectTimer = Timer.periodic(const Duration(seconds: 5), (
    timer,
  ) async {
    try {
      if (!wifi.isConnected) {
        await connectToEsp(wifi);
      }
    } catch (_) {}
  });

  final cleanupTimer = Timer.periodic(const Duration(seconds: 10), (
    timer,
  ) async {
    try {
      final now = DateTime.now();
      final before = _onlineAnimals.length;

      _onlineAnimals.removeWhere((deviceId, lastSeen) {
        final elapsed = now.difference(lastSeen).inSeconds;
        return elapsed > 30;
      });

      final after = _onlineAnimals.length;

      if (after != before && service is AndroidServiceInstance) {
        final text = after == 0
            ? 'No animals online'
            : (after == 1 ? '1 animal online' : '$after animals online');
        await service.setForegroundNotificationInfo(
          title: 'Livestock Tracker',
          content: text,
        );
      }
    } catch (_) {}
  });

  // ============================================================
  // STOP SERVICE
  // ============================================================

  service.on('stop').listen((event) {
    debugPrint('Stopping background service...');

    // Cancel both timers.
    reconnectTimer.cancel();
    cleanupTimer.cancel();

    debugPrint('Reconnect timer cancelled');

    debugPrint('Cleanup timer cancelled');

    service.stopSelf();
  });

  // ============================================================
  // WIFI MESSAGE LISTENER
  // ============================================================

  wifi.messages.listen(
    (json) async {
      try {
        debugPrint('Received ESP message: $json');

        // --------------------------------------------------------
        // DEVICE ID
        // --------------------------------------------------------

        final deviceId = json['device_id'];

        if (deviceId == null) {
          debugPrint('Received message without device_id');

          return;
        }

        final String animalId = deviceId.toString();

        // --------------------------------------------------------
        // UPDATE ONLINE ANIMAL
        // --------------------------------------------------------

        final before = _onlineAnimals.length;

        _onlineAnimals[animalId] = DateTime.now();

        final after = _onlineAnimals.length;

        // --------------------------------------------------------
        // UPDATE FOREGROUND NOTIFICATION
        // ONLY WHEN A NEW ANIMAL COMES ONLINE
        // --------------------------------------------------------

        if (after != before && service is AndroidServiceInstance) {
          await service.setForegroundNotificationInfo(
            title: 'Livestock Tracker',
            content: '$after animals online',
          );

          debugPrint(
            'Foreground notification updated: '
            '$after animals online',
          );
        }

        // --------------------------------------------------------
        // GPS DATA
        // --------------------------------------------------------

        final latitude = (json['latitude'] as num).toDouble();

        final longitude = (json['longitude'] as num).toDouble();

        // --------------------------------------------------------
        // BATTERY
        // --------------------------------------------------------

        final battery = (json['battery'] as num).toDouble();

        // --------------------------------------------------------
        // LOW BATTERY NOTIFICATION
        // --------------------------------------------------------

        final lastBattery = _lastBatteryNotification[animalId];

        if (battery <= 15 && lastBattery != battery) {
          _lastBatteryNotification[animalId] = battery;

          providerContainer
              .read(notificationProvider.notifier)
              .log(LogEventType.battery, '$animalId battery is $battery%');

          debugPrint(
            'Low battery notification: '
            '$animalId = $battery%',
          );
        }

        // --------------------------------------------------------
        // TIMESTAMP
        // --------------------------------------------------------

        final timestamp = json['timestamp'] as String;

        // --------------------------------------------------------
        // GET GEOFENCE
        // --------------------------------------------------------

        final fence = await DatabaseHelper.instance.getGeofence();

        if (fence == null) {
          debugPrint('No geofence configured.');

          return;
        }

        final geofenceId = fence['id'] as int;

        // --------------------------------------------------------
        // GET GEOFENCE POLYGON
        // --------------------------------------------------------

        final polygon = await DatabaseHelper.instance.getGeofencePoints(
          geofenceId,
        );

        // --------------------------------------------------------
        // POINT-IN-POLYGON CHECK
        // --------------------------------------------------------

        final inside = GeofenceUtils.isPointInsidePolygon(
          LatLng(latitude, longitude),
          polygon,
        );

        final geofenceStatus = inside ? 'inside' : 'outside';

        debugPrint(
          '$animalId is $geofenceStatus '
          'the geofence',
        );

        // --------------------------------------------------------
        // PREVIOUS GEOFENCE STATE
        // --------------------------------------------------------

        final previous = _previousGeofenceState[animalId];

        // --------------------------------------------------------
        // FIRST GPS LOCATION
        // --------------------------------------------------------

        if (previous == null) {
          _previousGeofenceState[animalId] = inside;

          debugPrint(
            'Initial geofence state for '
            '$animalId: $geofenceStatus',
          );
        }
        // --------------------------------------------------------
        // GEOFENCE STATE CHANGED
        // --------------------------------------------------------
        else if (previous != inside) {
          _previousGeofenceState[animalId] = inside;

          if (inside) {
            providerContainer
                .read(notificationProvider.notifier)
                .log(LogEventType.geofence, '$animalId entered the geofence.');

            debugPrint('$animalId entered the geofence');
          } else {
            providerContainer
                .read(notificationProvider.notifier)
                .log(LogEventType.geofence, '$animalId left the geofence!');

            debugPrint('$animalId left the geofence');
          }
        }

        // --------------------------------------------------------
        // UPDATE DASHBOARD
        // --------------------------------------------------------

        await DatabaseHelper.instance.updateDashboard(
          animalId: animalId,
          latitude: latitude,
          longitude: longitude,
          status: geofenceStatus,
          battery: battery,
          timestamp: timestamp,
          geofenceId: geofenceId,
        );

        // --------------------------------------------------------
        // SAVE LOCATION HISTORY
        // --------------------------------------------------------

        final movement = (json['movement'] as num?)?.toInt() ?? 0;

        final shouldSaveHistory = _shouldSaveHistory(
          animalId: animalId,
          moving: movement == 1,
        );

        if (shouldSaveHistory) {
          await DatabaseHelper.instance.insertDashboardHistory(
            animalId: animalId,
            latitude: latitude,
            longitude: longitude,
            status: geofenceStatus,
            battery: battery,
            timestamp: timestamp,
            geofenceId: geofenceId,
          );

          debugPrint(
            'History saved for $animalId '
            '(${_reportingInterval.label})',
          );
        }
      } catch (e, stackTrace) {
        debugPrint('Error processing ESP message: $e');

        debugPrint('$stackTrace');
      }
    },
    onError: (error) {
      debugPrint('WiFi message stream error: $error');
    },
  );
}

// ============================================================================
// ESP CONNECTION
// ============================================================================

Future<void> connectToEsp(WifiService wifi) async {
  while (!wifi.isConnected) {
    try {
      final connected = await wifi.connect();

      if (connected) {
        debugPrint('Connected to ESP Base Station');
        return;
      }
    } catch (_) {
      // Quiet background polling without console log spam
    }

    await Future.delayed(const Duration(seconds: 5));
  }
}

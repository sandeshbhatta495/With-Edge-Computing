import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:async';
import '../providers/notification_provider.dart';
import '../models/hardware_event.dart';
import '../services/livestock_websocket_service.dart';

class AlertsScreen extends ConsumerStatefulWidget {
  const AlertsScreen({super.key});

  @override
  ConsumerState<AlertsScreen> createState() => _AlertsScreenState();
}

class _AlertsScreenState extends ConsumerState<AlertsScreen> {
  final _hardware = LivestockWebSocketService();
  final _storedEvents = <StoredHardwareEvent>[];
  StreamSubscription<StoredHardwareEvent>? _eventSubscription;

  @override
  void initState() {
    super.initState();
    _eventSubscription = _hardware.storedEventStream.listen((event) {
      if (!mounted || _storedEvents.any((item) => item.id == event.id)) return;
      setState(() => _storedEvents.add(event));
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _hardware.requestStoredEvents();
    });
  }

  @override
  void dispose() {
    _eventSubscription?.cancel();
    super.dispose();
  }

  IconData _iconFor(LogEventType type) {
    switch (type) {
      case LogEventType.boundaryCreated:
        return Icons.check_circle;
      case LogEventType.boundaryBreached:
        return Icons.warning;
      case LogEventType.deviceConnected:
        return Icons.wifi;
      case LogEventType.deviceDisconnected:
        return Icons.wifi_off;
      case LogEventType.boundaryAdjusted:
        return Icons.edit;
      case LogEventType.boundaryDeleted:
        return Icons.delete;
      case LogEventType.mapDownloaded:
        return Icons.download;
      case LogEventType.geofence:
        return Icons.outbond;
      case LogEventType.battery:
        return Icons.battery_alert;
    }
  }

  @override
  Widget build(BuildContext context) {
    final logs = ref.watch(notificationProvider);
    final sorted = [...logs]
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));

    final hardwareItems = _storedEvents.map(
      (event) => ListTile(
        leading: const Icon(Icons.sensors),
        title: Text('${event.animalId} ${event.type}'),
        subtitle: Text(event.data),
        trailing: IconButton(
          tooltip: 'Acknowledge hardware event',
          icon: const Icon(Icons.done),
          onPressed: () {
            _hardware.acknowledgeStoredEvent(event.id);
            setState(
              () => _storedEvents.removeWhere((item) => item.id == event.id),
            );
          },
        ),
      ),
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text("Alerts"),
        actions: [
          IconButton(
            tooltip: 'Sync hardware events',
            icon: const Icon(Icons.sync),
            onPressed: () {
              setState(_storedEvents.clear);
              _hardware.requestStoredEvents();
            },
          ),
        ],
      ),
      body: sorted.isEmpty && _storedEvents.isEmpty
          ? const Center(child: Text("No alerts yet"))
          : ListView(
              children: [
                ...hardwareItems,
                ...sorted.map(
                  (event) => ListTile(
                    leading: Icon(_iconFor(event.type)),
                    title: Text(event.message),
                    subtitle: Text(event.timestamp.toString()),
                  ),
                ),
              ],
            ),
    );
  }
}

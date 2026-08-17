import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/notification_provider.dart';

class AlertsScreen extends ConsumerWidget {
  const AlertsScreen({super.key});

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
  Widget build(BuildContext context, WidgetRef ref) {
    final logs = ref.watch(notificationProvider);
    final sorted = [...logs]
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));

    return Scaffold(
      appBar: AppBar(title: const Text("Alerts")),
      body: sorted.isEmpty
          ? const Center(child: Text("No alerts yet"))
          : ListView.builder(
              itemCount: sorted.length,
              itemBuilder: (context, index) {
                final event = sorted[index];
                return ListTile(
                  leading: Icon(_iconFor(event.type)),
                  title: Text(event.message),
                  subtitle: Text(event.timestamp.toString()),
                );
              },
            ),
    );
  }
}

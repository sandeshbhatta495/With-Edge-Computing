import 'package:flutter/material.dart';
import '../geofence/geofence.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/notification_provider.dart';

class GeofencePanel extends ConsumerWidget {
  final bool showGeofencePanel;
  final GeofenceController geofence;
  final VoidCallback refresh;

  const GeofencePanel({
    super.key,
    required this.showGeofencePanel,
    required this.geofence,
    required this.refresh,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AnimatedPositioned(
      duration: const Duration(milliseconds: 300),
      left: 0,
      right: 0,
      bottom: showGeofencePanel ? 0 : -120,
      child: Container(
        height: MediaQuery.of(context).size.height * 0.10,
        color: Colors.white,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            TextButton(
              onPressed: () {
                geofence.cancel();
                refresh();
              },
              child: const Text("Cancel"),
            ),
            ElevatedButton(
              onPressed: () {
                final isNew = geofence.savedPoints.isEmpty;
                geofence.save();
                if (isNew) {
                  ref
                      .read(notificationProvider.notifier)
                      .log(
                        LogEventType.boundaryCreated,
                        "Geofence created successfully",
                      );
                } else {
                  ref
                      .read(notificationProvider.notifier)
                      .log(
                        LogEventType.boundaryAdjusted,
                        "Geofence adjusted successfully",
                      );
                }
                refresh();
              },
              child: const Text("Save"),
            ),

            ElevatedButton(
              onPressed: () async {
                bool? confirm = await showDialog<bool>(
                  context: context,
                  builder: (context) {
                    return AlertDialog(
                      title: const Text("Delete Geofence"),
                      content: const Text(
                        "Are you sure you want to delete this geofence?",
                      ),
                      actions: [
                        TextButton(
                          onPressed: () {
                            Navigator.pop(context, false);
                          },
                          child: const Text("No"),
                        ),
                        TextButton(
                          onPressed: () {
                            Navigator.pop(context, true);
                          },
                          child: const Text("Yes"),
                        ),
                      ],
                    );
                  },
                );

                if (confirm == true) {
                  geofence.delete();
                  ref
                      .read(notificationProvider.notifier)
                      .log(
                        LogEventType.boundaryDeleted,
                        "Geofence deleted successfully",
                      );
                  refresh();
                }
              },
              child: const Text("Delete"),
            ),
          ],
        ),
      ),
    );
  }
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/hardware_event.dart';
import '../providers/notification_provider.dart';
import '../services/livestock_websocket_service.dart';

class AlertsScreen extends ConsumerStatefulWidget {
  const AlertsScreen({super.key});

  @override
  ConsumerState<AlertsScreen> createState() => _AlertsScreenState();
}

class _AlertsScreenState extends ConsumerState<AlertsScreen> {
  final _hardware = LivestockWebSocketService();

  final List<StoredHardwareEvent> _storedEvents = [];
  final List<StoredHardwareEvent> _syncEvents = [];
  final Set<int> _pendingAcknowledgments = {};

  StreamSubscription<StoredHardwareEvent>? _eventSubscription;
  StreamSubscription<StoredEventsSyncStatus>? _syncSubscription;
  StreamSubscription<String>? _ackSubscription;

  bool _syncing = false;

  @override
  void initState() {
    super.initState();

    _eventSubscription = _hardware.storedEventStream.listen((event) {
      if (!mounted) return;

      final target = _syncing ? _syncEvents : _storedEvents;

      if (target.any((item) => item.id == event.id)) return;

      setState(() => target.add(event));
    });

    _syncSubscription = _hardware.eventSyncStream.listen((status) {
      if (!mounted) return;

      switch (status) {
        case StoredEventsSyncStatus.syncing:
          break;

        case StoredEventsSyncStatus.completed:
          setState(() {
            _storedEvents
              ..clear()
              ..addAll(_syncEvents);
            _syncEvents.clear();
            _syncing = false;
          });
          break;

        case StoredEventsSyncStatus.empty:
          setState(() {
            _storedEvents.clear();
            _syncEvents.clear();
            _syncing = false;
          });
          break;

        case StoredEventsSyncStatus.failed:
          setState(() {
            _syncEvents.clear();
            _syncing = false;
          });
          _showMessage(
            'Hardware event sync failed. Existing events were preserved.',
            isError: true,
          );
          break;
      }
    });

    _ackSubscription = _hardware.ackStream.listen(_handleAcknowledgment);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _startSync();
    });
  }

  void _startSync() {
    if (_syncing) return;

    if (!_hardware.isConnected) {
      _showMessage(
        'Connect to the base station before syncing.',
        isError: true,
      );
      return;
    }

    setState(() {
      _syncing = true;
      _syncEvents.clear();
    });

    if (!_hardware.requestStoredEvents() && mounted) {
      setState(() {
        _syncing = false;
        _syncEvents.clear();
      });
      _showMessage('Could not start hardware event sync.', isError: true);
    }
  }

  void _handleAcknowledgment(String message) {
    if (!mounted) return;

    final parts = message.trim().split(',');
    if (parts.isEmpty) return;

    final response = parts[0].toUpperCase();

    if (response == 'EVENT_ACK_SUCCESS' && parts.length >= 2) {
      final id = int.tryParse(parts[1].trim());
      if (id == null || !_pendingAcknowledgments.contains(id)) return;

      setState(() {
        _pendingAcknowledgments.remove(id);
        _storedEvents.removeWhere((event) => event.id == id);
      });

      _showMessage('Hardware event $id acknowledged.');
      return;
    }

    if (response == 'EVENT_ACK_FAILED' || response == 'COMMAND_FAILED') {
      final id = parts.length >= 2 ? int.tryParse(parts[1].trim()) : null;

      setState(() {
        if (id != null) {
          _pendingAcknowledgments.remove(id);
        } else {
          _pendingAcknowledgments.clear();
        }
      });

      _showMessage(
        id == null
            ? 'The base station rejected the acknowledgment.'
            : 'Could not acknowledge event $id. The event was retained.',
        isError: true,
      );
    }
  }

  void _acknowledge(StoredHardwareEvent event) {
    if (_pendingAcknowledgments.contains(event.id)) return;

    if (!_hardware.isConnected) {
      _showMessage('Base station is not connected.', isError: true);
      return;
    }

    setState(() => _pendingAcknowledgments.add(event.id));
    _hardware.acknowledgeStoredEvent(event.id);
  }

  void _showMessage(String message, {bool isError = false}) {
    if (!mounted) return;

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: isError ? Colors.red.shade700 : null,
        ),
      );
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
        return Icons.outbound;
      case LogEventType.battery:
        return Icons.battery_alert;
    }
  }

  @override
  void dispose() {
    _eventSubscription?.cancel();
    _syncSubscription?.cancel();
    _ackSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final logs = ref.watch(notificationProvider);
    final sorted = [...logs]
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));

    final hardwareItems = _storedEvents.map((event) {
      final pending = _pendingAcknowledgments.contains(event.id);

      return ListTile(
        key: ValueKey('hardware-event-${event.id}'),
        leading: const Icon(Icons.sensors),
        title: Text('${event.animalId} ${event.type}'),
        subtitle: Text(event.data),
        trailing: IconButton(
          tooltip: 'Acknowledge hardware event',
          onPressed: pending ? null : () => _acknowledge(event),
          icon: pending
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.done),
        ),
      );
    });

    final noContent = sorted.isEmpty && _storedEvents.isEmpty;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Alerts'),
        actions: [
          IconButton(
            tooltip: 'Sync hardware events',
            onPressed: _syncing ? null : _startSync,
            icon: _syncing
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.sync),
          ),
        ],
      ),
      body: noContent
          ? Center(
              child: Text(
                _syncing ? 'Syncing hardware events…' : 'No alerts yet',
              ),
            )
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

import 'dart:async';

import 'package:data_table_2/data_table_2.dart';
import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../database/database_helper.dart';
import '../models/gps_data.dart';
import '../services/livestock_websocket_service.dart';
import 'common_screen.dart';
import 'location_screen.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  // ---------------------------------------------------------------------------
  // DATA
  // ---------------------------------------------------------------------------

  List<Map<String, Object?>> records = [];

  String selectedFilter = "Present Data";

  // ---------------------------------------------------------------------------
  // WEBSOCKET
  // ---------------------------------------------------------------------------

  final LivestockWebSocketService esp = LivestockWebSocketService();

  StreamSubscription<GpsData>? _animalSubscription;
  StreamSubscription<EspConnectionState>? _stateSubscription;
  StreamSubscription<String>? _ackSubscription;

  bool _espConnected = false;
  bool _requestingLiveData = false;

  // ---------------------------------------------------------------------------
  // "LAST UPDATED" TICKER
  // ---------------------------------------------------------------------------
  // We store a local DateTime per animal (keyed by Animal_ID) separately from
  // the row map, since it's UI-only bookkeeping, not part of the animal's
  // reported data. A periodic timer rebuilds the table so the "Xs ago" text
  // stays live without needing a new packet to arrive.

  final Map<String, DateTime> _lastUpdated = {};
  Timer? _tickTimer;

  // ---------------------------------------------------------------------------
  // INITIALIZATION
  // ---------------------------------------------------------------------------

  @override
  void initState() {
    super.initState();

    _espConnected = esp.isConnected;

    // Listen for ESP connection changes.
    _stateSubscription = esp.stateStream.listen((state) {
      if (!mounted) return;

      setState(() {
        _espConnected = state == EspConnectionState.connected;
      });
    });

    // Listen for ACK messages.
    _ackSubscription = esp.ackStream.listen((message) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Collar ACK: $message'),
          duration: const Duration(seconds: 3),
        ),
      );
    });

    // Listen for live livestock data from ESP8266.
    _animalSubscription = esp.animalStream.listen((animal) {
      if (!mounted) return;

      // Only update the table when Present Data is selected.
      if (selectedFilter != "Present Data") {
        return;
      }

      _updateLiveAnimal(animal);
    });

    // Rebuild every few seconds so "last updated Xs ago" stays fresh while
    // viewing live data. Cheap: only triggers a rebuild, no I/O.
    _tickTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted) return;
      if (selectedFilter != "Present Data") return;
      setState(() {});
    });

    // Load initial data.
    loadData();
  }

  // ---------------------------------------------------------------------------
  // LIVE ANIMAL UPDATE
  // ---------------------------------------------------------------------------

  void _updateLiveAnimal(GpsData animal) {
    final animalId = animal.deviceId;

    final index = records.indexWhere(
      (row) => row["Animal_ID"]?.toString() == animalId,
    );

    final liveRecord = <String, Object?>{
      "Animal_ID": animal.deviceId,
      "Latitude": animal.latitude,
      "Longitude": animal.longitude,
      "Altitude": animal.altitude,
      "Satellites": animal.satellites,
      "Speed": animal.speed,
      "Moving": animal.moving,
      "Geofence_Status": "-",
      "Timestamp": animal.timestamp,
      "Battery": animal.battery,
      "Rssi": animal.rssi,
      "Snr": animal.snr,
    };

    setState(() {
      _lastUpdated[animalId] = DateTime.now();

      if (index >= 0) {
        // Update existing animal.
        records[index] = liveRecord;
      } else {
        // Add new animal.
        records.add(liveRecord);
      }
    });
  }

  // ---------------------------------------------------------------------------
  // REQUEST LIVE DATA FROM ESP8266
  // ---------------------------------------------------------------------------

  Future<void> _requestLiveAnimals() async {
    if (_requestingLiveData) {
      return;
    }

    _requestingLiveData = true;

    try {
      // If WebSocket is not connected, try to connect.
      if (!esp.isConnected) {
        debugPrint('Dashboard: Connecting to ESP8266...');

        await esp.connect();
      }

      if (!esp.isConnected) {
        debugPrint(
          'Dashboard: ESP8266 is not connected. '
          'Cannot request animal data.',
        );

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'ESP8266 is not connected. '
                'Connect to the base station Wi-Fi first.',
              ),
            ),
          );
        }

        return;
      }

      debugPrint('Dashboard: Requesting GET_ANIMALS');

      esp.send('GET_ANIMALS');
    } finally {
      _requestingLiveData = false;
    }
  }

  // ---------------------------------------------------------------------------
  // LOAD DATA
  // ---------------------------------------------------------------------------

  Future<void> loadData() async {
    if (selectedFilter == "Present Data") {
      // Present Data now comes from ESP8266/WebSocket.
      records.clear();
      _lastUpdated.clear();

      if (mounted) {
        setState(() {});
      }

      await _requestLiveAnimals();

      return;
    }

    // -------------------------------------------------------------------------
    // HISTORICAL DATA STILL COMES FROM DATABASE
    // -------------------------------------------------------------------------

    List<Map<String, Object?>> newRecords;

    switch (selectedFilter) {
      case "Last 15 Days":
        newRecords = await DatabaseHelper.instance.getDashboardLast15Days();
        break;

      case "Last 30 Days":
        newRecords = await DatabaseHelper.instance.getDashboardLast30Days();
        break;

      case "All Data":
        newRecords = await DatabaseHelper.instance.getDashboardHistory();
        break;

      default:
        newRecords = [];
    }

    if (!mounted) return;

    setState(() {
      records = newRecords;
    });
  }

  // ---------------------------------------------------------------------------
  // FILTER CHANGE
  // ---------------------------------------------------------------------------

  Future<void> _changeFilter(String value) async {
    if (value == selectedFilter) {
      return;
    }

    setState(() {
      selectedFilter = value;
      records = [];
    });

    await loadData();
  }

  // ---------------------------------------------------------------------------
  // LOCATION (STATIC / HISTORICAL VIEW)
  // ---------------------------------------------------------------------------

  void _openLocation(Map<String, Object?> row) {
    final latitude = row["Latitude"];
    final longitude = row["Longitude"];

    if (latitude == null || longitude == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Location data is not available.')),
      );

      return;
    }

    final latitudeValue = (latitude as num).toDouble();
    final longitudeValue = (longitude as num).toDouble();

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => LocationScreen(
          animalId: row["Animal_ID"].toString(),
          latitude: latitudeValue,
          longitude: longitudeValue,
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // LIVE LOCATION VIEW
  // ---------------------------------------------------------------------------
  // NOTE: This reuses LocationScreen with an `isLive: true` flag rather than
  // inventing a call into CommonScreen/MapScreen, since this file doesn't
  // have visibility into those screens' constructors. If you already have a
  // dedicated live map screen, swap the import/class name below and pass the
  // same animalId/latitude/longitude — the calling logic doesn't change.
  // Add `final bool isLive;` (default false) to LocationScreen so it knows
  // to, e.g., keep listening to esp.animalStream for that animalId instead
  // of showing a single static point.

  void _openLiveLocation(Map<String, Object?> row) {
    if (selectedFilter != "Present Data") {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Live view is only available when Present Data is selected.'),
        ),
      );
      return;
    }

    final latitude = row["Latitude"];
    final longitude = row["Longitude"];

    if (latitude == null || longitude == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Live location is not available yet.')),
      );

      return;
    }

    final latitudeValue = (latitude as num).toDouble();
    final longitudeValue = (longitude as num).toDouble();

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CommonScreen(
          targetAnimalId: row["Animal_ID"]?.toString(),
          initialCenter: LatLng(latitudeValue, longitudeValue),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // FORMAT TIMESTAMP
  // ---------------------------------------------------------------------------

  String _formatTimestamp(Object? value) {
    if (value == null) {
      return "-";
    }

    final text = value.toString();

    if (text.isEmpty) {
      return "-";
    }

    try {
      final parsed = DateTime.parse(text);

      final local = parsed.toLocal();

      final year = local.year.toString().padLeft(4, '0');
      final month = local.month.toString().padLeft(2, '0');
      final day = local.day.toString().padLeft(2, '0');
      final hour = local.hour.toString().padLeft(2, '0');
      final minute = local.minute.toString().padLeft(2, '0');
      final second = local.second.toString().padLeft(2, '0');

      return '$year-$month-$day $hour:$minute:$second';
    } catch (_) {
      // Some historical records may not be ISO timestamps.
      return text;
    }
  }

  // ---------------------------------------------------------------------------
  // FORMAT BATTERY
  // ---------------------------------------------------------------------------

  String _formatBattery(Object? value) {
    if (value == null) {
      return "-";
    }

    if (value is num) {
      return '${value.toStringAsFixed(2)} V';
    }

    return value.toString();
  }

  // ---------------------------------------------------------------------------
  // FORMAT SPEED
  // ---------------------------------------------------------------------------

  String _formatSpeed(Object? value) {
    if (value == null) {
      return "-";
    }

    if (value is num) {
      return '${value.toStringAsFixed(1)} km/h';
    }

    return value.toString();
  }

  // ---------------------------------------------------------------------------
  // FORMAT RSSI / SNR (SIGNAL QUALITY)
  // ---------------------------------------------------------------------------

  String _formatRssi(Object? value) {
    if (value == null) {
      return "-";
    }

    if (value is num) {
      return '${value.toStringAsFixed(0)} dBm';
    }

    return value.toString();
  }

  // ---------------------------------------------------------------------------
  // MOVEMENT HELPERS
  // ---------------------------------------------------------------------------

  bool _isMoving(Object? value) {
    if (value == null) return false;
    if (value is bool) return value;
    if (value is num) return value != 0;

    final text = value.toString().toLowerCase();
    return text == '1' || text == 'true' || text == 'moving';
  }

  Widget _buildMovementChip(Object? value) {
    final moving = _isMoving(value);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: moving
            ? Colors.green.withValues(alpha: 0.15)
            : Colors.grey.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        moving ? "MOVING" : "STATIONARY",
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: moving ? Colors.green[800] : Colors.grey[700],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // "LAST UPDATED Xs AGO" HELPER
  // ---------------------------------------------------------------------------

  String _lastUpdatedText(String animalId) {
    final updated = _lastUpdated[animalId];

    if (updated == null) {
      return "-";
    }

    final diff = DateTime.now().difference(updated);

    if (diff.inSeconds < 5) {
      return "just now";
    } else if (diff.inSeconds < 60) {
      return "${diff.inSeconds}s ago";
    } else if (diff.inMinutes < 60) {
      return "${diff.inMinutes}m ago";
    } else {
      return "${diff.inHours}h ago";
    }
  }

  // ---------------------------------------------------------------------------
  // ESP STATUS
  // ---------------------------------------------------------------------------

  Widget _buildConnectionStatus() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.circle,
          size: 10,
          color: _espConnected ? Colors.green : Colors.red,
        ),
        const SizedBox(width: 6),
        Text(
          _espConnected ? "Base Station Connected" : "Base Station Offline",
          style: TextStyle(
            fontSize: 12,
            color: _espConnected ? Colors.green : Colors.red,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // EMPTY STATE
  // ---------------------------------------------------------------------------

  Widget _buildEmptyState() {
    if (selectedFilter == "Present Data" && !_espConnected) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.wifi_off, size: 50, color: Colors.grey),
            SizedBox(height: 12),
            Text(
              "Base station is not connected",
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            SizedBox(height: 6),
            Text(
              "Connect to the ESP8266 Wi-Fi and try again.",
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }

    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.pets, size: 50, color: Colors.grey),
          SizedBox(height: 12),
          Text(
            "No livestock data available",
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // DISPOSE
  // ---------------------------------------------------------------------------

  @override
  void dispose() {
    _animalSubscription?.cancel();
    _stateSubscription?.cancel();
    _ackSubscription?.cancel();
    _tickTimer?.cancel();

    // IMPORTANT:
    // Do not dispose the singleton WebSocket service here.
    // Other screens use the same service.
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // COLUMNS (LIVE VS HISTORICAL)
  // ---------------------------------------------------------------------------

  bool get _isLiveView => selectedFilter == "Present Data";

  Widget _buildStatusChip(dynamic status) {
    final statusStr = status?.toString().toUpperCase() ?? "SAFE";
    final isBreached = statusStr == "BREACHED";

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: isBreached ? Colors.red[100] : Colors.green[100],
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        isBreached ? "BREACHED" : "SAFE",
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.bold,
          color: isBreached ? Colors.red[900] : Colors.green[900],
        ),
      ),
    );
  }

  List<DataColumn> _buildColumns() {
    if (_isLiveView) {
      return const [
        DataColumn2(label: Text("ID"), size: ColumnSize.S, fixedWidth: 80),
        DataColumn2(label: Text("Location"), size: ColumnSize.M, fixedWidth: 150),
        DataColumn2(label: Text("Status"), size: ColumnSize.S, fixedWidth: 100),
        DataColumn2(label: Text("Movement"), size: ColumnSize.M, fixedWidth: 140),
        DataColumn2(label: Text("Speed"), size: ColumnSize.S, fixedWidth: 90),
        DataColumn2(label: Text("Date"), size: ColumnSize.M, fixedWidth: 160),
        DataColumn2(label: Text("Battery"), size: ColumnSize.S, fixedWidth: 90),
        DataColumn2(label: Text("RSSI"), size: ColumnSize.S, fixedWidth: 80),
        DataColumn2(label: Text("Updated"), size: ColumnSize.S, fixedWidth: 90),
      ];
    }

    return const [
      DataColumn2(label: Text("ID"), size: ColumnSize.S, fixedWidth: 80),
      DataColumn2(label: Text("Location"), size: ColumnSize.M, fixedWidth: 120),
      DataColumn2(label: Text("Status"), size: ColumnSize.S, fixedWidth: 110),
      DataColumn2(label: Text("Date"), size: ColumnSize.M, fixedWidth: 160),
      DataColumn2(label: Text("Battery"), size: ColumnSize.S, fixedWidth: 90),
    ];
  }

  List<DataRow> _buildRows() {
    return records.map((row) {
      final animalId = row["Animal_ID"]?.toString() ?? "-";

      if (_isLiveView) {
        final moving = _isMoving(row["Moving"]);

        return DataRow(
          // Subtle highlight while the animal is moving.
          color: moving
              ? WidgetStateProperty.all(Colors.green.withValues(alpha: 0.05))
              : null,
          cells: [
            DataCell(Text(animalId)),
            DataCell(
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextButton(
                    onPressed: () => _openLocation(row),
                    child: const Text("View"),
                  ),
                  TextButton(
                    onPressed: () => _openLiveLocation(row),
                    child: const Text("Live"),
                  ),
                ],
              ),
            ),
            DataCell(_buildStatusChip(row["Geofence_Status"])),
            DataCell(_buildMovementChip(row["Moving"])),
            DataCell(Text(_formatSpeed(row["Speed"]))),
            DataCell(Text(_formatTimestamp(row["Timestamp"]))),
            DataCell(Text(_formatBattery(row["Battery"]))),
            DataCell(Text(_formatRssi(row["Rssi"]))),
            DataCell(Text(_lastUpdatedText(animalId))),
          ],
        );
      }

      return DataRow(
        cells: [
          DataCell(Text(animalId)),
          DataCell(
            TextButton(
              onPressed: () => _openLocation(row),
              child: const Text("View"),
            ),
          ),
          DataCell(_buildStatusChip(row["Geofence_Status"])),
          DataCell(Text(_formatTimestamp(row["Timestamp"]))),
          DataCell(Text(_formatBattery(row["Battery"]))),
        ],
      );
    }).toList();
  }

  // ---------------------------------------------------------------------------
  // BUILD
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Dashboard"),
        actions: [
          if (selectedFilter == "Present Data")
            IconButton(
              tooltip: "Refresh livestock data",
              onPressed: _requestLiveAnimals,
              icon: const Icon(Icons.refresh),
            ),
        ],
      ),

      body: Padding(
        padding: const EdgeInsets.all(16),

        child: Column(
          children: [
            // -----------------------------------------------------------------
            // HEADER
            // -----------------------------------------------------------------
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  "Livestock History",
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                ),

                PopupMenuButton<String>(
                  onSelected: _changeFilter,

                  itemBuilder: (context) => [
                    const PopupMenuItem(
                      value: "Present Data",
                      child: Text("Present Data"),
                    ),

                    const PopupMenuItem(
                      value: "Last 15 Days",
                      child: Text("Last 15 Days"),
                    ),

                    const PopupMenuItem(
                      value: "Last 30 Days",
                      child: Text("Last 30 Days"),
                    ),

                    const PopupMenuItem(
                      value: "All Data",
                      child: Text("All Data"),
                    ),
                  ],

                  child: Row(
                    children: [
                      Text(selectedFilter),
                      const Icon(Icons.arrow_drop_down),
                    ],
                  ),
                ),
              ],
            ),

            const SizedBox(height: 8),

            // -----------------------------------------------------------------
            // CONNECTION STATUS
            // -----------------------------------------------------------------
            Align(
              alignment: Alignment.centerLeft,
              child: _buildConnectionStatus(),
            ),

            const SizedBox(height: 20),

            // -----------------------------------------------------------------
            // TABLE
            // -----------------------------------------------------------------
            Expanded(
              child: records.isEmpty
                  ? _buildEmptyState()
                  : SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: SizedBox(
                        width: _isLiveView ? 1040 : 600,
                        child: DataTable2(
                          fixedTopRows: 1,
                          minWidth: _isLiveView ? 1040 : 600,
                          columnSpacing: 12,
                          horizontalMargin: 12,
                          columns: _buildColumns(),
                          rows: _buildRows(),
                        ),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

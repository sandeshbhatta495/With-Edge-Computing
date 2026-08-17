import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_location_marker/flutter_map_location_marker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../controllers/map_state_controller.dart';
import '../database/database_helper.dart';
import '../geofence/geofence.dart';
import '../geofence/map_layers.dart';
import '../models/download_progress.dart';
import '../models/gps_data.dart';
import '../providers/notification_provider.dart';
import '../screens/alerts_screen.dart';
import '../services/connectivity_service.dart';
import '../services/location_service.dart';
import '../services/map_download_service.dart';
import '../services/tile_cache_service.dart';
import '../services/wifi_service.dart';
import '../services/livestock_websocket_service.dart';
import '../widgets/app_drawer.dart';
import '../widgets/download_progress_dialog.dart';
import '../widgets/geofence_panel.dart';

class OnlineMapScreen extends ConsumerStatefulWidget {
  final LatLng? initialCenter;
  final String? targetAnimalId;

  const OnlineMapScreen({
    super.key,
    this.initialCenter,
    this.targetAnimalId,
  });

  @override
  ConsumerState<OnlineMapScreen> createState() => _OnlineMapScreenState();
}

class _OnlineMapScreenState extends ConsumerState<OnlineMapScreen> {
  final MapController mapController = MapController();
  bool downloadMode = false;
  final LocationService locationService = LocationService();

  StreamSubscription<Position>? positionStream;

  final MapStateController mapState = MapStateController();

  String? tileDirectory;

  bool hasInternet = true;

  final ConnectivityService connectivityService = ConnectivityService();
  final MapDownloadService downloader = MapDownloadService();

  final ValueNotifier<DownloadProgress?> progressNotifier =
      ValueNotifier<DownloadProgress?>(null);

  // ---------------------------------------------------------------------------
  // LIVESTOCK (LIVE, VIA WEBSOCKET)
  // ---------------------------------------------------------------------------

  Map<String, LatLng> livestockLocations = {};
  Map<String, GpsData> liveAnimals = {};

  final LivestockWebSocketService esp = LivestockWebSocketService();
  bool _espConnected = false;

  StreamSubscription<GpsData>? _animalSubscription;
  StreamSubscription<EspConnectionState>? _stateSubscription;

  // ---------------------------------------------------------------------------
  // WIFI / ROBOT (unrelated to livestock markers — left as-is)
  // ---------------------------------------------------------------------------

  final WifiService wifi = WifiService();

  bool robotConnected = false;
  bool ledOn = false;

  final GeofenceController geofence = GeofenceController();

  Map<String, bool> lastGeofenceStatus = {};
  Map<String, int> lastBattery = {};

  // Number of unread notifications.
  int unreadAlerts = 0;

  // ---------------------------------------------------------------------------
  // MAP LOCATION
  // ---------------------------------------------------------------------------

  void recenterToMyLocation() {
    final currentLocation = mapState.currentLocation;

    if (currentLocation == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Current location is not available yet.')),
      );
      return;
    }

    mapController.move(currentLocation, mapController.camera.zoom);
  }

  // ---------------------------------------------------------------------------
  // INITIALIZATION
  // ---------------------------------------------------------------------------

  @override
  void initState() {
    super.initState();

    loadTileDirectory();
    loadConnectivity();
    connectWifi();

    _espConnected = esp.isConnected;
    esp.connect();

    // Live connection indicator.
    _stateSubscription = esp.stateStream.listen((state) {
      if (!mounted) return;

      setState(() {
        _espConnected = state == EspConnectionState.connected;
      });
    });

    // Live markers — replaces the old 2-second database poll. Each packet
    // updates (or adds) that animal's marker immediately.
    _animalSubscription = esp.animalStream.listen((animal) {
      if (!mounted) return;

      setState(() {
        liveAnimals[animal.deviceId] = animal;
        livestockLocations[animal.deviceId] = LatLng(
          animal.latitude,
          animal.longitude,
        );
      });

      _evaluateGeofenceBreach(animal);
    });

    listenToLocation();

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await geofence.loadGeofence();

      if (!mounted) return;

      if (widget.initialCenter != null) {
        mapController.move(widget.initialCenter!, 17.0);
      }

      _evaluateAllAnimalsGeofence();
      setState(() {});
    });

    connectivityService.connectivityStream.listen((connected) {
      if (!mounted) return;

      setState(() {
        hasInternet = connected;
      });

      debugPrint('WAN Internet Available: $connected');
    });
  }

  // ---------------------------------------------------------------------------
  // WIFI / ROBOT
  // ---------------------------------------------------------------------------

  Future<void> connectWifi() async {
    final connected = await wifi.connect();

    if (!mounted) return;

    setState(() {
      robotConnected = connected;
    });
  }

  // ---------------------------------------------------------------------------
  // CONNECTIVITY
  // ---------------------------------------------------------------------------

  Future<void> loadConnectivity() async {
    hasInternet = await connectivityService.isConnected();

    if (mounted) {
      setState(() {});
    }
  }

  // ---------------------------------------------------------------------------
  // TILE DIRECTORY
  // ---------------------------------------------------------------------------

  // ---------------------------------------------------------------------------
  // GEOFENCE BREACH EVALUATION & ALERT POPUP
  // ---------------------------------------------------------------------------

  Set<String> breachedAnimals = {};

  void _evaluateGeofenceBreach(GpsData animal) {
    final polygon = geofence.points.isNotEmpty ? geofence.points : geofence.savedPoints;
    if (polygon.length < 3) return;

    final point = LatLng(animal.latitude, animal.longitude);
    final isInside = geofence.containsPoint(point);
    final statusString = isInside ? "Safe" : "Breached";

    // Update SQLite database so Dashboard table reflects status
    DatabaseHelper.instance.updateDashboard(
      animalId: animal.deviceId,
      latitude: animal.latitude,
      longitude: animal.longitude,
      status: statusString,
      battery: animal.battery,
      timestamp: animal.timestamp.toString(),
    );

    if (!isInside) {
      if (!breachedAnimals.contains(animal.deviceId)) {
        breachedAnimals.add(animal.deviceId);

        // 1. Log notification & trigger local push
        ref.read(notificationProvider.notifier).log(
          LogEventType.boundaryBreached,
          'GEOFENCE ALERT: Collar ${animal.deviceId} is OUTSIDE the boundary!',
        );

        // 2. Show alert popup modal overlay
        _showBreachDialog(animal.deviceId, point);
      }
    } else {
      breachedAnimals.remove(animal.deviceId);
    }
  }

  void _evaluateAllAnimalsGeofence() {
    for (final animal in liveAnimals.values) {
      _evaluateGeofenceBreach(animal);
    }
  }

  void _showBreachDialog(String animalId, LatLng location) {
    if (!mounted) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          backgroundColor: Colors.red[50],
          title: Row(
            children: const [
              Icon(Icons.warning_amber_rounded, color: Colors.red, size: 32),
              SizedBox(width: 10),
              Text(
                "GEOFENCE BREACH!",
                style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                "Collar $animalId has crossed OUTSIDE the designated geofence boundary!",
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 12),
              Text("Latitude: ${location.latitude.toStringAsFixed(5)}"),
              Text("Longitude: ${location.longitude.toStringAsFixed(5)}"),
            ],
          ),
          actions: [
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
              ),
              onPressed: () {
                Navigator.of(context).pop();
                mapController.move(location, 17.0);
              },
              icon: const Icon(Icons.my_location),
              label: const Text("Locate on Map"),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text("Dismiss"),
            ),
          ],
        );
      },
    );
  }

  Future<void> loadTileDirectory() async {
    tileDirectory = await TileCacheService.getTileDirectoryPath();

    if (mounted) {
      setState(() {});
    }

    debugPrint('Tile Directory: $tileDirectory');
  }

  // ---------------------------------------------------------------------------
  // GPS LOCATION
  // ---------------------------------------------------------------------------

  void listenToLocation() {
    positionStream = locationService.getPositionStream().listen((position) {
      final newLocation = LatLng(position.latitude, position.longitude);

      mapState.updateCurrentLocation(newLocation);

      if (mounted) {
        setState(() {});
      }
    });
  }

  // ---------------------------------------------------------------------------
  // DISPOSE
  // ---------------------------------------------------------------------------

  @override
  void dispose() {
    positionStream?.cancel();
    _animalSubscription?.cancel();
    _stateSubscription?.cancel();

    progressNotifier.dispose();
    wifi.dispose();

    // IMPORTANT:
    // Do not dispose the singleton LivestockWebSocketService here.
    // Other screens use the same service.
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // OPEN ALERTS
  // ---------------------------------------------------------------------------

  Future<void> openAlerts() async {
    setState(() {
      unreadAlerts = 0;
    });

    await Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const AlertsScreen()),
    );
  }

  // ---------------------------------------------------------------------------
  // NOTIFICATION BUTTON
  // ---------------------------------------------------------------------------

  Widget buildNotificationButton() {
    return IconButton(
      tooltip: 'Notifications',
      icon: Stack(
        clipBehavior: Clip.none,
        children: [
          const Icon(Icons.notifications),

          if (unreadAlerts > 0)
            Positioned(
              right: -4,
              top: -4,
              child: Container(
                padding: const EdgeInsets.all(4),
                decoration: const BoxDecoration(
                  color: Colors.red,
                  shape: BoxShape.circle,
                ),
                constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
                child: Text(
                  unreadAlerts > 9 ? '9+' : '$unreadAlerts',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
        ],
      ),
      onPressed: openAlerts,
    );
  }

  // ---------------------------------------------------------------------------
  // BASE STATION CONNECTION BADGE (OVERLAID ON MAP)
  // ---------------------------------------------------------------------------

  Widget _buildConnectionBadge() {
    return Positioned(
      top: 12,
      left: 12,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          boxShadow: const [BoxShadow(blurRadius: 4, color: Colors.black26)],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.circle,
              size: 10,
              color: _espConnected ? Colors.green : Colors.red,
            ),
            const SizedBox(width: 6),
            Text(
              _espConnected ? 'Base Station Connected' : 'Base Station Offline',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: _espConnected ? Colors.green[800] : Colors.red[800],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // BUILD
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    // Listen for new notification events.
    //
    // Because this screen is already a ConsumerStatefulWidget,
    // we do not need another Consumer widget around the Scaffold.
    ref.listen<List<LogEvent>>(notificationProvider, (previous, next) {
      if (!mounted) return;

      final previousLength = previous?.length ?? 0;
      final sessionStart = ref
          .read(notificationProvider.notifier)
          .sessionStartCount;

      if (next.length > previousLength && previousLength >= sessionStart) {
        final latestEvent = next.last;

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(latestEvent.message),
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 3),
          ),
        );

        setState(() {
          unreadAlerts++;
        });
      }
    });

    return Scaffold(
      // -----------------------------------------------------------------------
      // APP BAR
      // -----------------------------------------------------------------------
      appBar: AppBar(
        title: const Text('Livestock Tracker'),
        actions: [buildNotificationButton()],
      ),
      // -----------------------------------------------------------------------
      // DRAWER
      // -----------------------------------------------------------------------
      drawer: AppDrawer(
        onGeoFenceTap: () async {
          await geofence.startEditing(mapController.camera.center);

          if (!mounted) return;

          setState(() {});
        },
      ),

      // -----------------------------------------------------------------------
      // FLOATING ACTION BUTTONS
      // -----------------------------------------------------------------------
      floatingActionButton: AnimatedPadding(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,

        padding: EdgeInsets.only(bottom: geofence.showPanel ? 85 : 0),

        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // -----------------------------------------------------------------
            // CURRENT LOCATION BUTTON
            // -----------------------------------------------------------------
            FloatingActionButton(
              heroTag: 'locateMe',
              tooltip: 'Show my location',
              onPressed: recenterToMyLocation,
              child: const Icon(Icons.my_location),
            ),

            // -----------------------------------------------------------------
            // SELECT MAP DOWNLOAD AREA
            // -----------------------------------------------------------------
            if (hasInternet) ...[
              const SizedBox(height: 12),

              FloatingActionButton(
                heroTag: 'selectBounds',
                tooltip: mapState.selectedBounds == null
                    ? 'Select offline area'
                    : 'Selection in progress',
                onPressed: mapState.selectedBounds != null
                    ? null
                    : () {
                        final center = mapController.camera.center;
                        const double offset = 0.01;
                        downloadMode = true;

                        mapState.updateSelectedBounds(
                          LatLngBounds(
                            LatLng(
                              center.latitude - offset,
                              center.longitude - offset,
                            ),
                            LatLng(
                              center.latitude + offset,
                              center.longitude + offset,
                            ),
                          ),
                        );

                        setState(() {});
                      },

                child: const Icon(Icons.crop_square),
              ),
            ],

            if (downloadMode && mapState.selectedBounds != null) ...[
              const SizedBox(height: 12),
              FloatingActionButton(
                heroTag: 'cancelBounds',
                tooltip: 'Cancel selection',
                backgroundColor: Colors.red,
                onPressed: () {
                  mapState.clearSelectedBounds();
                  downloadMode = false;
                  setState(() {});
                },
                child: const Icon(Icons.close),
              ),
            ],
          ],
        ),
      ),

      // -----------------------------------------------------------------------
      // MAP DOWNLOAD BUTTON
      // -----------------------------------------------------------------------
      bottomNavigationBar: (downloadMode && mapState.selectedBounds != null)
          ? Padding(
              padding: const EdgeInsets.all(12),

              child: ElevatedButton(
                onPressed: () async {
                  showDialog(
                    context: context,
                    barrierDismissible: false,

                    builder: (_) => DownloadProgressDialog(
                      progressNotifier: progressNotifier,

                      onCancel: () {
                        downloader.cancelDownload();
                      },
                    ),
                  );

                  await downloader.downloadArea(
                    bounds: mapState.selectedBounds!,
                    minZoom: 13,
                    maxZoom: 19,
                    onProgress: (progress) {
                      progressNotifier.value = progress;
                    },
                  );

                  if (!context.mounted) return;

                  // Close the download progress dialog.
                  Navigator.of(context).pop();

                  if (downloader.isCancelled) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Download cancelled')),
                    );
                  } else {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                          'Offline map downloaded successfully up to zoom level 19',
                        ),
                      ),
                    );

                    ref
                        .read(notificationProvider.notifier)
                        .log(
                          LogEventType.mapDownloaded,
                          'Offline map downloaded (zoom up to 19)',
                        );
                  }

                  mapState.clearSelectedBounds();
                  downloadMode = false;
                  setState(() {});
                },
                child: const Text('Download Area'),
              ),
            )
          : null,

      // -----------------------------------------------------------------------
      // BODY
      // -----------------------------------------------------------------------
      body: Stack(
        children: [
          // -------------------------------------------------------------------
          // MAP
          // -------------------------------------------------------------------
          FlutterMap(
            mapController: mapController,
            options: MapOptions(
              initialCenter: widget.initialCenter ??
                  mapState.currentLocation ?? const LatLng(27.7172, 85.3240),
              initialZoom: widget.initialCenter != null ? 17.0 : 15.0,
              minZoom: hasInternet ? 1.0 : 15.0,
              maxZoom: hasInternet ? 21.0 : 19.0,
            ),

            children: [
              // ---------------------------------------------------------------
              // ONLINE MAP
              // ---------------------------------------------------------------
              if (hasInternet)
                TileLayer(
                  urlTemplate:
                      'https://tile.openstreetmap.org/'
                      '{z}/{x}/{y}.png',

                  userAgentPackageName: 'com.example.livestock_tracker',
                  maxNativeZoom: 19,
                  maxZoom: 19,
                )
              // ---------------------------------------------------------------
              // OFFLINE MAP
              // ---------------------------------------------------------------
              else if (tileDirectory != null)
                TileLayer(
                  tileProvider: FileTileProvider(),

                  urlTemplate: '$tileDirectory/{z}/{x}/{y}.png',
                  maxZoom: 19,
                  maxNativeZoom: 19,
                ),

              // ---------------------------------------------------------------
              // CURRENT LOCATION
              // ---------------------------------------------------------------
              CurrentLocationLayer(
                alignPositionOnUpdate: AlignOnUpdate.never,

                alignDirectionOnUpdate: AlignOnUpdate.never,

                style: LocationMarkerStyle(
                  marker: const DefaultLocationMarker(color: Colors.blue),

                  markerSize: const Size(24, 24),

                  headingSectorColor: Colors.blue.withValues(alpha: 0.4),

                  headingSectorRadius: 80,
                ),
              ),

              // ---------------------------------------------------------------
              // GEOFENCE / MAP LAYERS
              // ---------------------------------------------------------------
              MapLayers(
                geofence: geofence,
                currentLocation: mapState.currentLocation,
                selectedBounds: mapState.selectedBounds,
                refresh: () {
                  setState(() {});
                },
                onBoundsChanged: (bounds) {
                  mapState.updateSelectedBounds(bounds);
                  setState(() {});
                },
              ),

              // ---------------------------------------------------------------
              // LIVESTOCK MARKERS (LIVE & BREACH STATUS)
              // ---------------------------------------------------------------
              MarkerLayer(
                markers: liveAnimals.isNotEmpty
                    ? liveAnimals.entries.map((entry) {
                        final animal = entry.value;
                        final isMoving = animal.moving;
                        final isBreached = breachedAnimals.contains(animal.deviceId);
                        return Marker(
                          point: LatLng(animal.latitude, animal.longitude),
                          width: 90,
                          height: 75,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 28,
                                height: 28,
                                decoration: BoxDecoration(
                                  color: isBreached
                                      ? Colors.red
                                      : (isMoving ? Colors.green : Colors.blue),
                                  shape: BoxShape.circle,
                                  border: Border.all(color: Colors.white, width: 3),
                                  boxShadow: const [
                                    BoxShadow(
                                      color: Colors.black38,
                                      blurRadius: 5,
                                      offset: Offset(0, 2),
                                    ),
                                  ],
                                ),
                                child: Icon(
                                  isBreached
                                      ? Icons.warning_amber_rounded
                                      : (isMoving ? Icons.directions_run : Icons.pets),
                                  size: 16,
                                  color: Colors.white,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(10),
                                  boxShadow: const [
                                    BoxShadow(blurRadius: 3, color: Colors.black26),
                                  ],
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      entry.key,
                                      style: const TextStyle(
                                        fontSize: 10,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    if (isBreached) ...[
                                      const SizedBox(width: 3),
                                      Text(
                                        "BREACHED",
                                        style: TextStyle(
                                          fontSize: 8,
                                          fontWeight: FontWeight.w900,
                                          color: Colors.red[800],
                                        ),
                                      ),
                                    ] else if (isMoving) ...[
                                      const SizedBox(width: 3),
                                      Text(
                                        "MOVING",
                                        style: TextStyle(
                                          fontSize: 8,
                                          fontWeight: FontWeight.w900,
                                          color: Colors.green[800],
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ],
                          ),
                        );
                      }).toList()
                    : livestockLocations.entries.map((entry) {
                        return Marker(
                          point: entry.value,
                          width: 60,
                          height: 60,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 22,
                                height: 22,
                                decoration: BoxDecoration(
                                  color: Colors.blue,
                                  shape: BoxShape.circle,
                                  border: Border.all(color: Colors.white, width: 4),
                                  boxShadow: const [
                                    BoxShadow(
                                      color: Colors.black38,
                                      blurRadius: 5,
                                      offset: Offset(0, 2),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 4),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(12),
                                  boxShadow: const [
                                    BoxShadow(blurRadius: 3, color: Colors.black26),
                                  ],
                                ),
                                child: Text(
                                  entry.key,
                                  style: const TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        );
                      }).toList(),
              ),
            ],
          ),

          // -------------------------------------------------------------------
          // BASE STATION CONNECTION BADGE
          // -------------------------------------------------------------------
          _buildConnectionBadge(),

          // -------------------------------------------------------------------
          // GEOFENCE PANEL
          // -------------------------------------------------------------------
          GeofencePanel(
            showGeofencePanel: geofence.showPanel,

            geofence: geofence,

            refresh: () {
              breachedAnimals.clear();
              _evaluateAllAnimalsGeofence();
              setState(() {});
            },
          ),
        ],
      ),
    );
  }
}

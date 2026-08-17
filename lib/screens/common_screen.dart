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
import '../models/gps_data.dart';
import '../providers/notification_provider.dart';
import '../screens/alerts_screen.dart';
import '../services/connectivity_service.dart';
import '../services/location_service.dart';
import '../services/tile_cache_service.dart';
import '../services/livestock_websocket_service.dart';
import '../widgets/app_drawer.dart';
import '../widgets/geofence_panel.dart';

class CommonScreen extends ConsumerStatefulWidget {
  final LatLng? initialCenter;
  final String? targetAnimalId;

  const CommonScreen({
    super.key,
    this.initialCenter,
    this.targetAnimalId,
  });

  @override
  ConsumerState<CommonScreen> createState() => _CommonScreenState();
}

class _CommonScreenState extends ConsumerState<CommonScreen> {
  // ---------------------------------------------------------------------------
  // MAP / LOCATION
  // ---------------------------------------------------------------------------

  final MapController mapController = MapController();
  final LocationService locationService = LocationService();

  StreamSubscription<Position>? positionStream;

  final MapStateController mapState = MapStateController();

  String? tileDirectory;

  bool hasInternet = true;
  bool espConnected = false;

  final ConnectivityService connectivityService = ConnectivityService();

  // ---------------------------------------------------------------------------
  // LIVESTOCK (LIVE, VIA WEBSOCKET)
  // ---------------------------------------------------------------------------

  Map<String, LatLng> livestockLocations = {};
  Map<String, GpsData> liveAnimals = {};

  StreamSubscription<GpsData>? _animalSubscription;
  StreamSubscription<EspConnectionState>? _stateSubscription;

  // ---------------------------------------------------------------------------
  // GEOFENCE
  // ---------------------------------------------------------------------------

  final GeofenceController geofence = GeofenceController();

  // ---------------------------------------------------------------------------
  // NOTIFICATIONS
  // ---------------------------------------------------------------------------

  int unreadAlerts = 0;

  // ---------------------------------------------------------------------------
  // ESP8266 / WEBSOCKET
  // ---------------------------------------------------------------------------
  // NOTE: previously there was a second, unused `websocket` field here
  // pointing at the same singleton as `esp` below — removed, this is the
  // only reference to the service in this screen now.

  final LivestockWebSocketService esp = LivestockWebSocketService();
  bool _espConnected = false;

  // ---------------------------------------------------------------------------
  // RECENTER TO CURRENT LOCATION
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
    loadStoredAnimals();

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
  // CONNECTIVITY
  // ---------------------------------------------------------------------------

  Future<void> loadConnectivity() async {
    hasInternet = await connectivityService.isConnected();

    if (mounted) {
      setState(() {});
    }
  }

  // ---------------------------------------------------------------------------
  // LOAD STORED ANIMAL COLLARS FROM DATABASE
  // ---------------------------------------------------------------------------

  Future<void> loadStoredAnimals() async {
    try {
      final rows = await DatabaseHelper.instance.getDashboard();
      if (!mounted) return;

      setState(() {
        for (final row in rows) {
          final animalId = row["Animal_ID"]?.toString();
          final lat = row["Latitude"];
          final lng = row["Longitude"];
          final battery = row["Battery"];

          if (animalId != null && lat != null && lng != null) {
            final double latitude = (lat as num).toDouble();
            final double longitude = (lng as num).toDouble();

            if (!liveAnimals.containsKey(animalId)) {
              livestockLocations[animalId] = LatLng(latitude, longitude);
              liveAnimals[animalId] = GpsData(
                deviceId: animalId,
                latitude: latitude,
                longitude: longitude,
                altitude: (row["Altitude"] as num?)?.toDouble() ?? 0.0,
                satellites: (row["Satellites"] as num?)?.toInt() ?? 0,
                speed: (row["Speed"] as num?)?.toDouble() ?? 0.0,
                moving: row["Moving"] == 1 || row["Moving"] == true || row["Moving"] == "true",
                timestamp: row["Timestamp"]?.toString() ?? "",
                battery: (battery as num?)?.toDouble() ?? 0.0,
                rssi: (row["Rssi"] as num?)?.toInt() ?? 0,
                snr: (row["Snr"] as num?)?.toDouble() ?? 0.0,
              );
            }
          }
        }
      });
      _evaluateAllAnimalsGeofence();
    } catch (e) {
      debugPrint('Error loading stored animals: $e');
    }
  }

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

  // ---------------------------------------------------------------------------
  // SHOW COLLAR TELEMETRY DETAILS MODAL
  // ---------------------------------------------------------------------------

  void _showCollarDetails(GpsData animal) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return Container(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Icon(
                        animal.moving ? Icons.directions_run : Icons.pets,
                        color: animal.moving ? Colors.green : Colors.blue,
                        size: 28,
                      ),
                      const SizedBox(width: 10),
                      Text(
                        'Collar: ${animal.deviceId}',
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: animal.moving ? Colors.green[100] : Colors.blue[100],
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      animal.moving ? 'MOVING' : 'STATIONARY',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: animal.moving ? Colors.green[900] : Colors.blue[900],
                      ),
                    ),
                  ),
                ],
              ),
              const Divider(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _detailColumn("Latitude", animal.latitude.toStringAsFixed(5)),
                  _detailColumn("Longitude", animal.longitude.toStringAsFixed(5)),
                  _detailColumn("Speed", "${animal.speed.toStringAsFixed(1)} km/h"),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _detailColumn("Battery", "${animal.battery.toStringAsFixed(2)} V"),
                  _detailColumn("Signal (RSSI)", "${animal.rssi} dBm"),
                  _detailColumn("Satellites", "${animal.satellites}"),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _detailColumn(String label, String value) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 11,
            color: Colors.grey,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // TILE DIRECTORY
  // ---------------------------------------------------------------------------

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

    // IMPORTANT:
    // Do not dispose the singleton WebSocket service here.
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
    // -------------------------------------------------------------------------
    // NOTIFICATION LISTENER
    // -------------------------------------------------------------------------

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

    // -------------------------------------------------------------------------
    // MAP ZOOM LIMITS
    // -------------------------------------------------------------------------
    //
    // ONLINE:
    //   Minimum zoom = 1
    //   Maximum zoom = 21
    //
    // OFFLINE:
    //   Minimum zoom = 15
    //   Maximum zoom = 19
    //
    // This prevents the offline map from requesting tiles outside
    // the supported offline tile range.
    // -------------------------------------------------------------------------

    final double minimumZoom = hasInternet ? 1.0 : 15.0;
    final double maximumZoom = hasInternet ? 21.0 : 19.0;

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
      // CURRENT LOCATION BUTTON
      // -----------------------------------------------------------------------
      floatingActionButton: FloatingActionButton(
        heroTag: 'commonLocateMe',
        tooltip: 'Show my location',
        onPressed: recenterToMyLocation,
        child: const Icon(Icons.my_location),
      ),

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
              initialCenter:
                  widget.initialCenter ?? mapState.currentLocation ?? const LatLng(27.7172, 85.3240),

              // Initial zoom remains inside both online/offline ranges.
              initialZoom: widget.initialCenter != null ? 17.0 : 15.0,

              // ONLINE:
              //   1 -> 21
              //
              // OFFLINE:
              //   15 -> 19
              minZoom: minimumZoom,
              maxZoom: maximumZoom,
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

                  // Online map may zoom up to 21.
                  maxZoom: 21,
                )
              // ---------------------------------------------------------------
              // OFFLINE MAP
              // ---------------------------------------------------------------
              else if (tileDirectory != null)
                TileLayer(
                  tileProvider: FileTileProvider(),

                  urlTemplate:
                      '$tileDirectory/'
                      '{z}/{x}/{y}.png',

                  // Offline tiles are limited to 15-19.
                  maxNativeZoom: 19,
                  maxZoom: 19,
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
              // GEOFENCE
              // ---------------------------------------------------------------
              MapLayers(
                geofence: geofence,

                currentLocation: mapState.currentLocation,

                selectedBounds: null,

                refresh: () {
                  setState(() {});
                },

                onBoundsChanged: (_) {},
              ),

              // ---------------------------------------------------------------
              // LIVESTOCK / COLLAR MARKERS (LIVE & STORED)
              // ---------------------------------------------------------------
              MarkerLayer(
                markers: liveAnimals.isNotEmpty
                    ? liveAnimals.entries.map((entry) {
                        final animal = entry.value;
                        final isMoving = animal.moving;
                        return Marker(
                          point: LatLng(animal.latitude, animal.longitude),
                          width: 80,
                          height: 70,
                          child: GestureDetector(
                            onTap: () => _showCollarDetails(animal),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Container(
                                  width: 26,
                                  height: 26,
                                  decoration: BoxDecoration(
                                    color: isMoving ? Colors.green : Colors.blue,
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
                                    isMoving ? Icons.directions_run : Icons.pets,
                                    size: 14,
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
                                      if (isMoving) ...[
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

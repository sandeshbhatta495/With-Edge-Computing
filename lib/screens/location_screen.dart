import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../models/gps_data.dart';
import '../services/livestock_websocket_service.dart';

class LocationScreen extends StatefulWidget {
  final double latitude;
  final double longitude;
  final String animalId;
  final bool isLive;

  const LocationScreen({
    super.key,
    required this.latitude,
    required this.longitude,
    required this.animalId,
    this.isLive = false,
  });

  @override
  State<LocationScreen> createState() => _LocationScreenState();
}

class _LocationScreenState extends State<LocationScreen> {
  late double _latitude;
  late double _longitude;
  bool _isMoving = false;
  double? _speed;
  double? _battery;
  int? _rssi;

  StreamSubscription<GpsData>? _animalSubscription;

  final MapController _mapController = MapController();

  @override
  void initState() {
    super.initState();

    _latitude = widget.latitude;
    _longitude = widget.longitude;

    if (widget.isLive) {
      // Keep listening for updates to this specific animal and move the
      // marker (and map center) as new packets arrive.
      _animalSubscription = LivestockWebSocketService().animalStream.listen((
        animal,
      ) {
        if (!mounted) return;

        if (animal.deviceId != widget.animalId) {
          return;
        }

        setState(() {
          _latitude = animal.latitude;
          _longitude = animal.longitude;
          _isMoving = animal.moving;
          _speed = animal.speed;
          _battery = animal.battery;
          _rssi = animal.rssi;
        });

        _mapController.move(
          LatLng(_latitude, _longitude),
          _mapController.camera.zoom,
        );
      });
    }
  }

  @override
  void dispose() {
    _animalSubscription?.cancel();
    _mapController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final location = LatLng(_latitude, _longitude);

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.animalId),
        actions: [
          if (widget.isLive)
            const Padding(
              padding: EdgeInsets.only(right: 12),
              child: Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.circle, size: 10, color: Colors.green),
                    SizedBox(width: 6),
                    Text(
                      "LIVE",
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: Colors.green,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: location,
              initialZoom: 17,
              maxZoom: 21,
            ),
            children: [
              TileLayer(
                urlTemplate: "https://tile.openstreetmap.org/{z}/{x}/{y}.png",
                userAgentPackageName: "com.example.livestock_tracker",
              ),

              MarkerLayer(
                markers: [
                  Marker(
                    point: location,
                    width: 80,
                    height: 70,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 28,
                          height: 28,
                          decoration: BoxDecoration(
                            color: _isMoving
                                ? Colors.green
                                : (widget.isLive ? Colors.blue : Colors.red),
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
                            _isMoving ? Icons.directions_run : Icons.pets,
                            size: 16,
                            color: Colors.white,
                          ),
                        ),

                        const SizedBox(height: 3),

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
                                widget.animalId,
                                style: const TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              if (_isMoving) ...[
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
                ],
              ),
            ],
          ),
          if (widget.isLive)
            Positioned(
              left: 16,
              right: 16,
              bottom: 24,
              child: Card(
                elevation: 4,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text(
                            "STATUS",
                            style: TextStyle(
                              fontSize: 10,
                              color: Colors.grey,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            _isMoving ? "MOVING" : "STATIONARY",
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                              color: _isMoving ? Colors.green : Colors.blueGrey,
                            ),
                          ),
                        ],
                      ),
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text(
                            "SPEED",
                            style: TextStyle(
                              fontSize: 10,
                              color: Colors.grey,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            _speed != null
                                ? "${_speed!.toStringAsFixed(1)} km/h"
                                : "-",
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text(
                            "BATTERY",
                            style: TextStyle(
                              fontSize: 10,
                              color: Colors.grey,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            _battery != null
                                ? "${_battery!.toStringAsFixed(2)} V"
                                : "-",
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text(
                            "SIGNAL",
                            style: TextStyle(
                              fontSize: 10,
                              color: Colors.grey,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            _rssi != null ? "$_rssi dBm" : "-",
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

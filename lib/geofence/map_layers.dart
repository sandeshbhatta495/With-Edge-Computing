import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_dragmarker/flutter_map_dragmarker.dart';
import 'package:latlong2/latlong.dart';

import 'geofence.dart';

class MapLayers extends StatelessWidget {
  final GeofenceController geofence;
  final LatLng? currentLocation;
  final LatLngBounds? selectedBounds;
  final VoidCallback refresh;
  final ValueChanged<LatLngBounds> onBoundsChanged;

  const MapLayers({
    super.key,
    required this.geofence,
    required this.currentLocation,
    required this.selectedBounds,
    required this.refresh,
    required this.onBoundsChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        if (selectedBounds != null)
          PolygonLayer(
            polygons: [
              Polygon(
                points: [
                  selectedBounds!.northWest,
                  LatLng(selectedBounds!.north, selectedBounds!.east),
                  selectedBounds!.southEast,
                  LatLng(selectedBounds!.south, selectedBounds!.west),
                ],
                color: Colors.blue.withValues(alpha: 0.25),
                borderColor: Colors.blue,
                borderStrokeWidth: 2,
              ),
            ],
          ),
        if (selectedBounds != null)
          DragMarkers(
            markers: [
              DragMarker(
                point: selectedBounds!.northWest,
                size: const Size(40, 40),
                builder: (context, position, isDragging) {
                  return Center(
                    child: Container(
                      width: 22,
                      height: 22,
                      decoration: BoxDecoration(
                        color: Colors.blue,
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 3),
                      ),
                    ),
                  );
                },
                onDragUpdate: (details, newPoint) {
                  onBoundsChanged(
                    LatLngBounds(newPoint, selectedBounds!.southEast),
                  );
                },
              ),
              DragMarker(
                point: LatLng(selectedBounds!.north, selectedBounds!.east),
                size: const Size(40, 40),
                builder: (context, position, isDragging) {
                  return Center(
                    child: Container(
                      width: 22,
                      height: 22,
                      decoration: BoxDecoration(
                        color: Colors.blue,
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 3),
                      ),
                    ),
                  );
                },
                onDragUpdate: (details, newPoint) {
                  onBoundsChanged(
                    LatLngBounds(
                      LatLng(newPoint.latitude, selectedBounds!.west),
                      LatLng(selectedBounds!.south, newPoint.longitude),
                    ),
                  );
                },
              ),
              DragMarker(
                point: selectedBounds!.southEast,
                size: const Size(40, 40),
                builder: (context, position, isDragging) {
                  return Center(
                    child: Container(
                      width: 22,
                      height: 22,
                      decoration: BoxDecoration(
                        color: Colors.blue,
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 3),
                      ),
                    ),
                  );
                },
                onDragUpdate: (details, newPoint) {
                  onBoundsChanged(
                    LatLngBounds(selectedBounds!.northWest, newPoint),
                  );
                },
              ),
              DragMarker(
                point: LatLng(selectedBounds!.south, selectedBounds!.west),
                size: const Size(40, 40),
                builder: (context, position, isDragging) {
                  return Center(
                    child: Container(
                      width: 22,
                      height: 22,
                      decoration: BoxDecoration(
                        color: Colors.blue,
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 3),
                      ),
                    ),
                  );
                },
                onDragUpdate: (details, newPoint) {
                  onBoundsChanged(
                    LatLngBounds(
                      LatLng(selectedBounds!.north, newPoint.longitude),
                      LatLng(newPoint.latitude, selectedBounds!.east),
                    ),
                  );
                },
              ),
            ],
          ),
        PolygonLayer<Object>(
          polygons: geofence.points.length >= 3
              ? [
                  Polygon<Object>(
                    points: geofence.points,
                    color: Colors.green.withValues(alpha: 0.3),
                    borderColor: Colors.green,
                    borderStrokeWidth: 3,
                  ),
                ]
              : [],
        ),
        if (geofence.isEditing)
          DragMarkers(
            markers: geofence.points.asMap().entries.map((entry) {
              final index = entry.key;
              final point = entry.value;

              return DragMarker(
                point: point,
                size: const Size(40, 40),

                builder: (context, position, isDragging) {
                  return Center(
                    child: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: Colors.transparent,
                        shape: BoxShape.circle,
                      ),

                      alignment: Alignment.center,
                      child: Container(
                        width: 22,
                        height: 22,
                        decoration: BoxDecoration(
                          color: Colors.green,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 5),
                        ),
                      ),
                    ),
                  );
                },

                onDragUpdate: (details, newPoint) {
                  geofence.points[index] = newPoint;
                  refresh();
                },
                onDragEnd: (_, _) {
                  geofence.removeVertexIfNeeded(index);
                  geofence.activeInsertedVertex = null;
                  refresh();
                },
              );
            }).toList(),
          ),
        if (geofence.isEditing)
          DragMarkers(
            markers: geofence.getEdgeHandles().map((handle) {
              return DragMarker(
                point: handle.position,

                size: const Size(40, 40),

                builder: (context, position, isDragging) {
                  return Center(
                    child: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: Colors.transparent,
                        shape: BoxShape.circle,
                      ),
                      alignment: Alignment.center,
                      child: Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: Colors.green,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                  );
                },

                onDragStart: (_, _) {
                  geofence.activeInsertedVertex = geofence.insertVertex(
                    handle.edgeIndex,
                  );
                  refresh();
                },

                onDragUpdate: (_, newPoint) {
                  final index = geofence.activeInsertedVertex;
                  if (index != null) {
                    geofence.points[index] = newPoint;
                  }
                  refresh();
                },

                onDragEnd: (_, _) {
                  geofence.activeInsertedVertex = null;
                  refresh();
                },
              );
            }).toList(),
          ),
      ],
    );
  }
}

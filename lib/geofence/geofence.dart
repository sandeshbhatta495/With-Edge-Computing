import 'package:latlong2/latlong.dart';
import '../database/database_helper.dart';
import 'dart:math' as math;

class EdgeHandle {
  final int edgeIndex;
  final LatLng position;

  EdgeHandle({required this.edgeIndex, required this.position});
}

class GeofenceController {
  bool isEditing = false;
  bool showPanel = false;
  List<LatLng> points = [];
  List<LatLng> savedPoints = [];
  int? selectedVertex;
  int? activeInsertedVertex;

  double _calculateDistance(LatLng p1, LatLng p2) {
    final dx = p1.latitude - p2.latitude;
    final dy = p1.longitude - p2.longitude;
    return math.sqrt(dx * dx + dy * dy);
  }

  void removeVertexIfNeeded(int index) {
    if (points.length <= 3) return;

    final previousIndex = (index - 1 + points.length) % points.length;
    final nextIndex = (index + 1) % points.length;

    const threshold = 0.0001;

    final closeToPrevious =
        _calculateDistance(points[index], points[previousIndex]) < threshold;
    final closeToNext =
        _calculateDistance(points[index], points[nextIndex]) < threshold;

    if (closeToPrevious || closeToNext) {
      points.removeAt(index);
    }
  }

  List<EdgeHandle> getEdgeHandles() {
    final handles = <EdgeHandle>[];

    for (int i = 0; i < points.length; i++) {
      final p1 = points[i];
      final p2 = points[(i + 1) % points.length];

      handles.add(
        EdgeHandle(
          edgeIndex: i,
          position: LatLng(
            (p1.latitude + p2.latitude) / 2,
            (p1.longitude + p2.longitude) / 2,
          ),
        ),
      );
    }

    return handles;
  }

  int insertVertex(int edgeIndex) {
    final p1 = points[edgeIndex];
    final p2 = points[(edgeIndex + 1) % points.length];

    final midpoint = LatLng(
      (p1.latitude + p2.latitude) / 2,
      (p1.longitude + p2.longitude) / 2,
    );

    points.insert(edgeIndex + 1, midpoint);

    return edgeIndex + 1;
  }

  Future<void> loadGeofence() async {
    final fence = await DatabaseHelper.instance.getGeofence();

    if (fence != null) {
      final loadedPoints = await DatabaseHelper.instance.getGeofencePoints(
        fence['id'] as int,
      );

      points = List.from(loadedPoints);
      savedPoints = List.from(loadedPoints);
    }
  }

  Future<void> startEditing(LatLng center) async {
    isEditing = true;
    showPanel = true;

    final fence = await DatabaseHelper.instance.getGeofence();

    if (fence != null) {
      savedPoints = await DatabaseHelper.instance.getGeofencePoints(
        fence['id'] as int,
      );

      points = List.from(savedPoints);
    } else {
      points = [
        LatLng(center.latitude + 0.0005, center.longitude),
        LatLng(center.latitude - 0.0005, center.longitude - 0.0005),
        LatLng(center.latitude - 0.0005, center.longitude + 0.0005),
      ];
    }
  }

  void stopEditing() {
    isEditing = false;
    showPanel = false;
  }

  Future<void> save() async {
    stopEditing();

    await DatabaseHelper.instance.insertGeofence(
      name: "Farm A",
      points: points,
    );

    savedPoints = List.from(points);
  }

  Future<void> delete() async {
    points.clear();
    savedPoints.clear();

    await DatabaseHelper.instance.deleteAllGeofences();

    stopEditing();
  }

  void cancel() {
    if (savedPoints.isEmpty) {
      points.clear();
    } else {
      points = List.from(savedPoints);
    }

    stopEditing();
  }

  /// Ray-Casting point-in-polygon algorithm to check if a GPS coordinate
  /// (latitude, longitude) is inside the geofence boundary.
  bool containsPoint(LatLng point) {
    final polygon = points.isNotEmpty ? points : savedPoints;
    if (polygon.length < 3) return true; // Default safe if no active geofence set

    bool inside = false;
    final x = point.longitude;
    final y = point.latitude;

    for (int i = 0, j = polygon.length - 1; i < polygon.length; j = i++) {
      final xi = polygon[i].longitude;
      final yi = polygon[i].latitude;
      final xj = polygon[j].longitude;
      final yj = polygon[j].latitude;

      final intersect = ((yi > y) != (yj > y)) &&
          (x < (xj - xi) * (y - yi) / (yj - yi) + xi);

      if (intersect) inside = !inside;
    }

    return inside;
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

class MapStateController extends ChangeNotifier {
  /// User location
  LatLng? currentLocation;

  /// Selected download/geofence area
  LatLngBounds? selectedBounds;

  /// Bottom panel visibility
  bool showGeofencePanel = false;

  /// Future tracked animals
  final List<Marker> animalMarkers = [];

  //-----------------------------. 
  // Current location
  //-----------------------------
  void updateCurrentLocation(LatLng location) {
    currentLocation = location;
    notifyListeners();
  }

  //-----------------------------
  // Selected Area
  //-----------------------------
  void updateSelectedBounds(LatLngBounds bounds) {
    selectedBounds = bounds;
    notifyListeners();
  }

  void clearSelectedBounds() {
    selectedBounds = null;
    notifyListeners();
  }

  //-----------------------------
  // Geofence Panel
  //-----------------------------
  void showPanel() {
    showGeofencePanel = true;
    notifyListeners();
  }

  void hidePanel() {
    showGeofencePanel = false;
    notifyListeners();
  }

  //-----------------------------
  // Animal Markers
  //-----------------------------
  void setAnimalMarkers(List<Marker> markers) {
    animalMarkers
      ..clear()
      ..addAll(markers);

    notifyListeners();
  }

  void addAnimalMarker(Marker marker) {
    animalMarkers.add(marker);
    notifyListeners();
  }

  void clearAnimals() {
    animalMarkers.clear();
    notifyListeners();
  }
}

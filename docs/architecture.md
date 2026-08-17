Current Architecture

Screens
- MapScreen

Services
- LocationService
- TileCacheService
- TileCalculator

Controllers
- MapStateController

Widgets
- AppDrawer
- GeofencePanel

final code sturcture
lib/
│
├── app.dart
├── main.dart
│
├── core/
│   ├── constants/
│   ├── theme/
│   ├── utils/
│   └── exceptions/
│
├── models/
│   ├── animal.dart
│   ├── device.dart
│   ├── geofence.dart
│   ├── location_point.dart
│   └── lora_packet.dart
│
├── services/
│   ├── location_service.dart
│   ├── tile_cache_service.dart
│   ├── lora_service.dart
│   ├── animal_service.dart
│   └── storage_service.dart
│
├── controllers/
│   ├── map_state_controller.dart
│   ├── animal_controller.dart
│   └── lora_controller.dart
│
├── screens/
│   ├── map/
│   ├── animals/
│   ├── settings/
│   ├── alerts/
│   └── splash/
│
├── widgets/
│
└── assets/
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../database/database_helper.dart';
import '../models/base_station_data.dart';
import '../models/gps_data.dart';
import '../models/hardware_event.dart';

enum EspConnectionState { disconnected, connecting, connected }

enum StoredEventsSyncStatus { syncing, completed, empty, failed }

class LivestockWebSocketService {
  // --------------------------------------------------------------------------
  // SINGLETON
  // --------------------------------------------------------------------------
  static final LivestockWebSocketService _instance =
      LivestockWebSocketService._internal();
  factory LivestockWebSocketService() => _instance;
  LivestockWebSocketService._internal();

  // --------------------------------------------------------------------------
  // EVENT SYNC CONTROLLER & TIMERS
  // --------------------------------------------------------------------------
  final StreamController<StoredEventsSyncStatus> _eventSyncController =
      StreamController<StoredEventsSyncStatus>.broadcast();

  Stream<StoredEventsSyncStatus> get eventSyncStream =>
      _eventSyncController.stream;

  Timer? _eventSyncTimer;

  void _finishEventSync(StoredEventsSyncStatus status) {
    _eventSyncTimer?.cancel();
    _eventSyncTimer = null;
    _eventSyncController.add(status);
  }

  // --------------------------------------------------------------------------
  // STATE
  // --------------------------------------------------------------------------
  WebSocket? _socket;
  EspConnectionState _state = EspConnectionState.disconnected;
  EspConnectionState get connectionState => _state;
  bool get isConnected => _state == EspConnectionState.connected;

  // --------------------------------------------------------------------------
  // STREAMS
  // --------------------------------------------------------------------------
  final StreamController<GpsData> _animalController =
      StreamController<GpsData>.broadcast();
  Stream<GpsData> get animalStream => _animalController.stream;

  final StreamController<BaseStationData> _baseStationController =
      StreamController<BaseStationData>.broadcast();
  Stream<BaseStationData> get baseStationStream =>
      _baseStationController.stream;

  final StreamController<EspConnectionState> _stateController =
      StreamController<EspConnectionState>.broadcast();
  Stream<EspConnectionState> get stateStream => _stateController.stream;

  final StreamController<String> _ackController =
      StreamController<String>.broadcast();
  Stream<String> get ackStream => _ackController.stream;

  final StreamController<String> _alertController =
      StreamController<String>.broadcast();
  Stream<String> get alertStream => _alertController.stream;

  final StreamController<HardwareAlert> _hardwareAlertController =
      StreamController<HardwareAlert>.broadcast();
  Stream<HardwareAlert> get hardwareAlertStream =>
      _hardwareAlertController.stream;

  final StreamController<StoredHardwareEvent> _eventController =
      StreamController<StoredHardwareEvent>.broadcast();
  Stream<StoredHardwareEvent> get storedEventStream => _eventController.stream;

  // --------------------------------------------------------------------------
  // CONNECT
  // --------------------------------------------------------------------------
  Future<bool> connect({String host = '192.168.4.1', int port = 81}) async {
    if (_state == EspConnectionState.connected) return true;
    if (_state == EspConnectionState.connecting) return false;

    _setState(EspConnectionState.connecting);

    try {
      final url = 'ws://$host:$port/';
      _socket = await WebSocket.connect(
        url,
      ).timeout(const Duration(seconds: 5));
      _setState(EspConnectionState.connected);
      _socket!.listen(
        _onMessage,
        onDone: _onDisconnected,
        onError: (_) => _onDisconnected(),
      );
      return true;
    } catch (e) {
      debugPrint('WebSocket connection error: $e');
      _setState(EspConnectionState.disconnected);
      return false;
    }
  }

  // --------------------------------------------------------------------------
  // MESSAGE HANDLER
  // --------------------------------------------------------------------------
  void _onMessage(dynamic message) {
    final msgStr = message.toString().trim();
    assert(() {
      debugPrint('[WS RX] $msgStr');
      return true;
    }());

    if (msgStr.isEmpty) return;

    try {
      final upper = msgStr.toUpperCase();

      // Route plain text status & command acknowledgments directly to ackStream
      if (upper.startsWith('ACK') ||
          upper.startsWith('OK') ||
          upper.startsWith('COMMAND_') ||
          upper.startsWith('EVENT_ACK_') ||
          upper.startsWith('STATUS,')) {
        _ackController.add(msgStr);
        return;
      }

      if (upper.startsWith('DATA,')) {
        final animal = GpsData.fromCsv(msgStr);
        _animalController.add(animal);
        DatabaseHelper.instance.recordLiveAnimalUpdate(animal).catchError((
          Object e,
        ) {
          debugPrint('Failed to persist animal update: $e');
        });
        return;
      }

      if (upper.startsWith('ALERT,')) {
        _alertController.add(msgStr);
        _hardwareAlertController.add(HardwareAlert.fromCsv(msgStr));
        return;
      }

      if (upper.startsWith('EVENT,')) {
        _eventController.add(StoredHardwareEvent.fromCsv(msgStr));
        return;
      }

      if (upper == 'EVENTS_END') {
        _finishEventSync(StoredEventsSyncStatus.completed);
        return;
      }

      if (upper == 'EVENTS_EMPTY') {
        _finishEventSync(StoredEventsSyncStatus.empty);
        return;
      }

      // JSON payload decoding
      final json = jsonDecode(msgStr) as Map<String, dynamic>;
      final type = json['type']?.toString();

      if (type == 'animal') {
        final animal = GpsData.fromJson(json);
        _animalController.add(animal);

        DatabaseHelper.instance.recordLiveAnimalUpdate(animal).catchError((
          Object e,
        ) {
          debugPrint('Failed to persist animal update: $e');
        });
      } else if (type == 'base_station') {
        _baseStationController.add(BaseStationData.fromJson(json));
      } else if (type == 'ack') {
        final ackMsg =
            json['message']?.toString() ??
            json['ack']?.toString() ??
            json['command']?.toString() ??
            json['status']?.toString() ??
            json['payload']?.toString() ??
            msgStr;

        _ackController.add(ackMsg);
      }
    } catch (e) {
      debugPrint('Error parsing WebSocket message: $e | Raw: $msgStr');
      final upper = msgStr.toUpperCase();
      if (upper.startsWith('ACK') ||
          upper.startsWith('OK') ||
          upper.startsWith('COMMAND_') ||
          upper.startsWith('EVENT_ACK_')) {
        _ackController.add(msgStr);
      }
    }
  }

  // --------------------------------------------------------------------------
  // SEND COMMANDS
  // --------------------------------------------------------------------------
  void send(String command) {
    if (isConnected && _socket != null) {
      _socket!.add(command);
    }
  }

  void sendLive(String animalId, bool enabled) {
    send('LIVE,$animalId,${enabled ? 'ON' : 'OFF'}');
  }

  void poll(String animalId) {
    // v2 collars report autonomously and accept NOW during the report
    // receive window; they do not implement the legacy POLL command.
    sendNow(animalId);
  }

  void sendNow(String animalId) {
    send('NOW,$animalId');
  }

  void sendConfig(
    String animalId, {
    required int normalSec,
    required int fastSec,
    required int liveSec,
  }) {
    send('CFG,$animalId,$normalSec,$fastSec,$liveSec');
  }

  void sendFence(String animalId, List<List<double>> points) {
    final coordinates = points
        .map(
          (point) =>
              '${point[0].toStringAsFixed(6)},${point[1].toStringAsFixed(6)}',
        )
        .join(',');
    send('FENCE,$animalId,${points.length},$coordinates');
  }

  bool requestStoredEvents() {
    if (!isConnected || _socket == null) {
      return false;
    }

    _eventSyncTimer?.cancel();
    _eventSyncController.add(StoredEventsSyncStatus.syncing);

    _eventSyncTimer = Timer(const Duration(seconds: 10), () {
      _finishEventSync(StoredEventsSyncStatus.failed);
    });

    try {
      _socket!.add('GET_EVENTS');
      return true;
    } catch (e) {
      _finishEventSync(StoredEventsSyncStatus.failed);
      return false;
    }
  }

  /// Sends acknowledgment for a stored hardware event using the protocol string expected by the base station: EVENT_ACK,id
  bool acknowledgeStoredEvent(int id) {
    if (!isConnected || _socket == null) {
      return false;
    }
    try {
      _socket!.add('EVENT_ACK,$id');
      return true;
    } catch (e) {
      debugPrint('Error sending EVENT_ACK: $e');
      return false;
    }
  }

  /// Enables live tracking for specified animals by issuing individual LIVE,id,ON commands.
  bool enableLiveForAnimals(dynamic animalIds) {
    if (!isConnected || _socket == null) {
      return false;
    }
    try {
      if (animalIds is Iterable) {
        for (final id in animalIds) {
          _socket!.add('LIVE,$id,ON');
        }
      } else {
        _socket!.add('LIVE,$animalIds,ON');
      }
      return true;
    } catch (e) {
      debugPrint('Error enabling live mode: $e');
      return false;
    }
  }

  // --------------------------------------------------------------------------
  // DISCONNECT
  // --------------------------------------------------------------------------
  void _onDisconnected() {
    _socket = null;
    _setState(EspConnectionState.disconnected);
    if (_eventSyncTimer != null) {
      _finishEventSync(StoredEventsSyncStatus.failed);
    }
  }

  void disconnect() {
    _socket?.close();
    _onDisconnected();
  }

  // --------------------------------------------------------------------------
  // INTERNAL
  // --------------------------------------------------------------------------
  void _setState(EspConnectionState state) {
    _state = state;
    _stateController.add(state);
  }

  // --------------------------------------------------------------------------
  // DISPOSE
  // --------------------------------------------------------------------------
  void dispose() {}

  void disposeCompletely() {
    disconnect();
    _animalController.close();
    _baseStationController.close();
    _stateController.close();
    _ackController.close();
    _alertController.close();
    _hardwareAlertController.close();
    _eventController.close();
    _eventSyncTimer?.cancel();
    _eventSyncTimer = null;
    _eventSyncController.close();
  }
}

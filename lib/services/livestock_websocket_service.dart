import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../database/database_helper.dart';
import '../models/gps_data.dart';
import '../models/base_station_data.dart';

enum EspConnectionState { disconnected, connecting, connected }

class LivestockWebSocketService {
  // --------------------------------------------------------------------------
  // SINGLETON
  // --------------------------------------------------------------------------
  static final LivestockWebSocketService _instance =
      LivestockWebSocketService._internal();
  factory LivestockWebSocketService() => _instance;
  LivestockWebSocketService._internal();

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
      _setState(EspConnectionState.disconnected);
      return false;
    }
  }

  // --------------------------------------------------------------------------
  // MESSAGE HANDLER
  // --------------------------------------------------------------------------
  void _onMessage(dynamic message) {
    try {
      final msgStr = message.toString().trim();
      if (msgStr.toUpperCase().startsWith('ACK') || msgStr.toUpperCase().startsWith('OK')) {
        _ackController.add(msgStr);
        return;
      }

      final json = jsonDecode(msgStr) as Map<String, dynamic>;
      final type = json['type']?.toString();

      if (type == 'animal') {
        final animal = GpsData.fromJson(json);

        _animalController.add(animal);

        // Persist every packet: updates the current-snapshot row and
        // appends a historical row. Fire-and-forget on purpose — a DB
        // write failing here should never block or crash live streaming.
        // This is the single point where all animal data gets persisted,
        // regardless of which screen (if any) is currently open.
        DatabaseHelper.instance.recordLiveAnimalUpdate(animal).catchError((
          Object e,
        ) {
          // ignore: avoid_print
          print('Failed to persist animal update: $e');
        });
      } else if (type == 'base_station') {
        _baseStationController.add(BaseStationData.fromJson(json));
      } else if (type == 'ack') {
        final ackMsg = json['message']?.toString() ??
            json['ack']?.toString() ??
            json['command']?.toString() ??
            json['status']?.toString() ??
            json['payload']?.toString() ??
            msgStr;

        _ackController.add(ackMsg);
      }
    } catch (_) {
      final msgStr = message?.toString().trim();
      if (msgStr != null && (msgStr.toUpperCase().startsWith('ACK') || msgStr.toUpperCase().startsWith('OK'))) {
        _ackController.add(msgStr);
      }
    }
  }

  // --------------------------------------------------------------------------
  // SEND COMMAND
  // --------------------------------------------------------------------------
  void send(String command) {
    if (isConnected && _socket != null) {
      _socket!.add(command);
    }
  }

  // --------------------------------------------------------------------------
  // DISCONNECT
  // --------------------------------------------------------------------------
  void _onDisconnected() {
    _socket = null;
    _setState(EspConnectionState.disconnected);
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
  }
}

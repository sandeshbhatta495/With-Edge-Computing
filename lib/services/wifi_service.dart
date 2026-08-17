import '../services/discovery_server.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';

class WifiService {
  String? host;
  int? port;

  String _buffer = "";
  Socket? _socket;

  final StreamController<Map<String, dynamic>> _messageController =
      StreamController<Map<String, dynamic>>.broadcast();

  Stream<Map<String, dynamic>> get messages => _messageController.stream;

  bool get isConnected => _socket != null;

  Future<bool> connect() async {
    try {
      final result = await ServerDiscovery().discover();

      if (result == null) {
        return false;
      }

      final parts = result.split(":");

      host = parts[1];
      port = int.parse(parts[2]);

      _socket = await Socket.connect(
        host!,
        port!,
        timeout: const Duration(seconds: 5),
      );

      _socket!.listen(
        (data) {
          _buffer += utf8.decode(data);

          while (_buffer.contains('\n')) {
            final index = _buffer.indexOf('\n');
            final line = _buffer.substring(0, index).trim();
            _buffer = _buffer.substring(index + 1);

            if (line.isEmpty) continue;

            try {
              final json = jsonDecode(line) as Map<String, dynamic>;
              _messageController.add(json);
            } catch (e) {
              debugPrint("Invalid JSON: $line");
            }
          }
        },
        onDone: disconnect,
        onError: (_) => disconnect(),
      );

      return true;
    } catch (e) {
      return false;
    }
  }

  void send(String command) {
    if (_socket != null) {
      _socket!.write("$command\n");
    }
  }

  void disconnect() {
    _socket?.destroy();
    _socket = null;
  }

  void dispose() {
    disconnect();
    _messageController.close();
  }
}

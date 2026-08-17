import 'dart:async';
import 'dart:io';

class ServerDiscovery {
  static const int discoveryPort = 8888;

  Future<String?> discover() async {
    final socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      0,
    );

    socket.broadcastEnabled = true;

    socket.send(
      "DISCOVER_LIVESTOCK_SERVER".codeUnits,
      InternetAddress("255.255.255.255"),
      discoveryPort,
    );

    final completer = Completer<String?>();

    socket.listen((event) {
      if (event == RawSocketEvent.read) {
        final dg = socket.receive();

        if (dg == null) return;

        final reply = String.fromCharCodes(dg.data);

        if (reply.startsWith("LIVESTOCK_SERVER")) {
          completer.complete(reply);
          socket.close();
        }
      }
    });

    return completer.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        socket.close();
        return null;
      },
    );
  }
}
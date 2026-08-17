import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../database/database_helper.dart';
import '../services/livestock_websocket_service.dart';
import '../providers/notification_provider.dart';
import 'alerts_screen.dart';
import 'map_screen.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  List<Map<String, Object?>> records = [];
  Timer? _refreshTimer;

  final LivestockWebSocketService esp = LivestockWebSocketService();
  bool robotConnected = false;
  bool _connecting = false;

  @override
  void initState() {
    super.initState();
    loadRecords();
    connectWifi();

    _refreshTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      loadRecords();
      if (mounted && robotConnected != esp.isConnected) {
        setState(() {
          robotConnected = esp.isConnected;
        });
      }
    });
  }

  Future<void> loadRecords() async {
    final data = await DatabaseHelper.instance.getDashboard();
    if (!mounted) return;
    setState(() {
      records = data;
    });
  }

  Future<void> connectWifi() async {
    setState(() => _connecting = true);
    final connected = await esp.connect();
    if (!mounted) return;
    setState(() {
      robotConnected = connected;
      _connecting = false;
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    esp.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final total = records.length;
    final breached = records
        .where((r) => r["Geofence_Status"] == "outside")
        .length;
    final safe = total - breached;

    final logs = ref.watch(notificationProvider);
    final recentAlerts = [...logs]
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
    final latestFive = recentAlerts.take(5).toList();

    return Scaffold(
      appBar: AppBar(title: const Text("Home")),
      body: RefreshIndicator(
        onRefresh: () async {
          await loadRecords();
        },
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // ---------------- Summary cards ----------------
            Row(
              children: [
                Expanded(
                  child: _SummaryCard(
                    label: "Total",
                    value: "$total",
                    color: Colors.blue,
                    icon: Icons.pets,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _SummaryCard(
                    label: "Safe",
                    value: "$safe",
                    color: Colors.green,
                    icon: Icons.check_circle,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _SummaryCard(
                    label: "Breached",
                    value: "$breached",
                    color: Colors.red,
                    icon: Icons.warning,
                  ),
                ),
              ],
            ),

            const SizedBox(height: 20),

            // ---------------- Hardware status ----------------
            Card(
              child: ListTile(
                leading: Icon(
                  robotConnected ? Icons.wifi : Icons.wifi_off,
                  color: robotConnected ? Colors.green : Colors.red,
                ),
                title: Text(
                  robotConnected
                      ? "Base station connected"
                      : "Base station offline",
                ),
                subtitle: _connecting
                    ? const Text("Connecting...")
                    : Text(robotConnected ? "Live" : "Not reachable"),
                trailing: IconButton(
                  icon: const Icon(Icons.refresh),
                  onPressed: _connecting ? null : connectWifi,
                ),
              ),
            ),

            const SizedBox(height: 20),

            // ---------------- Quick actions ----------------
            const Text(
              "Quick Actions",
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                ElevatedButton.icon(
                  onPressed: _connecting ? null : connectWifi,
                  icon: const Icon(Icons.sync),
                  label: const Text("Sync Trackers"),
                ),
                ElevatedButton.icon(
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const AlertsScreen()),
                    );
                  },
                  icon: const Icon(Icons.notifications),
                  label: const Text("View Alerts"),
                ),
                ElevatedButton.icon(
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const OnlineMapScreen(),
                      ),
                    );
                  },
                  icon: const Icon(Icons.map),
                  label: const Text("Open Map"),
                ),

                // TODO: wire this up once the exact buzzer command
                // string is confirmed from the ESP8266 firmware source.
                ElevatedButton.icon(
                  onPressed: null,
                  icon: const Icon(Icons.campaign),
                  label: const Text("Trigger Beacon"),
                ),
              ],
            ),

            const SizedBox(height: 20),

            // ---------------- Recent alerts ----------------
            const Text(
              "Recent Alerts",
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            if (latestFive.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Text("No alerts yet"),
              )
            else
              ...latestFive.map(
                (event) => Card(
                  child: ListTile(
                    dense: true,
                    title: Text(event.message),
                    subtitle: Text(event.timestamp.toString()),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  final IconData icon;

  const _SummaryCard({
    required this.label,
    required this.value,
    required this.color,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      color: color.withValues(alpha: 0.1),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Column(
          children: [
            Icon(icon, color: color, size: 28),
            const SizedBox(height: 6),
            Text(
              value,
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
            Text(label, style: const TextStyle(fontSize: 12)),
          ],
        ),
      ),
    );
  }
}

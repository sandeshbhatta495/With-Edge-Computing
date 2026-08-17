import 'package:flutter/material.dart';
import '../screens/dashboard_screen.dart';
import '../screens/home_screen.dart';
import '../screens/map_screen.dart';
import '../screens/settings_screen.dart';
import '../screens/alerts_screen.dart';

class AppDrawer extends StatelessWidget {
  final VoidCallback onGeoFenceTap;

  const AppDrawer({super.key, required this.onGeoFenceTap});

  @override
  Widget build(BuildContext context) {
    return Drawer(
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          // -------------------------------------------------------------------
          // DRAWER HEADER
          // -------------------------------------------------------------------
          SizedBox(
            height: 240,
            child: DrawerHeader(
              decoration: const BoxDecoration(color: Colors.green),
              margin: EdgeInsets.zero,
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.pets, size: 60, color: Colors.white),

                  const SizedBox(height: 8),

                  const Text(
                    "Livestock Tracker",
                    style: TextStyle(color: Colors.white, fontSize: 22),
                  ),
                ],
              ),
            ),
          ),

          // -------------------------------------------------------------------
          // HOME
          // -------------------------------------------------------------------
          ListTile(
            leading: const Icon(Icons.home),
            title: const Text("Home"),
            onTap: () {
              Navigator.pop(context);

              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const HomeScreen()),
              );
            },
          ),

          // -------------------------------------------------------------------
          // MAP
          // -------------------------------------------------------------------
          ListTile(
            leading: const Icon(Icons.map),
            title: const Text("Map"),
            onTap: () {
              Navigator.pop(context);

              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const OnlineMapScreen()),
              );
            },
          ),

          // -------------------------------------------------------------------
          // GEO-FENCE
          // -------------------------------------------------------------------
          ListTile(
            leading: const Icon(Icons.location_on),
            title: const Text("Geo-Fence"),
            onTap: () {
              Navigator.pop(context);
              onGeoFenceTap();
            },
          ),

          // -------------------------------------------------------------------
          // DASHBOARD
          // -------------------------------------------------------------------
          ListTile(
            leading: const Icon(Icons.dashboard),
            title: const Text("Dashboard"),
            onTap: () {
              Navigator.pop(context);

              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const DashboardScreen()),
              );
            },
          ),

          // -------------------------------------------------------------------
          // ALERTS
          // -------------------------------------------------------------------
          ListTile(
            leading: const Icon(Icons.notifications),
            title: const Text("Alerts"),
            onTap: () {
              Navigator.pop(context);
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const AlertsScreen()),
              );
            },
          ),

          // -------------------------------------------------------------------
          // SETTINGS
          // -------------------------------------------------------------------
          ListTile(
            leading: const Icon(Icons.settings),
            title: const Text("Settings"),
            onTap: () {
              Navigator.pop(context);

              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const SettingsScreen()),
              );
            },
          ),
        ],
      ),
    );
  }
}

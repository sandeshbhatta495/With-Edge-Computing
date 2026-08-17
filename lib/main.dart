import 'package:flutter/material.dart';
import 'services/background_service.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'app.dart';
import 'database/database_helper.dart';
import 'providers/provider_container.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Permission.notification.request();
  await BackgroundService.initialize();
  await BackgroundService.start();
  await DatabaseHelper.instance.database;
  runApp(
    UncontrolledProviderScope(
      container: providerContainer,
      child: const MyApp(),
    ),
  );
}

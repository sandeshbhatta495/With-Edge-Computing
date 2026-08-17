import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/database_helper.dart';
import '../services/livestock_websocket_service.dart';
import '../providers/notification_provider.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  // --------------------------------------------------------------------------
  // WI-FI SERVICE
  // --------------------------------------------------------------------------

  final LivestockWebSocketService esp = LivestockWebSocketService();

  bool robotConnected = false;
  bool ledOn = false;
  bool _connecting = false;

  // Pending-command flags so the UI can show "applying..." instead of
  // instantly assuming success.
  bool _intervalPending = false;
  bool _ledPending = false;

  StreamSubscription<EspConnectionState>? _stateSubscription;
  StreamSubscription<String>? _ackSubscription;

  // --------------------------------------------------------------------------
  // COLLAR INTERVAL
  // --------------------------------------------------------------------------

  String selectedInterval = '1 minute';

  // --------------------------------------------------------------------------
  // INIT / DISPOSE
  // --------------------------------------------------------------------------

  @override
  void initState() {
    super.initState();

    // Read the singleton's current state immediately instead of assuming
    // disconnected, and stay in sync with it going forward (Issue 3).
    robotConnected = esp.isConnected;

    _stateSubscription = esp.stateStream.listen((state) {
      if (!mounted) return;

      setState(() {
        robotConnected = state == EspConnectionState.connected;
      });
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      connectWifi();
    });
  }

  @override
  void dispose() {
    _stateSubscription?.cancel();
    _ackSubscription?.cancel();
    super.dispose();
  }

  // --------------------------------------------------------------------------
  // ACK HELPER
  // --------------------------------------------------------------------------
  // Sends a command, then waits for the next ack message to arrive within
  // [timeout]. Returns true if an ack showed up in time, false otherwise.
  //
  // NOTE: this currently treats *any* ack within the window as belonging to
  // this command, since the base station handles one command at a time. If
  // your firmware later echoes the command in the ack message, tighten this
  // by checking `message.contains(expectedPrefix)` below.
  Future<bool> _sendAndAwaitAck(
    String command, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final completer = Completer<bool>();
    late final StreamSubscription<String> sub;

    sub = esp.ackStream.listen((message) {
      if (!completer.isCompleted) {
        completer.complete(true);
      }
    });

    esp.send(command);

    final timer = Timer(timeout, () {
      if (!completer.isCompleted) {
        completer.complete(false);
      }
    });

    final result = await completer.future;

    timer.cancel();
    await sub.cancel();

    return result;
  }

  // --------------------------------------------------------------------------
  // COLLAR INTERVAL
  // --------------------------------------------------------------------------

  Future<void> setCollarInterval(String value) async {
    if (!robotConnected) {
      _showSnackBar('Base station is not connected', isError: true);
      return;
    }

    if (_intervalPending) return;

    String command;

    switch (value) {
      case '1 minute':
        command = 'SET_INTERVAL:60000';
        break;

      case '5 minutes':
        command = 'SET_INTERVAL:300000';
        break;

      case '30 minutes':
        command = 'SET_INTERVAL:1800000';
        break;

      default:
        return;
    }

    setState(() => _intervalPending = true);

    try {
      final acked = await _sendAndAwaitAck(command);

      if (!mounted) return;

      if (acked) {
        setState(() {
          selectedInterval = value;
        });

        _showSnackBar('Collar interval changed to $value');
      } else {
        _showSnackBar(
          'Collar did not confirm the interval change',
          isError: true,
        );
      }
    } catch (e) {
      debugPrint('Collar interval error: $e');

      if (!mounted) return;

      _showSnackBar('Failed to change collar interval', isError: true);
    } finally {
      if (mounted) {
        setState(() => _intervalPending = false);
      }
    }
  }

  // --------------------------------------------------------------------------
  // INTERVAL DIALOG
  // --------------------------------------------------------------------------

  Future<void> _showIntervalDialog() async {
    final selected = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        return SimpleDialog(
          title: const Text('Collar Data Interval'),
          children: [
            SimpleDialogOption(
              onPressed: () {
                Navigator.pop(dialogContext, '1 minute');
              },
              child: const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('1 minute'),
              ),
            ),
            SimpleDialogOption(
              onPressed: () {
                Navigator.pop(dialogContext, '5 minutes');
              },
              child: const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('5 minutes'),
              ),
            ),
            SimpleDialogOption(
              onPressed: () {
                Navigator.pop(dialogContext, '30 minutes');
              },
              child: const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('30 minutes'),
              ),
            ),
          ],
        );
      },
    );

    if (selected == null) return;

    await setCollarInterval(selected);
  }

  // --------------------------------------------------------------------------
  // WI-FI CONNECTION
  // --------------------------------------------------------------------------

  Future<void> connectWifi() async {
    if (_connecting) return;

    setState(() => _connecting = true);

    try {
      final connected = await esp.connect();

      if (!mounted) return;

      // robotConnected itself is now driven by _stateSubscription; we only
      // need to manage the "connecting" flag and the failure snackbar here.
      setState(() => _connecting = false);

      if (!connected) {
        _showSnackBar('Base station could not be reached', isError: true);
      }
    } catch (e) {
      debugPrint('Wi-Fi connection error: $e');

      if (!mounted) return;

      setState(() => _connecting = false);

      _showSnackBar('Failed to connect to base station', isError: true);
    }
  }

  // --------------------------------------------------------------------------
  // LED CONTROL
  // --------------------------------------------------------------------------

  Future<void> toggleLed(bool value) async {
    if (!robotConnected || _ledPending) return;

    setState(() => _ledPending = true);

    try {
      final command = value ? 'LED_ON' : 'LED_OFF';

      final acked = await _sendAndAwaitAck(command);

      if (!mounted) return;

      if (acked) {
        setState(() {
          ledOn = value;
        });
      } else {
        _showSnackBar('Collar did not confirm the LED change', isError: true);
      }
    } catch (e) {
      debugPrint('LED command error: $e');

      if (!mounted) return;

      _showSnackBar('Failed to control LED', isError: true);
    } finally {
      if (mounted) {
        setState(() => _ledPending = false);
      }
    }
  }

  // --------------------------------------------------------------------------
  // CLEAR HISTORY
  // --------------------------------------------------------------------------

  Future<void> clearHistory() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Clear Alert History'),
          content: const Text(
            'This will permanently delete all alert history. '
            'Continue?',
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(dialogContext, false);
              },
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () {
                Navigator.pop(dialogContext, true);
              },
              child: const Text('Delete', style: TextStyle(color: Colors.red)),
            ),
          ],
        );
      },
    );

    if (confirm != true) return;

    try {
      await DatabaseHelper.instance.clearLogs();

      if (!mounted) return;

      ref.read(notificationProvider.notifier).clearNotifications();

      _showSnackBar('Alert history cleared successfully');
    } catch (e) {
      debugPrint('Clear history error: $e');

      if (!mounted) return;

      _showSnackBar('Failed to clear alert history', isError: true);
    }
  }

  // --------------------------------------------------------------------------
  // SNACKBAR
  // --------------------------------------------------------------------------

  void _showSnackBar(String message, {bool isError = false}) {
    if (!mounted) return;

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: isError ? Colors.red : null,
        ),
      );
  }

  // --------------------------------------------------------------------------
  // BUILD
  // --------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),

      body: ListView(
        padding: const EdgeInsets.all(16),

        children: [
          // ==================================================================
          // BASE STATION
          // ==================================================================
          const _SectionHeader(title: 'Base Station'),

          Card(
            child: Column(
              children: [
                // ------------------------------------------------------------
                // CONNECTION
                // ------------------------------------------------------------
                ListTile(
                  leading: Icon(
                    robotConnected ? Icons.wifi : Icons.wifi_off,
                    color: robotConnected ? Colors.green : Colors.red,
                  ),

                  title: Text(
                    robotConnected
                        ? 'Base station connected'
                        : 'Base station offline',
                  ),

                  subtitle: _connecting
                      ? const Text('Connecting...')
                      : Text(robotConnected ? 'Live' : 'Not reachable'),

                  trailing: _connecting
                      ? const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : IconButton(
                          icon: const Icon(Icons.refresh),
                          tooltip: 'Reconnect',
                          onPressed: connectWifi,
                        ),
                ),

                const Divider(height: 1),

                // ------------------------------------------------------------
                // LED BEACON
                // ------------------------------------------------------------
                SwitchListTile(
                  secondary: _ledPending
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(
                          ledOn ? Icons.lightbulb : Icons.lightbulb_outline,
                          color: ledOn ? Colors.amber : Colors.grey,
                        ),

                  title: const Text('LED Beacon'),

                  subtitle: Text(
                    _ledPending ? 'Applying...' : (ledOn ? 'On' : 'Off'),
                  ),

                  value: ledOn,

                  onChanged: (robotConnected && !_ledPending)
                      ? toggleLed
                      : null,
                ),

                const Divider(height: 1),

                // ------------------------------------------------------------
                // COLLAR INTERVAL
                // ------------------------------------------------------------
                ListTile(
                  leading: _intervalPending
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.access_time, color: Colors.blue),

                  title: const Text('Collar Data Interval'),

                  subtitle: Text(
                    _intervalPending
                        ? 'Applying...'
                        : 'Send location every $selectedInterval',
                  ),

                  trailing: const Icon(Icons.chevron_right),

                  onTap: (robotConnected && !_intervalPending)
                      ? _showIntervalDialog
                      : () {
                          _showSnackBar(
                            robotConnected
                                ? 'Please wait for the current change to apply'
                                : 'Base station is not connected',
                            isError: true,
                          );
                        },
                ),
              ],
            ),
          ),

          const SizedBox(height: 20),

          // ==================================================================
          // DATABASE MANAGEMENT
          // ==================================================================
          const _SectionHeader(title: 'Database Management'),

          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.delete_forever, color: Colors.red),

                  title: const Text('Clear Livestock History'),

                  subtitle: const Text(
                    'Permanently deletes all history records',
                  ),

                  trailing: const Icon(Icons.chevron_right),

                  onTap: clearHistory,
                ),
              ],
            ),
          ),

          const SizedBox(height: 20),

          // ==================================================================
          // ABOUT
          // ==================================================================
          const _SectionHeader(title: 'About'),

          const Card(
            child: Column(
              children: [
                ListTile(
                  leading: Icon(Icons.pets, color: Colors.green),

                  title: Text('Livestock Tracker'),

                  subtitle: Text('LoRa-Integrated GPS Geo-Fencing System'),
                ),

                Divider(height: 1),

                ListTile(
                  leading: Icon(Icons.school),

                  title: Text('Institution'),

                  subtitle: Text(
                    'Advanced College of Engineering and '
                    'Management (ACEM)\n'
                    'Tribhuvan University, Nepal',
                  ),

                  isThreeLine: true,
                ),

                Divider(height: 1),

                ListTile(
                  leading: Icon(Icons.info_outline),

                  title: Text('Version'),

                  subtitle: Text('1.0.0'),
                ),
              ],
            ),
          ),

          const SizedBox(height: 20),
        ],
      ),
    );
  }
}

// ==============================================================================
// SECTION HEADER
// ==============================================================================

class _SectionHeader extends StatelessWidget {
  final String title;

  const _SectionHeader({required this.title});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),

      child: Text(
        title,

        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.bold,
          color: Colors.grey[600],
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

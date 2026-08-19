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
  // ============================================================================
  // BASE STATION / WEBSOCKET
  // ============================================================================

  final LivestockWebSocketService esp = LivestockWebSocketService();

  bool robotConnected = false;
  bool ledOn = false;
  bool _connecting = false;

  // ============================================================================
  // PENDING COMMAND STATES
  // ============================================================================

  bool _intervalPending = false;
  bool _liveModePending = false;
  bool _ledPending = false;

  StreamSubscription<EspConnectionState>? _stateSubscription;

  // ============================================================================
  // NORMAL COLLAR INTERVAL
  // ============================================================================

  String selectedInterval = '1 minute';

  // ============================================================================
  // LIVE MODE INTERVAL
  // ============================================================================

  int _liveInterval = 5000;

  // ============================================================================
  // INIT
  // ============================================================================

  @override
  void initState() {
    super.initState();

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

  // ============================================================================
  // DISPOSE
  // ============================================================================

  @override
  void dispose() {
    _stateSubscription?.cancel();
    super.dispose();
  }

  // ============================================================================
  // SEND COMMAND AND WAIT FOR ACK
  // ============================================================================

  Future<bool> _sendAndAwaitAck(
    String command, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    if (!esp.isConnected) {
      return false;
    }

    final completer = Completer<bool>();

    late final StreamSubscription<String> ackSubscription;

    ackSubscription = esp.ackStream.listen((message) {
      debugPrint('ACK received: $message');

      if (!completer.isCompleted) {
        completer.complete(true);
      }
    });

    try {
      debugPrint('Sending command: $command');

      esp.send(command);

      final timer = Timer(timeout, () {
        if (!completer.isCompleted) {
          completer.complete(false);
        }
      });

      final result = await completer.future;

      timer.cancel();

      return result;
    } finally {
      await ackSubscription.cancel();
    }
  }

  // ============================================================================
  // NORMAL COLLAR INTERVAL
  // ============================================================================

  Future<void> setCollarInterval(String value) async {
    if (!robotConnected) {
      _showSnackBar('Base station is not connected', isError: true);
      return;
    }

    if (_intervalPending) {
      return;
    }

    String? command;

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

    setState(() {
      _intervalPending = true;
    });

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
        setState(() {
          _intervalPending = false;
        });
      }
    }
  }

  // ============================================================================
  // NORMAL INTERVAL DIALOG
  // ============================================================================

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

    if (selected == null) {
      return;
    }

    await setCollarInterval(selected);
  }

  // ============================================================================
  // LIVE MODE INTERVAL DIALOG
  // ============================================================================

  Future<void> _showLiveModeDialog() async {
    int temporaryInterval = _liveInterval;

    final result = await showDialog<int>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('Live Mode Interval'),

              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Select transmission interval:'),

                    const SizedBox(height: 16),

                    SegmentedButton<int>(
                      segments: const [
                        ButtonSegment<int>(value: 5000, label: Text('5 sec')),
                        ButtonSegment<int>(value: 30000, label: Text('30 sec')),
                        ButtonSegment<int>(value: 60000, label: Text('1 min')),
                      ],

                      selected: {
                        if ([5000, 30000, 60000].contains(temporaryInterval))
                          temporaryInterval
                        else
                          5000,
                      },

                      onSelectionChanged: (Set<int> newSelection) {
                        setDialogState(() {
                          temporaryInterval = newSelection.first;
                        });
                      },
                    ),

                    const SizedBox(height: 20),

                    const Divider(),

                    const SizedBox(height: 8),

                    const Text(
                      'Custom interval',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),

                    const SizedBox(height: 8),

                    OutlinedButton.icon(
                      onPressed: () async {
                        final custom = await _showCustomIntervalDialog(
                          initialValue: temporaryInterval,
                        );

                        if (custom != null) {
                          setDialogState(() {
                            temporaryInterval = custom;
                          });
                        }
                      },

                      icon: const Icon(Icons.edit),

                      label: Text(_formatInterval(temporaryInterval)),
                    ),

                    const SizedBox(height: 8),

                    Text(
                      'Current selection: '
                      '${_formatInterval(temporaryInterval)}',
                      style: TextStyle(color: Colors.grey[700], fontSize: 13),
                    ),
                  ],
                ),
              ),

              actions: [
                TextButton(
                  onPressed: () {
                    Navigator.pop(dialogContext);
                  },
                  child: const Text('Cancel'),
                ),

                FilledButton(
                  onPressed: () {
                    Navigator.pop(dialogContext, temporaryInterval);
                  },
                  child: const Text('Apply'),
                ),
              ],
            );
          },
        );
      },
    );

    if (result == null) {
      return;
    }

    await _applyLiveInterval(result);
  }

  // ============================================================================
  // CUSTOM LIVE INTERVAL DIALOG
  // ============================================================================

  Future<int?> _showCustomIntervalDialog({required int initialValue}) async {
    final controller = TextEditingController(
      text: (initialValue ~/ 1000).toString(),
    );

    String unit = 'seconds';

    final result = await showDialog<int>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('Custom Live Interval'),

              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Set how often the collar transmits '
                      'data while live mode is active.',
                    ),
                  ),

                  const SizedBox(height: 20),

                  TextField(
                    controller: controller,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: false,
                    ),
                    decoration: const InputDecoration(
                      labelText: 'Interval',
                      hintText: 'Enter value',
                      border: OutlineInputBorder(),
                    ),
                  ),

                  const SizedBox(height: 16),

                  DropdownButtonFormField<String>(
                    initialValue: unit,
                    decoration: const InputDecoration(
                      labelText: 'Unit',
                      border: OutlineInputBorder(),
                    ),

                    items: const [
                      DropdownMenuItem(
                        value: 'seconds',
                        child: Text('Seconds'),
                      ),
                      DropdownMenuItem(
                        value: 'minutes',
                        child: Text('Minutes'),
                      ),
                    ],

                    onChanged: (value) {
                      if (value == null) return;

                      setDialogState(() {
                        unit = value;
                      });
                    },
                  ),

                  const SizedBox(height: 12),

                  Text(
                    'Allowed range: 1 second to 30 minutes',
                    style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                  ),
                ],
              ),

              actions: [
                TextButton(
                  onPressed: () {
                    Navigator.pop(dialogContext);
                  },
                  child: const Text('Cancel'),
                ),

                FilledButton(
                  onPressed: () {
                    final value = int.tryParse(controller.text.trim());

                    if (value == null || value <= 0) {
                      _showSnackBar('Enter a valid interval', isError: true);
                      return;
                    }

                    int milliseconds;

                    if (unit == 'seconds') {
                      milliseconds = value * 1000;
                    } else {
                      milliseconds = value * 60 * 1000;
                    }

                    if (milliseconds < 1000) {
                      _showSnackBar(
                        'Minimum interval is 1 second',
                        isError: true,
                      );
                      return;
                    }

                    if (milliseconds > 30 * 60 * 1000) {
                      _showSnackBar(
                        'Maximum interval is 30 minutes',
                        isError: true,
                      );
                      return;
                    }

                    Navigator.pop(dialogContext, milliseconds);
                  },
                  child: const Text('Set'),
                ),
              ],
            );
          },
        );
      },
    );

    controller.dispose();

    return result;
  }

  // ============================================================================
  // APPLY LIVE INTERVAL
  // ============================================================================

  Future<void> _applyLiveInterval(int interval) async {
    if (!robotConnected) {
      _showSnackBar('Base station is not connected', isError: true);
      return;
    }

    if (_liveModePending) {
      return;
    }

    setState(() {
      _liveModePending = true;
    });

    try {
      final command = 'SET_LIVE_INTERVAL:$interval';

      final acked = await _sendAndAwaitAck(command);

      if (!mounted) return;

      if (acked) {
        setState(() {
          _liveInterval = interval;
        });

        _showSnackBar(
          'Live interval set to '
          '${_formatInterval(interval)}',
        );
      } else {
        _showSnackBar(
          'Base station did not confirm '
          'the live interval',
          isError: true,
        );
      }
    } catch (e) {
      debugPrint('Live interval error: $e');

      if (!mounted) return;

      _showSnackBar('Failed to set live interval', isError: true);
    } finally {
      if (mounted) {
        setState(() {
          _liveModePending = false;
        });
      }
    }
  }

  // ============================================================================
  // FORMAT INTERVAL
  // ============================================================================

  String _formatInterval(int milliseconds) {
    if (milliseconds % 60000 == 0) {
      final minutes = milliseconds ~/ 60000;

      if (minutes == 1) {
        return '1 minute';
      }

      return '$minutes minutes';
    }

    if (milliseconds % 1000 == 0) {
      final seconds = milliseconds ~/ 1000;

      if (seconds == 1) {
        return '1 second';
      }

      return '$seconds seconds';
    }

    return '${milliseconds}ms';
  }

  // ============================================================================
  // BASE STATION CONNECTION
  // ============================================================================

  Future<void> connectWifi() async {
    if (_connecting) {
      return;
    }

    setState(() {
      _connecting = true;
    });

    try {
      final connected = await esp.connect();

      if (!mounted) return;

      setState(() {
        _connecting = false;
        robotConnected = connected;
      });

      if (!connected) {
        _showSnackBar('Base station could not be reached', isError: true);
      }
    } catch (e) {
      debugPrint('Wi-Fi connection error: $e');

      if (!mounted) return;

      setState(() {
        _connecting = false;
        robotConnected = false;
      });

      _showSnackBar('Failed to connect to base station', isError: true);
    }
  }

  // ============================================================================
  // LED CONTROL
  // ============================================================================

  Future<void> toggleLed(bool value) async {
    if (!robotConnected || _ledPending) {
      return;
    }

    setState(() {
      _ledPending = true;
    });

    try {
      final command = value ? 'LED_ON' : 'LED_OFF';

      final acked = await _sendAndAwaitAck(command);

      if (!mounted) return;

      if (acked) {
        setState(() {
          ledOn = value;
        });

        _showSnackBar(value ? 'LED turned on' : 'LED turned off');
      } else {
        _showSnackBar(
          'Base station did not confirm '
          'the LED change',
          isError: true,
        );
      }
    } catch (e) {
      debugPrint('LED command error: $e');

      if (!mounted) return;

      _showSnackBar('Failed to control LED', isError: true);
    } finally {
      if (mounted) {
        setState(() {
          _ledPending = false;
        });
      }
    }
  }

  // ============================================================================
  // CLEAR HISTORY
  // ============================================================================

  Future<void> clearHistory() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Clear Alert History'),

          content: const Text(
            'This will permanently delete all '
            'alert history. Continue?',
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

    if (confirm != true) {
      return;
    }

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

  // ============================================================================
  // SNACKBAR
  // ============================================================================

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

  // ============================================================================
  // BUILD
  // ============================================================================

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
                // NORMAL COLLAR INTERVAL
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
                        : 'Send location every '
                              '$selectedInterval',
                  ),

                  trailing: const Icon(Icons.chevron_right),

                  onTap: (robotConnected && !_intervalPending)
                      ? _showIntervalDialog
                      : () {
                          _showSnackBar(
                            robotConnected
                                ? 'Please wait for the '
                                      'current change to apply'
                                : 'Base station is '
                                      'not connected',
                            isError: true,
                          );
                        },
                ),

                const Divider(height: 1),

                // ------------------------------------------------------------
                // LIVE MODE INTERVAL
                // ------------------------------------------------------------
                ListTile(
                  leading: _liveModePending
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.videocam, color: Colors.red),

                  title: const Text('Live Mode Interval'),

                  subtitle: Text(
                    _liveModePending
                        ? 'Applying...'
                        : 'Transmit every '
                              '${_formatInterval(_liveInterval)} '
                              'when live',
                  ),

                  trailing: const Icon(Icons.chevron_right),

                  onTap: (robotConnected && !_liveModePending)
                      ? _showLiveModeDialog
                      : () {
                          _showSnackBar(
                            robotConnected
                                ? 'Please wait for the '
                                      'current change'
                                : 'Base station is '
                                      'not connected',
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
                    'Permanently deletes all '
                    'history records',
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

                  subtitle: Text(
                    'LoRa-Integrated GPS Geo-Fencing '
                    'System',
                  ),
                ),

                Divider(height: 1),

                ListTile(
                  leading: Icon(Icons.school),

                  title: Text('Institution'),

                  subtitle: Text(
                    'Advanced College of Engineering '
                    'and Management (ACEM)\n'
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

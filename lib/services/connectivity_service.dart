import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';

class ConnectivityService {
  final Connectivity _connectivity = Connectivity();

  /// Tests actual WAN internet reachability.
  static Future<bool> hasInternetReachability() async {
    try {
      final result = await InternetAddress.lookup('google.com')
          .timeout(const Duration(seconds: 2));
      return result.isNotEmpty && result[0].rawAddress.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// Returns the true WAN internet connectivity status.
  Future<bool> isConnected() async {
    final result = await _connectivity.checkConnectivity();
    final hasNetwork = result.contains(ConnectivityResult.mobile) ||
        result.contains(ConnectivityResult.wifi) ||
        result.contains(ConnectivityResult.ethernet);

    if (!hasNetwork) return false;

    return await hasInternetReachability();
  }

  /// Stream of actual WAN internet connectivity changes.
  Stream<bool> get connectivityStream {
    return _connectivity.onConnectivityChanged.asyncMap((results) async {
      final hasNetwork = results.contains(ConnectivityResult.mobile) ||
          results.contains(ConnectivityResult.wifi) ||
          results.contains(ConnectivityResult.ethernet);

      if (!hasNetwork) return false;

      return await hasInternetReachability();
    });
  }
}
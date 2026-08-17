import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

class TileCacheService {
  /// Returns the local file for a tile.
  static Future<File> _tileFile({
    required int zoom,
    required int x,
    required int y,
  }) async {
    final dir = await getApplicationDocumentsDirectory();

    return File('${dir.path}/tiles/$zoom/$x/$y.png');
  }

  /// Returns true if the tile already exists.
  static Future<bool> tileExists({
    required int zoom,
    required int x,
    required int y,
  }) async {
    final file = await _tileFile(zoom: zoom, x: x, y: y);

    return file.exists();
  }

  /// Returns the tile file if it exists.
  static Future<File?> getTile({
    required int zoom,
    required int x,
    required int y,
  }) async {
    final file = await _tileFile(zoom: zoom, x: x, y: y);

    if (await file.exists()) {
      return file;
    }

    return null;
  }

  /// Downloads and caches a tile.
  /// Downloads and caches a tile.
  static Future<void> downloadTile({
    required int zoom,
    required int x,
    required int y,
  }) async {
    if (await tileExists(zoom: zoom, x: x, y: y)) {
      return;
    }

    final url = 'https://tile.openstreetmap.org/$zoom/$x/$y.png';
    const headers = {
      'User-Agent': 'LivestockTracker/1.0 (ACEM student project)',
    };

    // Retry up to 3 times with exponential backoff.
    for (int attempt = 0; attempt < 3; attempt++) {
      try {
        final response = await http.get(Uri.parse(url), headers: headers);

        if (response.statusCode == 200) {
          final file = await _tileFile(zoom: zoom, x: x, y: y);
          await file.parent.create(recursive: true);
          await file.writeAsBytes(response.bodyBytes);
          return;
        }

        if (response.statusCode == 429) {
          // Rate limited — wait before retrying.
          await Future.delayed(Duration(seconds: (attempt + 1) * 2));
          continue;
        }

        // Other non-200 — don't retry.
        return;
      } catch (_) {
        // Network error — wait then retry.
        await Future.delayed(Duration(seconds: attempt + 1));
      }
    }
  }

  /// Returns the application's tile directory.
  /// Returns the root tile directory path.
  static Future<String> getTileDirectoryPath() async {
    final dir = await getApplicationDocumentsDirectory();
    return '${dir.path}/tiles';
  }

  /// Downloads all tiles within a selected area for a range of zoom levels.
}

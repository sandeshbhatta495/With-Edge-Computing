import 'package:flutter_map/flutter_map.dart';
import '../models/download_progress.dart';
import 'tile_cache_service.dart';
import 'tile_calculator.dart';

class MapDownloadService {
  bool _isCancelled = false;
  bool get isCancelled => _isCancelled;

  void cancelDownload() {
    _isCancelled = true;
  }

  void resetCancellation() {
    _isCancelled = false;
  }

  Future<void> downloadArea({
    required LatLngBounds bounds,
    required int minZoom,
    required int maxZoom,
    void Function(DownloadProgress progress)? onProgress,
  }) async {
    resetCancellation();

    // -------- PASS 1: Collect all tiles to download --------
    final List<({int zoom, int x, int y})> allTiles = [];

    for (int zoom = minZoom; zoom <= maxZoom; zoom++) {
      final minX = TileCalculator.longitudeToTileX(bounds.west, zoom);
      final maxX = TileCalculator.longitudeToTileX(bounds.east, zoom);
      final minY = TileCalculator.latitudeToTileY(bounds.north, zoom);
      final maxY = TileCalculator.latitudeToTileY(bounds.south, zoom);

      for (int x = minX; x <= maxX; x++) {
        for (int y = minY; y <= maxY; y++) {
          allTiles.add((zoom: zoom, x: x, y: y));
        }
      }
    }

    final totalTiles = allTiles.length;
    int downloadedTiles = 0;

    // -------- PASS 2: Download with controlled concurrency --------
    const int concurrency = 4;
    int index = 0;

    Future<void> worker() async {
      while (true) {
        if (_isCancelled) return;

        final int current;
        current = index++;
        if (current >= allTiles.length) return;

        final tile = allTiles[current];

        if (!await TileCacheService.tileExists(
          zoom: tile.zoom,
          x: tile.x,
          y: tile.y,
        )) {
          await TileCacheService.downloadTile(
            zoom: tile.zoom,
            x: tile.x,
            y: tile.y,
          );
        }

        downloadedTiles++;
        onProgress?.call(
          DownloadProgress(
            downloadedTiles: downloadedTiles,
            totalTiles: totalTiles,
            currentZoom: tile.zoom,
          ),
        );
      }
    }

    await Future.wait(List.generate(concurrency, (_) => worker()));
  }
}

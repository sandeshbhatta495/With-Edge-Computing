class DownloadProgress {
  final int downloadedTiles;
  final int totalTiles;
  final int currentZoom;
  bool get isCompleted => downloadedTiles >= totalTiles;
  String get percentageText =>
    '${(percentage * 100).toStringAsFixed(0)}%';

  const DownloadProgress({
    required this.downloadedTiles,
    required this.totalTiles,
    required this.currentZoom,
  });

  double get percentage {
    if (totalTiles == 0) return 0;
    return downloadedTiles / totalTiles;
  }
}
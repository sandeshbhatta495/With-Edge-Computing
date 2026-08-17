import 'dart:math';

class TileCalculator {

  static int longitudeToTileX(
      double longitude,
      int zoom,
      ) {

    return ((longitude + 180.0) / 360.0 * pow(2, zoom)).floor();
  }

  static int latitudeToTileY(
      double latitude,
      int zoom,
      ) {

    final latRad = latitude * pi / 180;

    return ((1 -
            log(
              tan(latRad) +
                  1 / cos(latRad),
            ) /
                pi) /
            2 *
            pow(2, zoom))
        .floor();
  }
}
import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

class MeasureCalculator {
  static double distanceMeters(List<LatLng> points) {
    if (points.length < 2) return 0;

    final distance = Distance();
    var totalMeters = 0.0;
    for (var index = 1; index < points.length; index++) {
      totalMeters += distance.as(
        LengthUnit.Meter,
        points[index - 1],
        points[index],
      );
    }
    return totalMeters;
  }

  static double areaSquareMeters(List<LatLng> points) {
    if (points.length < 3) return 0;

    const earthRadiusMeters = 6371008.8;
    var total = 0.0;
    for (var index = 0; index < points.length; index++) {
      final current = points[index];
      final next = points[(index + 1) % points.length];
      final currentLatitude = current.latitude * math.pi / 180;
      final nextLatitude = next.latitude * math.pi / 180;
      final longitudeDelta =
          (next.longitude - current.longitude + 540) % 360 - 180;
      total +=
          longitudeDelta *
          math.pi /
          180 *
          (2 + math.sin(currentLatitude) + math.sin(nextLatitude));
    }
    return total.abs() * earthRadiusMeters * earthRadiusMeters / 2;
  }
}

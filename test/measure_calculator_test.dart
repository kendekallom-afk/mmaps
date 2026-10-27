import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:mmaps_flutter/utils/measure_calculator.dart';

void main() {
  test('calculates distance between consecutive measurement points', () {
    final meters = MeasureCalculator.distanceMeters(const [
      LatLng(0, 0),
      LatLng(0, 1),
      LatLng(1, 1),
    ]);

    expect(meters, closeTo(222390, 1000));
    expect(MeasureCalculator.distanceMeters(const [LatLng(0, 0)]), 0);
  });

  test(
    'calculates polygon area and returns zero for fewer than three points',
    () {
      final area = MeasureCalculator.areaSquareMeters(const [
        LatLng(0, 0),
        LatLng(0, 1),
        LatLng(1, 1),
        LatLng(1, 0),
      ]);

      expect(area, closeTo(12364000000, 100000000));
      expect(
        MeasureCalculator.areaSquareMeters(const [LatLng(0, 0), LatLng(0, 1)]),
        0,
      );
    },
  );
}

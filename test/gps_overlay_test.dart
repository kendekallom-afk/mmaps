import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mmaps_flutter/widgets/gps_overlay.dart';

void main() {
  testWidgets('long press requests turning GPS off', (tester) async {
    var longPressed = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GpsOverlay(
            onTap: () {},
            onLongPress: () => longPressed = true,
            status: 'Sinyal baik',
            accuracy: 5,
            heading: 0,
            loading: false,
          ),
        ),
      ),
    );

    await tester.longPress(find.byType(GpsOverlay));

    expect(longPressed, isTrue);
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mmaps_flutter/widgets/layer_customization_sheet.dart';

void main() {
  testWidgets('returns customized settings and zooms to the layer', (
    tester,
  ) async {
    LayerCustomizationSettings? result;
    var zoomed = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await showModalBottomSheet<LayerCustomizationSettings>(
                  context: context,
                  builder: (_) => LayerCustomizationSheet(
                    layerName: 'Test layer',
                    initialOpacity: 0.6,
                    initialShowOutline: false,
                    onZoomToLayer: () => zoomed = true,
                  ),
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('Atur Layer: Test layer'), findsOneWidget);

    await tester.tap(find.byType(SwitchListTile));
    tester
        .widget<Slider>(find.byKey(const ValueKey('layer-opacity-slider')))
        .onChanged!(0.35);
    await tester.pump();
    await tester.tap(find.text('Zoom ke Layer'));
    await tester.pumpAndSettle();

    expect(zoomed, isTrue);
    expect(result?.opacity, 0.35);
    expect(result?.showOutline, isTrue);
  });
}

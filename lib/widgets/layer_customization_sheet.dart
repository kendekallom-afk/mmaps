import 'package:flutter/material.dart';

typedef LayerCustomizationSettings = ({double opacity, bool showOutline});

class LayerCustomizationSheet extends StatefulWidget {
  final String layerName;
  final double initialOpacity;
  final bool initialShowOutline;
  final VoidCallback onZoomToLayer;

  const LayerCustomizationSheet({
    super.key,
    required this.layerName,
    required this.initialOpacity,
    required this.initialShowOutline,
    required this.onZoomToLayer,
  });

  @override
  State<LayerCustomizationSheet> createState() =>
      _LayerCustomizationSheetState();
}

class _LayerCustomizationSheetState extends State<LayerCustomizationSheet> {
  late double _opacity = widget.initialOpacity.clamp(0, 1).toDouble();
  late bool _showOutline = widget.initialShowOutline;
  bool _allowPop = false;

  LayerCustomizationSettings get _settings =>
      (opacity: _opacity, showOutline: _showOutline);

  void _popWithSettings() {
    setState(() => _allowPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop(_settings);
    });
  }

  @override
  Widget build(BuildContext context) {
    return PopScope<LayerCustomizationSettings>(
      canPop: _allowPop,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop || _allowPop) return;
        setState(() => _allowPop = true);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) Navigator.of(context).pop(_settings);
        });
      },
      child: SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.only(
            left: 20,
            top: 16,
            right: 20,
            bottom: MediaQuery.viewInsetsOf(context).bottom + 20,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Atur Layer: ${widget.layerName}',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  const Text('Opacity'),
                  Expanded(
                    child: Slider(
                      key: const ValueKey('layer-opacity-slider'),
                      value: _opacity,
                      min: 0,
                      max: 1,
                      divisions: 100,
                      label: '${(_opacity * 100).round()}%',
                      onChanged: (value) => setState(() => _opacity = value),
                    ),
                  ),
                  SizedBox(
                    width: 42,
                    child: Text('${(_opacity * 100).round()}%'),
                  ),
                ],
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Tampilkan Outline'),
                value: _showOutline,
                onChanged: (value) => setState(() => _showOutline = value),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: () {
                  widget.onZoomToLayer();
                  _popWithSettings();
                },
                icon: const Icon(Icons.zoom_in_map),
                label: const Text('Zoom ke Layer'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

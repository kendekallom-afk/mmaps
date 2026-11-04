import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import 'map_overlay_manifest.dart';

class ImportedMap {
  final String id;
  final String name;
  final String fileName;
  final List<MapPointFeature> points;
  final List<MapLineFeature> lines;
  final List<MapPolygonFeature> polygons;
  final List<MapRasterOverlay> overlays;
  bool isActive;

  ImportedMap({
    required this.id,
    required this.name,
    required this.fileName,
    required this.points,
    required this.lines,
    required this.polygons,
    required this.overlays,
    this.isActive = false,
  });

  List<LatLng> get allCoordinates => [
    ...points.map((feature) => feature.point),
    ...lines.expand((feature) => feature.points),
    ...polygons.expand((feature) => feature.points),
    ...overlays.expand(
      (overlay) => [overlay.bounds.northWest, overlay.bounds.southEast],
    ),
  ];

  LatLngBounds? get bounds {
    final coordinates = allCoordinates;
    if (coordinates.isEmpty) return null;
    return LatLngBounds.fromPoints(coordinates);
  }
}

class MapPointFeature {
  final String name;
  final LatLng point;
  final double? altitude;
  final Color color;

  const MapPointFeature({
    required this.name,
    required this.point,
    this.altitude,
    required this.color,
  });
}

class MapLineFeature {
  final String name;
  final List<LatLng> points;
  final List<double?> altitudes;
  final Color color;
  final double width;

  const MapLineFeature({
    required this.name,
    required this.points,
    this.altitudes = const [],
    required this.color,
    this.width = 3,
  });
}

class MapPolygonFeature {
  final String name;
  final List<LatLng> points;
  final List<double?> altitudes;
  final List<List<LatLng>> holes;
  final List<List<double?>> holeAltitudes;
  final Color fillColor;
  final Color borderColor;

  const MapPolygonFeature({
    required this.name,
    required this.points,
    this.altitudes = const [],
    required this.holes,
    this.holeAltitudes = const [],
    required this.fillColor,
    required this.borderColor,
  });
}

class MapRasterOverlay {
  final String name;
  final Uint8List bytes;
  final LatLngBounds bounds;
  final MapOverlayBounds? sourceBounds;

  const MapRasterOverlay({
    required this.name,
    required this.bytes,
    required this.bounds,
    this.sourceBounds,
  });
}

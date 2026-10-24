import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:maplibre_gl/maplibre_gl.dart' as ml;

import '../models/imported_map.dart';
import '../models/waypoint.dart';
import '../services/database_helper.dart';
import '../services/kml_import_service.dart';
import '../services/map_file_store.dart';
import '../utils/geojson_helper.dart';
import '../views/layers_view.dart';
import '../widgets/active_layers_overlay.dart';
import '../widgets/crosshair.dart';
import '../widgets/gps_overlay.dart';
import '../widgets/map_attribution.dart';
import '../widgets/opacity_control.dart';
import '../widgets/tools_popup.dart';
import '../widgets/waypoint_form_sheet.dart';

class MapHomePage extends StatefulWidget {
  final bool loadSavedLibrary;

  const MapHomePage({super.key, this.loadSavedLibrary = true});

  @override
  State<MapHomePage> createState() => _MapHomePageState();
}

class _MapHomePageState extends State<MapHomePage> {
  // Controller MapLibre & status pemuatan
  ml.MapLibreMapController? _mapController;
  bool _isStyleLoaded = false;
  bool _layersInitialized = false;

  final KmlImportService _kmlImportService = KmlImportService();
  StreamSubscription<Position>? _positionSubscription;
  StreamSubscription<CompassEvent>? _compassSubscription;

  // Konstanta ID Source dan Layer KML
  static const String _polySourceId = 'kml-polygons-source';
  static const String _polyFillLayerId = 'kml-polygons-fill';
  static const String _polyOutlineLayerId = 'kml-polygons-outline';

  static const String _lineSourceId = 'kml-lines-source';
  static const String _lineLayerId = 'kml-lines-layer';

  static const String _pointSourceId = 'kml-points-source';
  static const String _pointCircleLayerId = 'kml-points-circle';

  // Konstanta ID Source dan Layer Waypoint
  static const String _waypointSourceId = 'waypoints-source';
  static const String _waypointCircleLayerId = 'waypoints-circle-layer';
  
  // Konstanta ID Source dan Layer Puck (Lokasi Pengguna)
  static const String _puckSourceId = 'user-puck-source';
  static const String _puckLayerId = 'user-puck-layer';

  // State peta
  LatLng _center = const LatLng(-2.67, 118.89);
  double _zoom = 12;
  Position? _gpsPosition;
  double? _compassHeading;
  String _gpsStatus = 'GPS mati';
  bool _gpsBusy = false;
  bool _gpsActive = false;
  List<ImportedMap> _importedMaps = [];
  bool _loadingMaps = true;
  bool _importingMap = false;

  // State waypoints
  List<Waypoint> _waypoints = [];
  Waypoint? _selectedWaypoint;
  Offset? _tooltipPosition;

  // State mode
  bool _showToolsPopup = false;
  bool _showOpacityPanel = false;
  bool _showLayersView = false;
  int _selectedLibraryTab = 0;
  double _opacity = 100;

  @override
  void initState() {
    super.initState();
    if (widget.loadSavedLibrary) {
      unawaited(_loadMapLibrary());
    } else {
      _loadingMaps = false;
    }
    // Muat waypoints dari database saat app dibuka
    unawaited(_loadWaypoints());
    if (!kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS)) {
      _compassSubscription = FlutterCompass.events?.listen(
        (event) {
          if (!mounted) return;
          setState(() => _compassHeading = event.heading);
          _updateUserPuck();
        },
        onError: (Object error) {
          if (!mounted) return;
          setState(() => _compassHeading = null);
        },
      );
    }
  }

  @override
  void dispose() {
    unawaited(_positionSubscription?.cancel());
    unawaited(_compassSubscription?.cancel());
    _mapController?.dispose();
    super.dispose();
  }

  // ==========================================
  // SIKLUS HIDUP MAPLIBRE SOURCES & STYLE LAYERS
  // ==========================================

  void _onMapCreated(ml.MapLibreMapController controller) {
    _mapController = controller;
  }

  /// Dipanggil otomatis setelah style JSON selesai dimuat oleh engine MapLibre
  void _onStyleLoaded() async {
    _isStyleLoaded = true;
    _layersInitialized = false;

    // 1. Sinkronisasi layer KML
    await _syncMapLayers();

    // 2. Update posisi puck
    _updateUserPuck();

    // 3. Tambahkan gambar puck
    try {
      final ByteData data = await rootBundle.load(
        'assets/images/location_puck.png',
      );
      final Uint8List bytes = data.buffer.asUint8List();
      await _mapController!.addImage('puck-icon', bytes);
    } catch (e) {
      debugPrint('Image puck-icon gagal dimuat atau sudah ada: $e');
    }

    // 4. Tambahkan source dan layer puck
    try {
      await _mapController!.addGeoJsonSource(_puckSourceId, {
        "type": "FeatureCollection",
        "features": [],
      });
      await _mapController!.addSymbolLayer(
        _puckSourceId,
        _puckLayerId,
        const ml.SymbolLayerProperties(
          iconImage: 'puck-icon',
          iconSize: 0.5,
          iconRotate: ['get', 'heading'],
          iconAllowOverlap: true,
          iconIgnorePlacement: true,
        ),
      );
    } catch (e) {
      debugPrint('Gagal menambahkan layer puck: $e');
    }

    // 5. Tambahkan source dan layer untuk waypoints
    try {
      await _mapController!.addGeoJsonSource(
        _waypointSourceId,
        _buildWaypointsGeoJson([]),
      );
      // Circle merah bertepi putih sebagai marker waypoint
      await _mapController!.addCircleLayer(
        _waypointSourceId,
        _waypointCircleLayerId,
        const ml.CircleLayerProperties(
          circleColor: '#FF4444',
          circleRadius: 8,
          circleOpacity: 0.9,
          circleStrokeColor: '#FFFFFF',
          circleStrokeWidth: 2.0,
        ),
      );
    } catch (e) {
      debugPrint('Gagal menambahkan layer waypoints: $e');
    }

    // 6. Render waypoints yang sudah ada ke peta
    if (_waypoints.isNotEmpty) {
      await _updateWaypointsOnMap();
    }

    // 7. Fit kamera ke peta yang aktif
    final activeMaps = _importedMaps.where((map) => map.isActive);
    if (!_showLayersView && activeMaps.isNotEmpty) {
      _fitMapToImportedMaps(activeMaps);
    }
  }

  void _zoomToLayerByName(String layerName) {
    for (final map in _importedMaps) {
      if (map.isActive && map.name == layerName) {
        _fitMapToImportedMap(map);
        return;
      }
    }
  }

  /// Menambahkan atau memperbarui GeoJSON sources & style layers di MapLibre
  Future<void> _syncMapLayers() async {
    if (!_isStyleLoaded || _mapController == null) return;

    final activeMaps = _importedMaps.where((map) => map.isActive).toList();
    final geoJsonData = GeoJsonHelper.fromImportedMaps(activeMaps);

    try {
      if (!_layersInitialized) {
        // 1. Daftarkan GeoJSON Sources
        await _mapController!.addGeoJsonSource(
          _polySourceId,
          geoJsonData.polygons,
        );
        await _mapController!.addGeoJsonSource(
          _lineSourceId,
          geoJsonData.lines,
        );
        await _mapController!.addGeoJsonSource(
          _pointSourceId,
          geoJsonData.points,
        );

        // 2. Tambahkan Fill Layer untuk interior poligon
        await _mapController!.addFillLayer(
          _polySourceId,
          _polyFillLayerId,
          const ml.FillLayerProperties(
            fillColor: ['get', 'fillColor'],
            fillOpacity: ['get', 'fillOpacity'],
          ),
        );

        // 3. Tambahkan Line Layer untuk garis batas poligon
        await _mapController!.addLineLayer(
          _polySourceId,
          _polyOutlineLayerId,
          const ml.LineLayerProperties(
            lineColor: ['get', 'borderColor'],
            lineWidth: ['get', 'borderWidth'],
          ),
        );

        // 4. Tambahkan Line Layer untuk polyline
        await _mapController!.addLineLayer(
          _lineSourceId,
          _lineLayerId,
          const ml.LineLayerProperties(
            lineColor: ['get', 'color'],
            lineWidth: ['get', 'width'],
            lineOpacity: ['get', 'opacity'],
            lineCap: 'round',
            lineJoin: 'round',
          ),
        );

        // 5. Tambahkan Circle Layer untuk titik (Marker)
        await _mapController!.addCircleLayer(
          _pointSourceId,
          _pointCircleLayerId,
          const ml.CircleLayerProperties(
            circleColor: ['get', 'color'],
            circleRadius: ['get', 'radius'],
            circleOpacity: ['get', 'opacity'],
            circleStrokeColor: '#FFFFFF',
            circleStrokeWidth: 1.5,
          ),
        );

        _layersInitialized = true;
      } else {
        // Jika layer sudah ada, perbarui data GeoJSON secara instan
        await _mapController!.setGeoJsonSource(
          _polySourceId,
          geoJsonData.polygons,
        );
        await _mapController!.setGeoJsonSource(
          _lineSourceId,
          geoJsonData.lines,
        );
        await _mapController!.setGeoJsonSource(
          _pointSourceId,
          geoJsonData.points,
        );
      }
    } catch (e) {
      debugPrint('Error updating map layers: $e');
    }
  }

  // ==========================================
  // PEMBARUAN LOKASI & PUCK
  // ==========================================

  void _updateGpsPosition(Position position) {
    if (!mounted) return;
    setState(() {
      _gpsPosition = position;
      _gpsActive = true;
      _gpsStatus = _gpsQuality(position.accuracy);
    });
    _updateUserPuck();
  }

  void _updateUserPuck() {
    if (_mapController == null || !_isStyleLoaded || _gpsPosition == null) {
      return;
    }

    final lat = _gpsPosition!.latitude;
    final lon = _gpsPosition!.longitude;
    final heading = _compassHeading ?? 0.0;

    try {
      _mapController!.setGeoJsonSource(_puckSourceId, {
        "type": "FeatureCollection",
        "features": [
          {
            "type": "Feature",
            "geometry": {
              "type": "Point",
              "coordinates": [lon, lat], // Urutan GeoJSON: lon, lat
            },
            "properties": {"heading": heading},
          },
        ],
      });
    } catch (e) {
      debugPrint('Gagal memperbarui puck: $e');
    }
  }

  // ==========================================
  // PELACAKAN KAMERA (IDLE LISTENER)
  // ==========================================

  void _onCameraIdle() {
    final camera = _mapController?.cameraPosition;
    if (camera == null) return;

    final newCenter = LatLng(camera.target.latitude, camera.target.longitude);
    final newZoom = camera.zoom;

    if (_center.latitude != newCenter.latitude ||
        _center.longitude != newCenter.longitude ||
        _zoom != newZoom) {
      setState(() {
        _center = newCenter;
        _zoom = newZoom;
      });
    }
    unawaited(_updateSelectedWaypointPosition());
  }

  // ==========================================
  // BUILD METHOD
  // ==========================================

  @override
  Widget build(BuildContext context) {
    final activeMaps = _importedMaps.where((map) => map.isActive).toList();
    return Scaffold(
      extendBodyBehindAppBar: !_showLayersView,
      // ===== TOOLBAR ATAS =====
      appBar: AppBar(
        backgroundColor: Colors.black.withValues(alpha: 0.65),
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        foregroundColor: Colors.white,
        automaticallyImplyLeading: false,
        titleSpacing: 0,
        title: Row(
          children: [
            _toolButton(
              icon: Icons.my_location,
              tooltip: 'Pusatkan GPS',
              color: _gpsActive ? Colors.lightBlueAccent : null,
              onPressed: _centerOnGps,
            ),
            _toolButton(
              icon: Icons.add_location_alt_outlined,
              tooltip: 'Tambah Titik',
              onPressed: _onAddWaypointPressed,
            ),
            Expanded(
              child: Center(
                child: Text(
                  'Lat: ${_center.latitude.toStringAsFixed(6)}\n'
                  'Lon: ${_center.longitude.toStringAsFixed(6)}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 13,
                    height: 1.3,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
            _toolButton(
              icon: Icons.edit_location_alt_outlined,
              tooltip: 'Kelola Titik',
              onPressed: () {
                // TODO: goToPointsView()
              },
            ),
            _toolButton(
              icon: Icons.layers_outlined,
              tooltip: 'Tampilan Layers',
              color: _showLayersView ? Colors.white : Colors.white70,
              onPressed: () => setState(() {
                _showLayersView = true;
                _showToolsPopup = false;
              }),
            ),
            _toolButton(
              icon: Icons.map_outlined,
              tooltip: 'Tampilan Peta',
              color: _showLayersView ? Colors.white70 : Colors.white,
              onPressed: () => setState(() {
                _showLayersView = false;
                _showToolsPopup = false;
              }),
            ),
            // btn-tools + popup
            Stack(
              children: [
                _toolButton(
                  icon: Icons.build_outlined,
                  tooltip: 'Menu Alat',
                  onPressed: () {
                    setState(() => _showToolsPopup = !_showToolsPopup);
                  },
                ),
              ],
            ),
          ],
        ),
      ),

      // ===== MAP VIEW =====
      body: _showLayersView
          ? LayersView(
              selectedTab: _selectedLibraryTab,
              onTabChanged: (tab) => setState(() => _selectedLibraryTab = tab),
              maps: _importedMaps,
              onImportMap: _importMap,
              onToggleMap: _toggleMapActive,
              onRemoveMap: _removeMap,
              importing: _importingMap,
              loading: _loadingMaps,
            )
          : Stack(
              children: [
                // 1) Peta MapLibre GL
                ml.MapLibreMap(
                  styleString: '''{
                   "version": 8,
                     "sources": {
                       "google_sat": {
                          "type": "raster",
                             "tiles": ["https://mt3.google.com/vt/lyrs=s&hl=en&x={x}&y={y}&z={z}"],
                           "tileSize": 256
                          }
                     },
                      "layers": [
                          {
                             "id": "google_sat_layer",
                             "type": "raster",
                             "source": "google_sat"
                          }
                      ]
                  }''',
                  initialCameraPosition: ml.CameraPosition(
                    target: ml.LatLng(_center.latitude, _center.longitude),
                    zoom: _zoom,
                  ),
                  trackCameraPosition: true,
                  myLocationEnabled: false,
                  myLocationTrackingMode: ml.MyLocationTrackingMode.none,
                  myLocationRenderMode: ml.MyLocationRenderMode.normal,
                  onMapCreated: _onMapCreated,
                  onStyleLoadedCallback: _onStyleLoaded,
                  onCameraIdle: _onCameraIdle,

                  // PERBAIKAN 1: Aktifkan agar onMapClick terpicu saat klik marker
                  featureTapsTriggersMapClick: true,

                  onMapClick: (point, coordinates) {
                    unawaited(_handleWaypointMapClick(point));
                  },
                ),

                // 2) Crosshair di tengah
                const IgnorePointer(child: Center(child: Crosshair())),

                if (_selectedWaypoint != null && _tooltipPosition != null)
                  Positioned.fill(
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        const tooltipHeight = 44.0;
                        final tooltipWidth = math.min(
                          220.0,
                          constraints.maxWidth - 16,
                        );
                        final left = (_tooltipPosition!.dx - tooltipWidth / 2)
                            .clamp(
                              8.0,
                              constraints.maxWidth - tooltipWidth - 8,
                            );
                        final top = (_tooltipPosition!.dy - tooltipHeight - 8)
                            .clamp(
                              8.0,
                              constraints.maxHeight - tooltipHeight - 8,
                            );
                        final waypoint = _selectedWaypoint!;

                        return Stack(
                          children: [
                            Positioned(
                              left: left,
                              top: top,
                              width: tooltipWidth,
                              height: tooltipHeight,
                              child: Material(
                                color: Colors.transparent,
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(10),
                                  onTap: () => _showWaypointForm(
                                    initialLat: waypoint.latitude,
                                    initialLng: waypoint.longitude,
                                    initialWaypoint: waypoint,
                                  ),
                                  child: Container(
                                    alignment: Alignment.center,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 8,
                                    ),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF1E1E2E),
                                      borderRadius: BorderRadius.circular(10),
                                      border: Border.all(
                                        color: Colors.amber,
                                        width: 1.2,
                                      ),
                                      boxShadow: const [
                                        BoxShadow(
                                          color: Colors.black54,
                                          blurRadius: 8,
                                          offset: Offset(0, 3),
                                        ),
                                      ],
                                    ),
                                    child: Text(
                                      waypoint.name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      textAlign: TextAlign.center,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ),

                // 3) GPS overlay (kanan bawah)
                Positioned(
                  right: 12,
                  bottom: 12,
                  child: GpsOverlay(
                    onTap: _centerOnGps,
                    status: _gpsStatus,
                    accuracy: _gpsPosition?.accuracy,
                    heading: _compassHeading,
                    loading: _gpsBusy,
                  ),
                ),

                // 4) Active layers overlay (kiri atas)
                Positioned(
                  left: 12,
                  top: MediaQuery.of(context).padding.top + kToolbarHeight + 8,
                  child: ActiveLayersOverlay(
                    layers: activeMaps.map((map) => map.name).toList(),
                    onLayerTap: _zoomToLayerByName,
                  ),
                ),

                // 5) Opacity control (kanan bawah atas GPS)
                Positioned(
                  right: 12,
                  bottom: 56,
                  child: OpacityControl(
                    expanded: _showOpacityPanel,
                    value: _opacity,
                    onToggle: () =>
                        setState(() => _showOpacityPanel = !_showOpacityPanel),
                    onChanged: (v) => setState(() => _opacity = v),
                  ),
                ),

                const Positioned(left: 8, bottom: 4, child: MapAttribution()),

                if (_showToolsPopup)
                  Positioned(
                    top: 8,
                    right: 8,
                    child: ToolsPopup(
                      onClose: () => setState(() => _showToolsPopup = false),
                      onFindByCoordinate: _closeToolsPopup,
                      onRecordTrack: _closeToolsPopup,
                      onMeasure: _closeToolsPopup,
                      onMapFeatures: _closeToolsPopup,
                      onSettings: _closeToolsPopup,
                    ),
                  ),
              ],
            ),
    );
  }

  // Tombol toolbar seragam
  Widget _toolButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
    Color? color,
  }) {
    return SizedBox(
      width: 38,
      height: 48,
      child: IconButton(
        icon: Icon(icon, color: color),
        tooltip: tooltip,
        onPressed: onPressed,
        iconSize: 21,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(width: 38, height: 48),
        visualDensity: VisualDensity.compact,
      ),
    );
  }

  void _closeToolsPopup() {
    setState(() => _showToolsPopup = false);
  }

  // ==========================================
  // WAYPOINT METHODS
  // ==========================================

  Future<void> _loadWaypoints() async {
    try {
      final waypoints = await DatabaseHelper.instance.getAllWaypoints();
      if (!mounted) return;
      setState(() => _waypoints = waypoints);
      if (_isStyleLoaded) {
        await _updateWaypointsOnMap();
      }
    } catch (e) {
      debugPrint('Gagal memuat waypoints: $e');
    }
  }

  Future<void> _onAddWaypointPressed() async {
    final camera = _mapController?.cameraPosition;
    if (camera == null) {
      _showMapMessage('Peta belum siap. Coba lagi sebentar.');
      return;
    }

    final lat = camera.target.latitude;
    final lng = camera.target.longitude;

    await _showWaypointForm(initialLat: lat, initialLng: lng);
  }

  Future<void> _handleWaypointMapClick(math.Point<double> point) async {
    final controller = _mapController;
    if (controller == null || !_isStyleLoaded) return;

    try {
      // PERBAIKAN: Gunakan argumen posisi (bukan named parameter)
      final features = await controller.queryRenderedFeatures(
        point,
        [_waypointCircleLayerId], // layerIds (posisi ke-2)
        null, // filter (posisi ke-3)
      );
      if (!mounted) return;

      Waypoint? waypointAtTap;
      for (final feature in features) {
        if (feature is! Map) continue;
        final properties = feature['properties'];
        if (properties is! Map) continue;

        final waypointId = properties['id']?.toString();
        if (waypointId == null) continue;

        Waypoint? waypoint;
        for (final candidate in _waypoints) {
          if (candidate.id == waypointId) {
            waypoint = candidate;
            break;
          }
        }

        if (waypoint != null) {
          waypointAtTap = waypoint;
          break;
        }
      }

      if (waypointAtTap == null) {
        setState(() {
          _selectedWaypoint = null;
          _tooltipPosition = null;
        });
        return;
      }

      final screenLocation = await controller.toScreenLocation(
        ml.LatLng(waypointAtTap.latitude, waypointAtTap.longitude),
      );
      if (!mounted) return;
      setState(() {
        _selectedWaypoint = waypointAtTap;
        _tooltipPosition = Offset(
          screenLocation.x.toDouble(),
          screenLocation.y.toDouble(),
        );
      });
    } catch (error) {
      debugPrint('Gagal memilih waypoint di peta: $error');
      if (mounted) {
        _showMapMessage('Tidak dapat membuka waypoint: $error');
      }
    }
  }

  Future<void> _updateSelectedWaypointPosition() async {
    final waypointId = _selectedWaypoint?.id;
    final controller = _mapController;
    if (waypointId == null || controller == null || !_isStyleLoaded) return;

    Waypoint? waypoint;
    for (final current in _waypoints) {
      if (current.id == waypointId) {
        waypoint = current;
        break;
      }
    }
    if (waypoint == null) {
      if (mounted) {
        setState(() {
          _selectedWaypoint = null;
          _tooltipPosition = null;
        });
      }
      return;
    }

    try {
      final screenLocation = await controller.toScreenLocation(
        ml.LatLng(waypoint.latitude, waypoint.longitude),
      );
      if (!mounted || _selectedWaypoint?.id != waypoint.id) return;
      setState(() {
        _selectedWaypoint = waypoint;
        _tooltipPosition = Offset(
          screenLocation.x.toDouble(),
          screenLocation.y.toDouble(),
        );
      });
    } catch (error) {
      debugPrint('Gagal memperbarui posisi tooltip waypoint: $error');
      if (mounted) {
        setState(() {
          _selectedWaypoint = null;
          _tooltipPosition = null;
        });
      }
    }
  }

  Future<void> _showWaypointForm({
    required double initialLat,
    required double initialLng,
    Waypoint? initialWaypoint,
  }) async {
    if (!mounted) return;

    final result = await WaypointFormSheet.show(
      context,
      initialLat: initialLat,
      initialLng: initialLng,
      initialWaypoint: initialWaypoint,
    );
    if (result == null || !mounted) return;

    try {
      if (result case WaypointSaved(:final waypoint)) {
        if (initialWaypoint == null) {
          await DatabaseHelper.instance.insertWaypoint(waypoint);
          if (!mounted) return;
          setState(() => _waypoints = [..._waypoints, waypoint]);
          _showMapMessage('"${waypoint.name}" berhasil disimpan.');
        } else {
          await DatabaseHelper.instance.updateWaypoint(waypoint);
          if (!mounted) return;
          setState(() {
            _waypoints = _waypoints
                .map(
                  (current) => current.id == waypoint.id ? waypoint : current,
                )
                .toList();
          });
          _showMapMessage('"${waypoint.name}" berhasil diperbarui.');
        }
      } else if (result case WaypointDeleted(:final waypointId)) {
        await DatabaseHelper.instance.deleteWaypoint(waypointId);
        String? photoCleanupError;
        final photoPath = initialWaypoint?.photoPath;
        if (photoPath != null) {
          try {
            final photoFile = File(photoPath);
            if (await photoFile.exists()) await photoFile.delete();
          } catch (error) {
            photoCleanupError = '$error';
          }
        }
        if (!mounted) return;
        setState(() {
          _waypoints = _waypoints
              .where((waypoint) => waypoint.id != waypointId)
              .toList();
        });
        _showMapMessage(
          photoCleanupError == null
              ? 'Waypoint berhasil dihapus.'
              : 'Waypoint dihapus, tetapi foto gagal dihapus: '
                    '$photoCleanupError',
        );
      }
      await _updateWaypointsOnMap();
    } catch (error) {
      if (mounted) {
        _showMapMessage('Gagal menyimpan perubahan waypoint: $error');
      }
    }
  }

  Future<void> _updateWaypointsOnMap() async {
    if (!_isStyleLoaded || _mapController == null) return;
    try {
      await _mapController!.setGeoJsonSource(
        _waypointSourceId,
        _buildWaypointsGeoJson(_waypoints),
      );
      await _updateSelectedWaypointPosition();
    } catch (e) {
      debugPrint('Gagal memperbarui waypoints di peta: $e');
    }
  }

  Map<String, dynamic> _buildWaypointsGeoJson(List<Waypoint> waypoints) {
    return {
      'type': 'FeatureCollection',
      'features': waypoints
          .map(
            (w) => {
              'type': 'Feature',
              'geometry': {
                'type': 'Point',
                'coordinates': [w.longitude, w.latitude], // GeoJSON: [lon, lat]
              },
              'properties': {
                'id': w.id,
                'name': w.name,
                'description': w.description,
              },
            },
          )
          .toList(),
    };
  }

  Future<void> _loadMapLibrary() async {
    try {
      final storedFiles = await MapFileStore.listStoredMapFiles();
      final activeIds = await MapFileStore.loadActiveIds();
      final maps = <ImportedMap>[];
      final failedFiles = <String>[];

      for (final fileInfo in storedFiles) {
        final isActive = activeIds.contains(fileInfo.id);
        if (isActive) {
          try {
            final bytes = await MapFileStore.readStoredMapFile(fileInfo.id);
            final map = _kmlImportService.parse(
              id: fileInfo.id,
              fileName: fileInfo.name,
              bytes: bytes,
            );
            map.isActive = true;
            maps.add(map);
          } catch (error) {
            failedFiles.add(fileInfo.name);
          }
        } else {
          maps.add(
            ImportedMap(
              id: fileInfo.id,
              name: _cleanMapName(fileInfo.name),
              fileName: fileInfo.name,
              points: const [],
              lines: const [],
              polygons: const [],
              overlays: const [],
              isActive: false,
            ),
          );
        }
      }

      if (!mounted) return;
      setState(() {
        _importedMaps = maps;
        _loadingMaps = false;
      });

      if (_isStyleLoaded) {
        await _syncMapLayers();
      }

      final activeMaps = maps.where((map) => map.isActive);
      if (!_showLayersView && activeMaps.isNotEmpty) {
        await WidgetsBinding.instance.endOfFrame;
        if (mounted) _fitMapToImportedMaps(activeMaps);
      }
      if (failedFiles.isNotEmpty) {
        _showMapMessage(
          'Gagal memuat ${failedFiles.length} file: ${failedFiles.join(', ')}.',
        );
      }
    } catch (error) {
      if (!mounted) return;
      setState(() => _loadingMaps = false);
      _showMapMessage('Tidak dapat memuat Maps Library: $error');
    }
  }

  String _cleanMapName(String fileName) {
    return fileName.replaceAll(
      RegExp(r'\.(kml|kmz)$', caseSensitive: false),
      '',
    );
  }

  Future<void> _importMap() async {
    if (_importingMap) return;
    setState(() => _importingMap = true);

    try {
      final file = await FilePicker.pickFile(
        dialogTitle: 'Import peta KML atau KMZ',
        type: FileType.custom,
        allowedExtensions: const ['kml', 'kmz'],
      );
      if (file == null) return;

      final fileSize = await file.length();
      if (fileSize != null && fileSize > 500 * 1024 * 1024) {
        throw const FormatException('Ukuran file melebihi batas 500 MB.');
      }
      final bytes = await file.readAsBytes();
      final id = DateTime.now().microsecondsSinceEpoch.toString();
      final map = _kmlImportService.parse(
        id: id,
        fileName: file.name,
        bytes: bytes,
      );

      await MapFileStore.save(
        StoredMapFile(id: id, name: file.name, bytes: bytes),
      );
      if (!mounted) return;
      setState(() => _importedMaps = [..._importedMaps, map]);
      _showMapMessage('${map.name} berhasil ditambahkan ke Maps Library.');

      if (_isStyleLoaded) {
        await _syncMapLayers();
      }
    } catch (error) {
      if (mounted) _showMapMessage('Gagal mengimpor peta: $error');
    } finally {
      if (mounted) setState(() => _importingMap = false);
    }
  }

  Future<void> _toggleMapActive(ImportedMap map) async {
    final activate = !map.isActive;
    ImportedMap targetMap = map;

    if (activate) {
      final isLazyPlaceholder =
          map.points.isEmpty &&
          map.lines.isEmpty &&
          map.polygons.isEmpty &&
          map.overlays.isEmpty;

      if (isLazyPlaceholder) {
        try {
          final bytes = await MapFileStore.readStoredMapFile(map.id);
          targetMap = _kmlImportService.parse(
            id: map.id,
            fileName: map.fileName,
            bytes: bytes,
          );
        } catch (error) {
          if (mounted) {
            _showMapMessage('Gagal membaca/parse file ${map.fileName}: $error');
          }
          return;
        }
      }
    }

    targetMap.isActive = activate;

    final index = _importedMaps.indexWhere((item) => item.id == map.id);
    if (index != -1) {
      _importedMaps[index] = targetMap;
    }

    setState(() {});

    try {
      final activeIds = _importedMaps
          .where((item) => item.isActive)
          .map((item) => item.id)
          .toSet();
      await MapFileStore.saveActiveIds(activeIds);
    } catch (error) {
      if (mounted) {
        _showMapMessage(
          'Layer berubah untuk sesi ini, tetapi statusnya tidak dapat disimpan: $error',
        );
      }
    }

    if (_isStyleLoaded) {
      await _syncMapLayers();
    }

    if (!activate || !mounted) return;
    setState(() {
      _showLayersView = false;
      _showToolsPopup = false;
    });
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    _fitMapToImportedMap(targetMap);
  }

  Future<void> _removeMap(ImportedMap map) async {
    try {
      await MapFileStore.remove(map.id);
      if (!mounted) return;
      setState(() => _importedMaps.removeWhere((item) => item.id == map.id));
      _showMapMessage('${map.name} dihapus dari Maps Library.');

      if (_isStyleLoaded) {
        await _syncMapLayers();
      }
    } catch (error) {
      if (mounted) _showMapMessage('Gagal menghapus peta: $error');
    }
  }

  void _fitMapToImportedMap(ImportedMap map) {
    _fitMapToImportedMaps([map]);
  }

  void _fitMapToImportedMaps(Iterable<ImportedMap> maps) {
    final coordinates = maps.expand((map) => map.allCoordinates).toList();
    if (coordinates.isEmpty || _mapController == null) return;

    double minLat = coordinates.first.latitude;
    double maxLat = coordinates.first.latitude;
    double minLon = coordinates.first.longitude;
    double maxLon = coordinates.first.longitude;

    for (final c in coordinates) {
      if (c.latitude < minLat) minLat = c.latitude;
      if (c.latitude > maxLat) maxLat = c.latitude;
      if (c.longitude < minLon) minLon = c.longitude;
      if (c.longitude > maxLon) maxLon = c.longitude;
    }

    if (minLat == maxLat && minLon == maxLon) {
      _mapController?.animateCamera(
        ml.CameraUpdate.newLatLngZoom(
          ml.LatLng(minLat, minLon),
          math.max(_zoom, 16),
        ),
      );
      return;
    }

    _mapController?.animateCamera(
      ml.CameraUpdate.newLatLngBounds(
        ml.LatLngBounds(
          southwest: ml.LatLng(minLat, minLon),
          northeast: ml.LatLng(maxLat, maxLon),
        ),
        left: 48,
        top: 48,
        right: 48,
        bottom: 48,
      ),
    );
  }

  void _showMapMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _centerOnGps() async {
    if (_gpsBusy) return;

    final currentPosition = _gpsPosition;
    if (_gpsActive && currentPosition != null) {
      if (_showLayersView) {
        setState(() {
          _showLayersView = false;
          _showToolsPopup = false;
        });
        await WidgetsBinding.instance.endOfFrame;
        if (!mounted) return;
      }
      _moveMapToGpsPosition(currentPosition);
      return;
    }

    setState(() {
      _gpsBusy = true;
      _gpsStatus = 'Mencari sinyal';
    });

    try {
      if (_showLayersView) {
        setState(() {
          _showLayersView = false;
          _showToolsPopup = false;
        });
        await WidgetsBinding.instance.endOfFrame;
        if (!mounted) return;
      }

      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        _showGpsMessage('Aktifkan layanan lokasi/GPS pada perangkat.');
        setState(() => _gpsStatus = 'GPS nonaktif');
        return;
      }

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied) {
        _showGpsMessage('Izin lokasi ditolak.');
        setState(() => _gpsStatus = 'Izin ditolak');
        return;
      }
      if (permission == LocationPermission.deniedForever) {
        _showGpsMessage(
          'Izin lokasi ditolak permanen. Aktifkan melalui pengaturan aplikasi.',
        );
        setState(() => _gpsStatus = 'Izin ditolak');
        return;
      }

      setState(() {
        _gpsActive = true;
        _gpsStatus = 'Mencari sinyal';
      });
      _positionSubscription ??=
          Geolocator.getPositionStream(
            locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.bestForNavigation,
              distanceFilter: 3,
            ),
          ).listen(
            _updateGpsPosition,
            onError: (Object error) {
              if (!mounted) return;
              setState(() => _gpsStatus = 'GPS bermasalah');
              _showGpsMessage('Gagal menerima pembaruan lokasi: $error');
            },
          );

      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.bestForNavigation,
          timeLimit: Duration(seconds: 15),
        ),
      );
      _updateGpsPosition(position);
      _moveMapToGpsPosition(position);
    } on TimeoutException {
      if (mounted) {
        setState(() => _gpsStatus = 'Menunggu sinyal');
        _showGpsMessage(
          'Lokasi belum tersedia. Coba lagi di area dengan pandangan langit terbuka.',
        );
      }
    } on LocationServiceDisabledException {
      if (mounted) {
        setState(() => _gpsStatus = 'GPS nonaktif');
        _showGpsMessage('Aktifkan layanan lokasi/GPS pada perangkat.');
      }
    } on PermissionDeniedException {
      if (mounted) {
        setState(() => _gpsStatus = 'Izin ditolak');
        _showGpsMessage('Aplikasi tidak mendapat izin untuk mengakses lokasi.');
      }
    } catch (error) {
      if (mounted) {
        setState(() => _gpsStatus = 'GPS bermasalah');
        _showGpsMessage('Tidak dapat membaca lokasi: $error');
      }
    } finally {
      if (mounted) setState(() => _gpsBusy = false);
    }
  }

  void _moveMapToGpsPosition(Position position) {
    final target = ml.LatLng(position.latitude, position.longitude);
    final targetZoom = math.max(_zoom, 15.0);
    _mapController?.animateCamera(
      ml.CameraUpdate.newLatLngZoom(target, targetZoom),
    );
  }

  String _gpsQuality(double accuracy) {
    if (accuracy <= 10) return 'Sinyal kuat';
    if (accuracy <= 25) return 'Sinyal baik';
    if (accuracy <= 50) return 'Sinyal sedang';
    return 'Sinyal lemah';
  }

  void _showGpsMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}

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

import '../models/basemap.dart';
import '../models/imported_map.dart';
import '../models/waypoint.dart';
import '../services/database_helper.dart';
import '../services/kml_import_service.dart';
import '../services/map_file_store.dart';
import '../utils/geojson_helper.dart';
import '../views/layers_view.dart';
import '../widgets/active_layers_overlay.dart';
import '../widgets/crosshair.dart';
import '../widgets/custom_xyz_tiles_sheet.dart';
import '../widgets/gps_overlay.dart';
import '../widgets/map_attribution.dart';
import '../widgets/opacity_control.dart';
import '../widgets/tools_popup.dart';
import '../widgets/waypoint_form_sheet.dart';

class MapHomePage extends StatefulWidget {
  final bool loadSavedLibrary;
  final bool useMapLibre;

  const MapHomePage({
    super.key,
    this.loadSavedLibrary = true,
    this.useMapLibre = true,
  });

  @override
  State<MapHomePage> createState() => _MapHomePageState();
}

class _MapHomePageState extends State<MapHomePage> with WidgetsBindingObserver {
  static const int _maxImportBytes = 100 * 1024 * 1024;

  // Controller MapLibre & status pemuatan
  ml.MapLibreMapController? _mapController;
  bool _isStyleLoaded = false;
  bool _layersInitialized = false;
  Future<void> _syncQueue = Future<void>.value();

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
  bool _resumeGpsOnForeground = false;
  List<ImportedMap> _importedMaps = [];
  List<Basemap> _customBasemaps = [];
  bool _loadingMaps = true;
  bool _importingMap = false;
  final Set<String> _busyMapIds = {};

  // State waypoints
  List<Waypoint> _waypoints = [];
  Waypoint? _selectedWaypoint;
  Offset? _tooltipPosition;

  // State mode
  bool _showToolsPopup = false;
  bool _showOpacityPanel = false;
  bool _showLayersView = false;
  int _selectedLibraryTab = 0;
  Basemap? _activeBasemap;
  double _opacity = 100;
  Timer? _opacityUpdateTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.loadSavedLibrary) {
      unawaited(_loadMapLibrary());
    } else {
      _loadingMaps = false;
    }
    // Muat waypoints dari database saat app dibuka
    unawaited(_loadWaypoints());
    unawaited(_loadCustomBasemaps());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_positionSubscription?.cancel());
    unawaited(_compassSubscription?.cancel());
    _positionSubscription = null;
    _compassSubscription = null;
    _opacityUpdateTimer?.cancel();
    _mapController?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _resumeGpsOnForeground = _gpsActive;
      unawaited(_cancelGpsStreams());
    } else if (state == AppLifecycleState.resumed) {
      final shouldResume = _resumeGpsOnForeground && _gpsActive;
      _resumeGpsOnForeground = false;
      if (shouldResume) {
        _startPositionSubscription();
        _startCompassSubscription();
      }
    }
  }

  Future<void> _cancelGpsStreams() async {
    final positionSubscription = _positionSubscription;
    final compassSubscription = _compassSubscription;
    _positionSubscription = null;
    _compassSubscription = null;

    for (final subscription in [positionSubscription, compassSubscription]) {
      if (subscription == null) continue;
      try {
        await subscription.cancel();
      } catch (error) {
        debugPrint('Gagal menghentikan stream GPS/kompas: $error');
      }
    }
  }

  void _startPositionSubscription() {
    if (_positionSubscription != null) return;
    _positionSubscription =
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
  }

  void _startCompassSubscription() {
    if (kIsWeb ||
        _compassSubscription != null ||
        (defaultTargetPlatform != TargetPlatform.android &&
            defaultTargetPlatform != TargetPlatform.iOS)) {
      return;
    }

    _compassSubscription = FlutterCompass.events?.listen(
      (event) {
        if (!mounted) return;
        setState(() => _compassHeading = event.heading);
        unawaited(_updateUserPuck());
      },
      onError: (Object error) {
        if (!mounted) return;
        setState(() => _compassHeading = null);
      },
    );
  }

  Future<void> _stopGps() async {
    if (!_gpsActive && _positionSubscription == null) return;

    setState(() {
      _gpsActive = false;
      _gpsPosition = null;
      _compassHeading = null;
      _gpsStatus = 'GPS mati';
    });
    _resumeGpsOnForeground = false;
    await _cancelGpsStreams();

    final controller = _mapController;
    if (controller == null || !_isStyleLoaded) return;
    try {
      await controller.setGeoJsonSource(_puckSourceId, {
        'type': 'FeatureCollection',
        'features': [],
      });
    } catch (error) {
      debugPrint('Gagal menghapus puck GPS dari peta: $error');
    }
  }

  // ==========================================
  // SIKLUS HIDUP MAPLIBRE SOURCES & STYLE LAYERS
  // ==========================================

  void _onMapCreated(ml.MapLibreMapController controller) {
    _mapController = controller;
    _isStyleLoaded = false;
    _layersInitialized = false;
    _syncQueue = Future<void>.value();
  }

  /// Dipanggil otomatis setelah style JSON selesai dimuat oleh engine MapLibre
  void _onStyleLoaded() async {
    _isStyleLoaded = true;
    _layersInitialized = false;

    // 1. Sinkronisasi layer KML
    await _syncMapLayers();
    await _applyKmlLayerOpacity();

    // 2. Tambahkan gambar puck
    try {
      final ByteData data = await rootBundle.load(
        'assets/images/location_puck.png',
      );
      final Uint8List bytes = data.buffer.asUint8List();
      await _mapController!.addImage('puck-icon', bytes);
    } catch (e) {
      debugPrint('Image puck-icon gagal dimuat atau sudah ada: $e');
    }

    // 3. Tambahkan source dan layer puck
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

    // 4. Update posisi puck setelah sourcenya tersedia.
    await _updateUserPuck();

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
  Future<void> _syncMapLayers() {
    final sync = _syncQueue.then((_) => _syncMapLayersImpl());
    _syncQueue = sync.catchError((Object error, StackTrace stackTrace) {
      debugPrint('Error updating map layers: $error\n$stackTrace');
    });
    return _syncQueue;
  }

  Future<void> _syncMapLayersImpl() async {
    final controller = _mapController;
    if (!_isStyleLoaded || controller == null) return;

    bool isCurrentController() =>
        identical(_mapController, controller) && _isStyleLoaded;

    final activeMaps = _importedMaps.where((map) => map.isActive).toList();
    final geoJsonData = GeoJsonHelper.fromImportedMaps(activeMaps);

    try {
      if (!_layersInitialized) {
        // 1. Daftarkan GeoJSON Sources
        await controller.addGeoJsonSource(_polySourceId, geoJsonData.polygons);
        if (!isCurrentController()) return;
        await controller.addGeoJsonSource(_lineSourceId, geoJsonData.lines);
        if (!isCurrentController()) return;
        await controller.addGeoJsonSource(_pointSourceId, geoJsonData.points);
        if (!isCurrentController()) return;

        // 2. Tambahkan Fill Layer untuk interior poligon
        await controller.addFillLayer(
          _polySourceId,
          _polyFillLayerId,
          ml.FillLayerProperties(
            fillColor: ['get', 'fillColor'],
            fillOpacity: [
              '*',
              [
                'coalesce',
                ['get', 'fillOpacity'],
                1,
              ],
              _opacity / 100,
            ],
          ),
        );
        if (!isCurrentController()) return;

        // 3. Tambahkan Line Layer untuk garis batas poligon
        await controller.addLineLayer(
          _polySourceId,
          _polyOutlineLayerId,
          ml.LineLayerProperties(
            lineColor: ['get', 'borderColor'],
            lineWidth: ['get', 'borderWidth'],
            lineOpacity: [
              '*',
              [
                'coalesce',
                ['get', 'borderOpacity'],
                1,
              ],
              _opacity / 100,
            ],
          ),
        );
        if (!isCurrentController()) return;

        // 4. Tambahkan Line Layer untuk polyline
        await controller.addLineLayer(
          _lineSourceId,
          _lineLayerId,
          ml.LineLayerProperties(
            lineColor: ['get', 'color'],
            lineWidth: ['get', 'width'],
            lineOpacity: [
              '*',
              [
                'coalesce',
                ['get', 'opacity'],
                1,
              ],
              _opacity / 100,
            ],
            lineCap: 'round',
            lineJoin: 'round',
          ),
        );
        if (!isCurrentController()) return;

        // 5. Tambahkan Circle Layer untuk titik (Marker)
        await controller.addCircleLayer(
          _pointSourceId,
          _pointCircleLayerId,
          ml.CircleLayerProperties(
            circleColor: ['get', 'color'],
            circleRadius: ['get', 'radius'],
            circleOpacity: [
              '*',
              [
                'coalesce',
                ['get', 'opacity'],
                1,
              ],
              _opacity / 100,
            ],
            circleStrokeColor: '#FFFFFF',
            circleStrokeWidth: 1.5,
            circleStrokeOpacity: _opacity / 100,
          ),
        );
        if (!isCurrentController()) return;

        _layersInitialized = true;
      } else {
        // Jika layer sudah ada, perbarui data GeoJSON secara instan
        await controller.setGeoJsonSource(_polySourceId, geoJsonData.polygons);
        if (!isCurrentController()) return;
        await controller.setGeoJsonSource(_lineSourceId, geoJsonData.lines);
        if (!isCurrentController()) return;
        await controller.setGeoJsonSource(_pointSourceId, geoJsonData.points);
      }
    } catch (e) {
      debugPrint('Error updating map layers: $e');
    }
  }

  Future<void> _applyKmlLayerOpacity() async {
    final controller = _mapController;
    if (!_isStyleLoaded || !_layersInitialized || controller == null) return;

    final factor = _opacity / 100;
    try {
      await controller.setLayerProperties(
        _polyFillLayerId,
        ml.FillLayerProperties(
          fillColor: ['get', 'fillColor'],
          fillOpacity: [
            '*',
            [
              'coalesce',
              ['get', 'fillOpacity'],
              1,
            ],
            factor,
          ],
        ),
      );
      if (!identical(_mapController, controller) || !_isStyleLoaded) return;
      await controller.setLayerProperties(
        _polyOutlineLayerId,
        ml.LineLayerProperties(
          lineColor: ['get', 'borderColor'],
          lineWidth: ['get', 'borderWidth'],
          lineOpacity: [
            '*',
            [
              'coalesce',
              ['get', 'borderOpacity'],
              1,
            ],
            factor,
          ],
        ),
      );
      if (!identical(_mapController, controller) || !_isStyleLoaded) return;
      await controller.setLayerProperties(
        _lineLayerId,
        ml.LineLayerProperties(
          lineColor: ['get', 'color'],
          lineWidth: ['get', 'width'],
          lineOpacity: [
            '*',
            [
              'coalesce',
              ['get', 'opacity'],
              1,
            ],
            factor,
          ],
          lineCap: 'round',
          lineJoin: 'round',
        ),
      );
      if (!identical(_mapController, controller) || !_isStyleLoaded) return;
      await controller.setLayerProperties(
        _pointCircleLayerId,
        ml.CircleLayerProperties(
          circleColor: ['get', 'color'],
          circleRadius: ['get', 'radius'],
          circleOpacity: [
            '*',
            [
              'coalesce',
              ['get', 'opacity'],
              1,
            ],
            factor,
          ],
          circleStrokeColor: '#FFFFFF',
          circleStrokeWidth: 1.5,
          circleStrokeOpacity: factor,
        ),
      );
    } catch (error) {
      debugPrint('Gagal memperbarui transparansi layer peta: $error');
    }
  }

  void _scheduleKmlLayerOpacityUpdate(double value) {
    setState(() => _opacity = value);
    _opacityUpdateTimer?.cancel();
    _opacityUpdateTimer = Timer(
      const Duration(milliseconds: 80),
      () => unawaited(_applyKmlLayerOpacity()),
    );
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
    unawaited(_updateUserPuck());
  }

  Future<void> _updateUserPuck() async {
    if (_mapController == null || !_isStyleLoaded || _gpsPosition == null) {
      return;
    }

    final lat = _gpsPosition!.latitude;
    final lon = _gpsPosition!.longitude;
    final heading = _compassHeading ?? 0.0;

    try {
      await _mapController!.setGeoJsonSource(_puckSourceId, {
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
      body: Stack(
        children: [
          Positioned.fill(
            child: Offstage(
              offstage: _showLayersView,
              child: Stack(
                children: [
                  // 1) Peta MapLibre GL
                  if (widget.useMapLibre)
                    ml.MapLibreMap(
                      key: ValueKey(_activeBasemap),
                      styleString:
                          _activeBasemap?.styleString ??
                          '{"version":8,"sources":{},"layers":[]}',
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

                      // Aktifkan klik peta ketika marker ditekan.
                      featureTapsTriggersMapClick: true,

                      onMapClick: (point, coordinates) {
                        unawaited(_handleWaypointMapClick(point));
                      },
                    )
                  else
                    const ColoredBox(
                      key: ValueKey('map-test-placeholder'),
                      color: Colors.black12,
                      child: SizedBox.expand(),
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
                      onLongPress: _stopGps,
                      status: _gpsStatus,
                      accuracy: _gpsPosition?.accuracy,
                      heading: _compassHeading,
                      loading: _gpsBusy,
                    ),
                  ),

                  // 4) Active layers overlay (kiri atas)
                  Positioned(
                    left: 12,
                    top:
                        MediaQuery.of(context).padding.top + kToolbarHeight + 8,
                    child: ActiveLayersOverlay(
                      layers: [
                        ...activeMaps.map((map) => map.name),
                        if (_activeBasemap != null) _activeBasemap!.label,
                      ],
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
                      onToggle: () => setState(
                        () => _showOpacityPanel = !_showOpacityPanel,
                      ),
                      onChanged: _scheduleKmlLayerOpacityUpdate,
                    ),
                  ),

                  Positioned(
                    left: 8,
                    bottom: 4,
                    child: MapAttribution(
                      attribution: _activeBasemap?.attribution,
                    ),
                  ),

                  if (_showToolsPopup)
                    Positioned(
                      top:
                          MediaQuery.of(context).padding.top +
                          kToolbarHeight +
                          8,
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
            ),
          ),
          if (_showLayersView)
            Positioned.fill(
              child: LayersView(
                selectedTab: _selectedLibraryTab,
                onTabChanged: (tab) =>
                    setState(() => _selectedLibraryTab = tab),
                maps: _importedMaps,
                customBasemaps: _customBasemaps,
                activeBasemap: _activeBasemap,
                onBasemapChanged: (basemap) =>
                    setState(() => _activeBasemap = basemap),
                onAddCustomBasemap: _addCustomBasemap,
                onImportMap: _importMap,
                onToggleMap: _toggleMapActive,
                onRemoveMap: _removeMap,
                importing: _importingMap,
                loading: _loadingMaps,
                busyMapIds: _busyMapIds,
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

  Future<void> _loadCustomBasemaps() async {
    try {
      final basemaps = await DatabaseHelper.instance.getCustomBasemaps();
      if (!mounted) return;
      setState(() {
        final loadedIds = basemaps.map((basemap) => basemap.id).toSet();
        _customBasemaps = [
          ...basemaps,
          ..._customBasemaps.where(
            (basemap) => !loadedIds.contains(basemap.id),
          ),
        ];
      });
    } catch (error) {
      if (mounted) {
        _showMapMessage('Tidak dapat memuat custom XYZ tiles: $error');
      }
    }
  }

  Future<void> _addCustomBasemap() async {
    final basemap = await showCustomXyzTilesSheet(context);
    if (basemap == null || !mounted) return;

    try {
      await DatabaseHelper.instance.saveCustomBasemap(basemap);
      if (!mounted) return;
      setState(() => _customBasemaps = [..._customBasemaps, basemap]);
      _showMapMessage('${basemap.name} ditambahkan ke daftar Basemap.');
    } catch (error) {
      if (mounted) {
        _showMapMessage('Gagal menyimpan custom XYZ tiles: $error');
      }
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
      if (result is WaypointSaved) {
        final waypoint = result.waypoint;

        if (initialWaypoint == null) {
          // --- MODE TAMBAH BARU ---
          await DatabaseHelper.instance.insertWaypoint(waypoint);
          if (!mounted) return;

          setState(() {
            _waypoints = [..._waypoints, waypoint];
          });
          _showMapMessage('"${waypoint.name}" berhasil disimpan.');
        } else {
          // --- MODE EDIT / PERBARUI ---
          // 1. Simpan ke database
          await DatabaseHelper.instance.updateWaypoint(waypoint);
          if (!mounted) return;

          // 2. Perbarui state list _waypoints agar foto baru ikut tersimpan di memori
          setState(() {
            _waypoints = _waypoints.map((current) {
              if (current.id == waypoint.id) {
                return waypoint; // Ganti dengan objek waypoint yang baru (berisi foto terbaru)
              }
              return current;
            }).toList();
          });
          _showMapMessage('"${waypoint.name}" berhasil diperbarui.');
        }
      } else if (result is WaypointDeleted) {
        final waypointId = result.waypointId;

        // --- MODE HAPUS ---
        await DatabaseHelper.instance.deleteWaypoint(waypointId);

        // Hapus file foto fisik dari memori HP
        final photoPaths = initialWaypoint?.photoPaths ?? [];
        for (final path in photoPaths) {
          try {
            final photoFile = File(path);
            if (await photoFile.exists()) await photoFile.delete();
          } catch (e) {
            debugPrint('Gagal menghapus file foto: $e');
          }
        }

        if (!mounted) return;
        setState(() {
          _waypoints = _waypoints
              .where((waypoint) => waypoint.id != waypointId)
              .toList();
        });
        _showMapMessage('Waypoint berhasil dihapus.');
      }

      // 3. Selalu perbarui peta setelah ada perubahan (tambah/edit/hapus)
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
            final map = await compute(parseKmlInBackground, (
              id: fileInfo.id,
              fileName: fileInfo.name,
              bytes: bytes,
            ));
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
      if (fileSize != null && fileSize > _maxImportBytes) {
        throw const FormatException(
          'Ukuran file melebihi batas 100 MB. Pilih file KML/KMZ yang lebih kecil.',
        );
      }
      final bytes = await file.readAsBytes();
      final id = DateTime.now().microsecondsSinceEpoch.toString();
      final map = await compute(parseKmlInBackground, (
        id: id,
        fileName: file.name,
        bytes: bytes,
      ));

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
    if (_busyMapIds.contains(map.id)) return;
    final activate = !map.isActive;
    ImportedMap targetMap = activate
        ? map
        : ImportedMap(
            id: map.id,
            name: map.name,
            fileName: map.fileName,
            points: const [],
            lines: const [],
            polygons: const [],
            overlays: const [],
          );

    if (activate) {
      final isLazyPlaceholder =
          map.points.isEmpty &&
          map.lines.isEmpty &&
          map.polygons.isEmpty &&
          map.overlays.isEmpty;

      if (isLazyPlaceholder) {
        setState(() => _busyMapIds.add(map.id));
        try {
          final bytes = await MapFileStore.readStoredMapFile(map.id);
          targetMap = await compute(parseKmlInBackground, (
            id: map.id,
            fileName: map.fileName,
            bytes: bytes,
          ));
        } catch (error) {
          if (mounted) {
            _showMapMessage('Gagal membaca/parse file ${map.fileName}: $error');
          }
          return;
        } finally {
          if (mounted) setState(() => _busyMapIds.remove(map.id));
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
      _startPositionSubscription();
      _startCompassSubscription();

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

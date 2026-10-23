import 'dart:async';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:maplibre_gl/maplibre_gl.dart' as ml;

import '../models/imported_map.dart';
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

  // Konstanta ID Source dan Layer
  static const String _polySourceId = 'kml-polygons-source';
  static const String _polyFillLayerId = 'kml-polygons-fill';
  static const String _polyOutlineLayerId = 'kml-polygons-outline';

  static const String _lineSourceId = 'kml-lines-source';
  static const String _lineLayerId = 'kml-lines-layer';

  static const String _pointSourceId = 'kml-points-source';
  static const String _pointCircleLayerId = 'kml-points-circle';

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

  // State mode
  bool _showToolsPopup = false;
  bool _showOpacityPanel = false;
  bool _addingWaypoint = false;
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
    if (!kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS)) {
      _compassSubscription = FlutterCompass.events?.listen(
        (event) {
          if (!mounted) return;
          setState(() => _compassHeading = event.heading);
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

  /// Dipanggil otomatis setelah style JSON (misal demotiles) selesai dimuat oleh engine MapLibre
  void _onStyleLoaded() async {
    _isStyleLoaded = true;
    _layersInitialized = false; // Reset status saat style di-reload
    await _syncMapLayers();

    final activeMaps = _importedMaps.where((map) => map.isActive);
    if (!_showLayersView && activeMaps.isNotEmpty) {
      _fitMapToImportedMaps(activeMaps);
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

        // 2. Tambahkan Fill Layer untuk interior poligon (Data-Driven Styling)
        await _mapController!.addFillLayer(
          _polySourceId,
          _polyFillLayerId,
          const ml.FillLayerProperties(
            fillColor: ['get', 'fillColor'],
            fillOpacity: ['get', 'fillOpacity'],
          ),
        );

        // 2b. Tambahkan Line Layer untuk garis batas poligon
        await _mapController!.addLineLayer(
          _polySourceId,
          _polyOutlineLayerId,
          const ml.LineLayerProperties(
            lineColor: ['get', 'borderColor'],
            lineWidth: ['get', 'borderWidth'],
          ),
        );

        // 3. Tambahkan Line Layer untuk polyline
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

        // 4. Tambahkan Circle Layer untuk titik (Marker)
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
  // PELACAKAN KAMERA (IDLE LISTENER)
  // ==========================================

  void _onCameraIdle() {
    final camera = _mapController?.cameraPosition;
    if (camera == null) return;

    final newCenter = LatLng(camera.target.latitude, camera.target.longitude);
    final newZoom = camera.zoom;

    // Hanya pemicu setState saat kamera berhenti bergerak (bebas frame drop)
    if (_center.latitude != newCenter.latitude ||
        _center.longitude != newCenter.longitude ||
        _zoom != newZoom) {
      setState(() {
        _center = newCenter;
        _zoom = newZoom;
      });
    }
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
              color: _addingWaypoint ? Colors.amber : null,
              onPressed: () {
                setState(() => _addingWaypoint = !_addingWaypoint);
              },
            ),
            Expanded(
              child: Center(
                child: Text(
                  'Lat: ${_center.latitude.toStringAsFixed(6)}\n'
                  'Lon: ${_center.longitude.toStringAsFixed(6)}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 10,
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
                  styleString: 'https://demotiles.maplibre.org/style.json',
                  initialCameraPosition: ml.CameraPosition(
                    target: ml.LatLng(_center.latitude, _center.longitude),
                    zoom: _zoom,
                  ),
                  trackCameraPosition: true,
                  myLocationEnabled: _gpsActive,
                  myLocationTrackingMode: ml.MyLocationTrackingMode.none,
                  myLocationRenderMode: ml.MyLocationRenderMode.compass,
                  onMapCreated: _onMapCreated,
                  onStyleLoadedCallback: _onStyleLoaded,
                  onCameraIdle: _onCameraIdle,
                  onMapClick: (point, coordinates) {
                    setState(() {
                      _addingWaypoint = false;
                    });
                    // TODO: kalau mode "tambah titik" aktif → tambah marker
                  },
                ),

                // 2) Crosshair di tengah
                const IgnorePointer(child: Center(child: Crosshair())),

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
                  top: 12,
                  child: ActiveLayersOverlay(
                    layers: activeMaps.map((map) => map.name).toList(),
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

  Future<void> _loadMapLibrary() async {
    try {
      final storedFiles = await MapFileStore.load();
      final activeIds = await MapFileStore.loadActiveIds();
      final maps = <ImportedMap>[];
      final failedFiles = <String>[];

      for (final file in storedFiles) {
        try {
          final map = _kmlImportService.parse(
            id: file.id,
            fileName: file.name,
            bytes: file.bytes,
          );
          map.isActive = activeIds.contains(map.id);
          maps.add(map);
        } catch (error) {
          failedFiles.add(file.name);
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
    setState(() => map.isActive = activate);

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
    _fitMapToImportedMap(map);
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
      _positionSubscription ??= Geolocator.getPositionStream(
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

  void _updateGpsPosition(Position position) {
    if (!mounted) return;
    setState(() {
      _gpsPosition = position;
      _gpsActive = true;
      _gpsStatus = _gpsQuality(position.accuracy);
    });
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

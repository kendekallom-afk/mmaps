import 'dart:async';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../models/imported_map.dart';
import '../services/kml_import_service.dart';
import '../services/map_file_store.dart';
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
  final MapController _mapController = MapController();
  final KmlImportService _kmlImportService = KmlImportService();
  StreamSubscription<Position>? _positionSubscription;
  StreamSubscription<CompassEvent>? _compassSubscription;

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
    super.dispose();
  }

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
                // 1) Peta
                FlutterMap(
                  mapController: _mapController,
                  options: MapOptions(
                    initialCenter: _center,
                    initialZoom: _zoom,
                    onTap: (tapPosition, point) {
                      setState(() {
                        _addingWaypoint = false;
                      });
                      // TODO: kalau mode "tambah titik" aktif → tambah marker
                    },
                    onPositionChanged: (camera, hasGesture) {
                      if (_center != camera.center || _zoom != camera.zoom) {
                        setState(() {
                          _center = camera.center;
                          _zoom = camera.zoom;
                        });
                      }
                    },
                  ),
                  children: [
                    TileLayer(
                      urlTemplate:
                          'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                      userAgentPackageName: 'id.mmaps.app',
                    ),
                    if (activeMaps.any((map) => map.overlays.isNotEmpty))
                      OverlayImageLayer(
                        overlayImages: [
                          for (final map in activeMaps)
                            for (final overlay in map.overlays)
                              OverlayImage(
                                imageProvider: MemoryImage(overlay.bytes),
                                bounds: overlay.bounds,
                                opacity: _opacity / 100,
                              ),
                        ],
                      ),
                    if (activeMaps.any((map) => map.polygons.isNotEmpty))
                      PolygonLayer(
                        polygons: [
                          for (final map in activeMaps)
                            for (final feature in map.polygons)
                              Polygon(
                                points: feature.points,
                                holePointsList: feature.holes,
                                color: feature.fillColor,
                                borderColor: feature.borderColor,
                                borderStrokeWidth: 2,
                                label: feature.name,
                              ),
                        ],
                      ),
                    if (activeMaps.any((map) => map.lines.isNotEmpty))
                      PolylineLayer(
                        polylines: [
                          for (final map in activeMaps)
                            for (final feature in map.lines)
                              Polyline(
                                points: feature.points,
                                color: feature.color,
                                strokeWidth: feature.width,
                              ),
                        ],
                      ),
                    if (activeMaps.any((map) => map.points.isNotEmpty))
                      MarkerLayer(
                        markers: [
                          for (final map in activeMaps)
                            for (final feature in map.points)
                              Marker(
                                point: feature.point,
                                width: 34,
                                height: 40,
                                child: Tooltip(
                                  message: feature.name,
                                  child: Icon(
                                    Icons.location_on,
                                    color: feature.color,
                                    size: 34,
                                  ),
                                ),
                              ),
                        ],
                      ),
                    if (_gpsPosition != null)
                      CircleLayer(
                        circles: [
                          CircleMarker(
                            point: LatLng(
                              _gpsPosition!.latitude,
                              _gpsPosition!.longitude,
                            ),
                            radius: _gpsPosition!.accuracy,
                            useRadiusInMeter: true,
                            color: Colors.blue.withValues(alpha: 0.12),
                            borderColor: Colors.blue.withValues(alpha: 0.5),
                            borderStrokeWidth: 1,
                          ),
                        ],
                      ),
                    if (_gpsPosition != null)
                      MarkerLayer(
                        markers: [
                          Marker(
                            point: LatLng(
                              _gpsPosition!.latitude,
                              _gpsPosition!.longitude,
                            ),
                            width: 24,
                            height: 24,
                            child: const GpsPositionMarker(),
                          ),
                        ],
                      ),
                    // TODO: OverlayImageLayer (WebP georef) — nanti
                    // TODO: MarkerLayer (titik-titik) — nanti
                    // TODO: PolylineLayer / PolygonLayer (ukur) — nanti
                  ],
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

                // 6) Measure box (tengah atas, hidden dulu) — TODO saat mode ukur aktif
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
    } catch (error) {
      if (mounted) _showMapMessage('Gagal menghapus peta: $error');
    }
  }

  void _fitMapToImportedMap(ImportedMap map) {
    _fitMapToImportedMaps([map]);
  }

  void _fitMapToImportedMaps(Iterable<ImportedMap> maps) {
    final coordinates = maps.expand((map) => map.allCoordinates).toList();
    if (coordinates.isEmpty) return;
    final bounds = LatLngBounds.fromPoints(coordinates);
    if (bounds.north == bounds.south && bounds.east == bounds.west) {
      _mapController.move(bounds.center, math.max(_zoom, 16));
      return;
    }
    _mapController.fitCamera(
      CameraFit.bounds(bounds: bounds, padding: const EdgeInsets.all(48)),
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

  void _updateGpsPosition(Position position) {
    if (!mounted) return;
    setState(() {
      _gpsPosition = position;
      _gpsActive = true;
      _gpsStatus = _gpsQuality(position.accuracy);
    });
  }

  void _moveMapToGpsPosition(Position position) {
    final target = LatLng(position.latitude, position.longitude);
    final targetZoom = math.max(_zoom, 15.0);
    _mapController.move(target, targetZoom);
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

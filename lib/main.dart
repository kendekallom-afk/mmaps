import 'package:flutter/foundation.dart'; // Diperlukan untuk kIsWeb
import 'package:flutter/material.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi_web/sqflite_ffi_web.dart'; // Diperlukan untuk Web

import 'screens/map_home_page.dart';

export 'screens/map_home_page.dart';

void main() {
  // 1. Pastikan Flutter Engine siap sebelum memanggil fungsi native/database
  WidgetsFlutterBinding.ensureInitialized();

  // 2. Inisialisasi SQLite khusus untuk platform Web (Chrome)
  if (kIsWeb) {
    databaseFactory = databaseFactoryFfiWeb;
  }

  // 3. Mulai mesin MapLibre lebih awal agar peta muncul lebih cepat
  MapLibreMap.preWarm(); 

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'mMaps',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF484848)),
        useMaterial3: false,
      ),
      home: const MapHomePage(),
    );
  }
}
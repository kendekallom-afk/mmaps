import 'package:flutter/material.dart';
import 'package:maplibre_gl/maplibre_gl.dart'; // <-- Tambahkan import ini

import 'screens/map_home_page.dart';

export 'screens/map_home_page.dart';

void main() {
  // Tambahkan dua baris ini sebelum runApp
  WidgetsFlutterBinding.ensureInitialized();
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
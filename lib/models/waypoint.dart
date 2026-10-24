import 'dart:convert';

class Waypoint {
  final String id;
  final String name;
  final String description;
  final double latitude;
  final double longitude;
  final List<String> photoPaths; // Ubah dari String? menjadi List<String>
  final DateTime createdAt;

  Waypoint({
    required this.id,
    required this.name,
    required this.description,
    required this.latitude,
    required this.longitude,
    this.photoPaths = const [], // Default list kosong
    required this.createdAt,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'description': description,
      'latitude': latitude,
      'longitude': longitude,
      // Simpan list sebagai JSON string
      'photoPaths': jsonEncode(photoPaths), 
      'createdAt': createdAt.toIso8601String(),
    };
  }

  factory Waypoint.fromMap(Map<String, dynamic> map) {
    // Baca JSON string menjadi List<String>
    List<String> paths = [];
    if (map['photoPaths'] != null && map['photoPaths'].isNotEmpty) {
      try {
        final decoded = jsonDecode(map['photoPaths']);
        if (decoded is List) {
          paths = decoded.map((e) => e.toString()).toList();
        }
      } catch (e) {
        // Abaikan jika format lama (bukan JSON)
        paths = [map['photoPaths'].toString()];
      }
    }

    return Waypoint(
      id: map['id'],
      name: map['name'],
      description: map['description'] ?? '',
      latitude: map['latitude'],
      longitude: map['longitude'],
      photoPaths: paths,
      createdAt: DateTime.parse(map['createdAt']),
    );
  }

  Waypoint copyWith({
    String? name,
    String? description,
    List<String>? photoPaths,
  }) {
    return Waypoint(
      id: id,
      name: name ?? this.name,
      description: description ?? this.description,
      latitude: latitude,
      longitude: longitude,
      photoPaths: photoPaths ?? this.photoPaths,
      createdAt: createdAt,
    );
  }
}
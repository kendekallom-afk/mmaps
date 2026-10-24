import 'package:uuid/uuid.dart';

class Waypoint {
  final String id;
  final String name;
  final String description;
  final double latitude;
  final double longitude;
  final String? photoPath;
  final DateTime createdAt;

  Waypoint({
    String? id,
    required this.name,
    required this.description,
    required this.latitude,
    required this.longitude,
    this.photoPath,
    DateTime? createdAt,
  })  : id = id ?? const Uuid().v4(),
        createdAt = createdAt ?? DateTime.now();

  /// Konversi ke Map untuk disimpan ke SQLite.
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'description': description,
      'latitude': latitude,
      'longitude': longitude,
      'photoPath': photoPath,
      'createdAt': createdAt.toIso8601String(),
    };
  }

  /// Buat Waypoint dari Map yang dibaca dari SQLite.
  factory Waypoint.fromMap(Map<String, dynamic> map) {
    return Waypoint(
      id: map['id'] as String,
      name: map['name'] as String,
      description: map['description'] as String,
      latitude: map['latitude'] as double,
      longitude: map['longitude'] as double,
      photoPath: map['photoPath'] as String?,
      createdAt: DateTime.parse(map['createdAt'] as String),
    );
  }

  /// Salin Waypoint dengan field yang diubah.
  Waypoint copyWith({
    String? name,
    String? description,
    double? latitude,
    double? longitude,
    String? photoPath,
  }) {
    return Waypoint(
      id: id,
      name: name ?? this.name,
      description: description ?? this.description,
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      photoPath: photoPath ?? this.photoPath,
      createdAt: createdAt,
    );
  }

  @override
  String toString() {
    return 'Waypoint(id: $id, name: $name, lat: $latitude, lon: $longitude)';
  }
}

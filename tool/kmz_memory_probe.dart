// Probe perilaku package archive: apakah decodeBytes menginflate isi arsip,
// dan berapa memori yang dipakai di tiap tahap.
//
// Taruh di folder `tool/` proyek, lalu jalankan SATU PROSES PER FILE
// (agar ProcessInfo.maxRss tidak tercampur antar kasus):
//
//   dart run tool/kmz_memory_probe.dart kmz_cases/big_honest.kmz
//   dart run tool/kmz_memory_probe.dart kmz_cases/big_forged_header.kmz
//   dart run tool/kmz_memory_probe.dart kmz_cases/big_symlink_entry.kmz
//   dart run tool/kmz_memory_probe.dart kmz_cases/control_small.kmz
//
// Catatan: RSS di desktop hanya pendekatan. Untuk angka yang relevan,
// ulangi di Android: `adb shell dumpsys meminfo <nama.paket>` sebelum dan
// sesudah mengimpor file yang sama lewat aplikasi.
import 'dart:io';

import 'package:archive/archive.dart';

int _mb(int bytes) => bytes ~/ (1024 * 1024);

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('Pemakaian: dart run tool/kmz_memory_probe.dart <file.kmz>');
    exit(64);
  }

  final bytes = File(args.first).readAsBytesSync();
  print('File            : ${args.first} (${bytes.length ~/ 1024} KB)');
  print('RSS awal        : ${_mb(ProcessInfo.currentRss)} MB');

  // --- Tahap 1: decodeBytes ---
  final sw = Stopwatch()..start();
  Archive archive;
  try {
    archive = ZipDecoder().decodeBytes(bytes);
  } catch (e) {
    print('decodeBytes melempar: ${e.runtimeType}: $e');
    print('maxRSS          : ${_mb(ProcessInfo.maxRss)} MB');
    return;
  }
  print('Setelah decodeBytes : RSS ${_mb(ProcessInfo.currentRss)} MB, '
      'maxRSS ${_mb(ProcessInfo.maxRss)} MB, ${sw.elapsedMilliseconds} ms');

  final files = archive.files.where((f) => f.isFile).toList();
  for (final f in files) {
    print('  entri ${f.name} | ukuran deklarasi: ${f.size} byte '
        '(${_mb(f.size)} MB)');
  }

  // Jika maxRSS di tahap 1 sudah melonjak ke ordo ukuran deklarasi,
  // berarti decodeBytes ikut menginflate (mis. untuk entri symlink).

  // --- Tahap 2: readBytes ---
  final target = files.firstWhere(
    (f) => f.name.toLowerCase().endsWith('.kml'),
    orElse: () => files.first,
  );
  sw
    ..reset()
    ..start();
  try {
    final data = target.readBytes();
    print('Setelah readBytes   : RSS ${_mb(ProcessInfo.currentRss)} MB, '
        'maxRSS ${_mb(ProcessInfo.maxRss)} MB, ${sw.elapsedMilliseconds} ms, '
        'panjang hasil: ${data?.length}');
  } catch (e) {
    print('readBytes melempar  : ${e.runtimeType}: $e');
    print('maxRSS              : ${_mb(ProcessInfo.maxRss)} MB');
  }
}
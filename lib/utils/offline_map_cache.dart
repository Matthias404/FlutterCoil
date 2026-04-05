import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:path_provider/path_provider.dart';

class OfflineMapCache {
  OfflineMapCache._();

  static const String tileUrlTemplate =
      'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
  static const LatLng defaultCenter = LatLng(48.137154, 11.576124);
  static const double minRadiusKm = 1;
  static const double maxRadiusKm = 12;
  static const double defaultRadiusKm = 4;

  static double startupRadiusKm = defaultRadiusKm;

  static Directory? _cacheDirectory;

  static Future<Directory> ensureInitialized() async {
    if (_cacheDirectory != null) {
      return _cacheDirectory!;
    }

    final root = await getApplicationSupportDirectory();
    final tileDir = Directory('${root.path}/offline_tiles');
    if (!await tileDir.exists()) {
      await tileDir.create(recursive: true);
    }

    _cacheDirectory = tileDir;
    return tileDir;
  }

  static TileProvider localFirstTileProvider() {
    return _LocalFirstTileProvider();
  }

  static double normalizeRadiusKm(double value) {
    return value.clamp(minRadiusKm, maxRadiusKm).toDouble();
  }

  static Future<void> prefetchGreaterArea({
    required LatLng center,
    List<int> zoomLevels = const <int>[13, 14, 15, 16],
    double radiusKm = 4,
    void Function(int completed, int total)? onProgress,
  }) async {
    final cacheDir = await ensureInitialized();

    final jobs = <({int z, int x, int y})>[];
    for (final z in zoomLevels) {
      final min = _latLngToTile(
        center.latitude + _kmToLatDegrees(radiusKm),
        center.longitude - _kmToLonDegrees(radiusKm, center.latitude),
        z,
      );
      final max = _latLngToTile(
        center.latitude - _kmToLatDegrees(radiusKm),
        center.longitude + _kmToLonDegrees(radiusKm, center.latitude),
        z,
      );

      final minX = math.min(min.$1, max.$1);
      final maxX = math.max(min.$1, max.$1);
      final minY = math.min(min.$2, max.$2);
      final maxY = math.max(min.$2, max.$2);

      for (var x = minX; x <= maxX; x++) {
        for (var y = minY; y <= maxY; y++) {
          jobs.add((z: z, x: x, y: y));
        }
      }
    }

    var completed = 0;
    final total = jobs.length;

    final client = HttpClient();
    try {
      for (final job in jobs) {
        final file = File('${cacheDir.path}/${job.z}/${job.x}/${job.y}.png');
        if (await file.exists()) {
          completed += 1;
          onProgress?.call(completed, total);
          continue;
        }

        await file.parent.create(recursive: true);

        final url = Uri.parse(
          tileUrlTemplate
              .replaceAll('{z}', '${job.z}')
              .replaceAll('{x}', '${job.x}')
              .replaceAll('{y}', '${job.y}'),
        );

        try {
          final request = await client.getUrl(url);
          request.headers.set('User-Agent', 'lasertag_app');
          final response = await request.close();
          if (response.statusCode == 200) {
            final bytes = await consolidateHttpClientResponseBytes(response);
            await file.writeAsBytes(bytes, flush: true);
          }
        } catch (_) {
          // Continue prefetch even if some tiles fail.
        }

        completed += 1;
        onProgress?.call(completed, total);
      }
    } finally {
      client.close(force: true);
    }
  }

  static double _kmToLatDegrees(double km) => km / 110.574;

  static double _kmToLonDegrees(double km, double latitude) {
    final latRad = latitude * math.pi / 180;
    final kmPerDegree = 111.320 * math.cos(latRad);
    if (kmPerDegree.abs() < 0.0001) {
      return 0;
    }
    return km / kmPerDegree;
  }

  static (int, int) _latLngToTile(double lat, double lon, int zoom) {
    final n = math.pow(2.0, zoom).toDouble();
    final x = ((lon + 180.0) / 360.0 * n).floor();
    final latRad = lat * math.pi / 180.0;
    final y =
        ((1.0 - math.log(math.tan(latRad) + 1.0 / math.cos(latRad)) / math.pi) /
                2.0 *
                n)
            .floor();
    return (x, y);
  }
}

class _LocalFirstTileProvider extends NetworkTileProvider {
  _LocalFirstTileProvider()
    : super(headers: <String, String>{'User-Agent': 'lasertag_app'});

  @override
  ImageProvider getImageWithCancelLoadingSupport(
    TileCoordinates coordinates,
    TileLayer options,
    Future<void> cancelLoading,
  ) {
    final cacheDir = OfflineMapCache._cacheDirectory;
    if (cacheDir != null) {
      final z = coordinates.z;
      final x = coordinates.x;
      final y = options.tms ? ((1 << z) - 1) - coordinates.y : coordinates.y;
      final localFile = File('${cacheDir.path}/$z/$x/$y.png');
      if (localFile.existsSync()) {
        return FileImage(localFile);
      }
    }

    return super.getImageWithCancelLoadingSupport(
      coordinates,
      options,
      cancelLoading,
    );
  }
}

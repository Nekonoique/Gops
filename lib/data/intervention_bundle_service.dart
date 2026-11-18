import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'database.dart';

/// Creates and imports self-contained GOPS fiche files (JSON plus photographs).
class InterventionBundleService {
  InterventionBundleService._();

  static const _format = 'gops-intervention';
  static const _version = 1;
  static const _maxBundleBytes = 256 * 1024 * 1024;
  static const _qrPrefix = 'GOPSQR1:';
  // Version 40-L holds at most 2,953 bytes; leave a margin for reader reliability.
  static const _maxQrCharacters = 2800;

  static Future<Uint8List> exportBundle(
    String interventionId, {
    bool includePhotos = true,
  }) async {
    final db = GopsDatabase.instance;
    final intervention = await db.intervention(interventionId);
    if (intervention == null) {
      throw StateError('La fiche d’intervention est introuvable.');
    }

    final identities = await db.rows('identities', interventionId);
    final vehicles = await db.rows('vehicles', interventionId);
    final links = <Map<String, String>>[];
    for (final vehicle in vehicles) {
      final vehicleId = vehicle['id']! as String;
      for (final identityId in await db.vehicleIdentityIds(vehicleId)) {
        links.add({'vehicle_id': vehicleId, 'identity_id': identityId});
      }
    }

    final archive = Archive();
    final photos = <Map<String, Object?>>[];
    final sourcePhotos = includePhotos
        ? await db.photos(interventionId)
        : <Map<String, Object?>>[];
    for (var i = 0; i < sourcePhotos.length; i++) {
      final photo = sourcePhotos[i];
      final filename = 'photos/photo_${i + 1}.jpg';
      final source = File(photo['local_path']! as String);
      if (await source.exists()) {
        archive.addFile(
          ArchiveFile.bytes(filename, await source.readAsBytes()),
        );
      }
      photos.add({
        'id': photo['id'],
        'identity_id': photo['identity_id'],
        'vehicle_id': photo['vehicle_id'],
        'description': photo['description'],
        'category': photo['category'],
        'created_at': photo['created_at'],
        'file': await source.exists() ? filename : null,
      });
    }

    final manifest = <String, Object?>{
      'format': _format,
      'version': _version,
      'exported_at': DateTime.now().toIso8601String(),
      'photos_omitted': !includePhotos,
      'intervention': {
        for (final key in [
          'reference',
          'date',
          'time',
          'location',
          'nature',
          'observations',
          'report',
          'intervention_type',
          'tcpm_data',
          'created_at',
          'updated_at',
        ])
          key: intervention[key],
      },
      'identities': identities.map(_withoutInterventionId).toList(),
      'vehicles': vehicles.map(_withoutInterventionId).toList(),
      'vehicle_identities': links,
      'photos': photos,
    };
    archive.addFile(
      ArchiveFile.string(
        'fiche.json',
        const JsonEncoder.withIndent('  ').convert(manifest),
      ),
    );
    final encoded = ZipEncoder().encode(archive);
    return Uint8List.fromList(encoded);
  }

  static Future<String> exportQrPayload(String interventionId) async {
    final bundle = await exportBundle(interventionId, includePhotos: false);
    final payload = '$_qrPrefix${base64Url.encode(bundle).replaceAll('=', '')}';
    if (payload.length > _maxQrCharacters) {
      throw const FormatException(
        'Cette fiche contient trop de données pour un QR code. Utilisez l’envoi du fichier.',
      );
    }
    return payload;
  }

  static Future<String> importQrPayload(String payload) async {
    if (!payload.startsWith(_qrPrefix) || payload.length > _maxQrCharacters) {
      throw const FormatException(
        'Ce QR code n’est pas une fiche GOPS valide.',
      );
    }
    final encoded = payload.substring(_qrPrefix.length);
    final normalized = base64Url.normalize(encoded);
    final bundle = Uint8List.fromList(base64Url.decode(normalized));
    return importBundle(bundle);
  }

  static Map<String, Object?> _withoutInterventionId(
    Map<String, Object?> row,
  ) => {
    for (final entry in row.entries)
      if (entry.key != 'intervention_id') entry.key: entry.value,
  };

  static Future<String> importBundle(Uint8List bytes) async {
    if (bytes.isEmpty || bytes.length > _maxBundleBytes) {
      throw const FormatException(
        'Le fichier GOPS est vide ou trop volumineux.',
      );
    }

    final archive = ZipDecoder().decodeBytes(bytes, verify: true);
    final manifestFile = archive.findFile('fiche.json');
    if (manifestFile == null) {
      throw const FormatException('Ce fichier ne contient pas de fiche GOPS.');
    }
    if (manifestFile.size > 5 * 1024 * 1024 ||
        archive.files.fold<int>(0, (sum, file) => sum + file.size) >
            _maxBundleBytes) {
      throw const FormatException(
        'Le contenu décompressé est trop volumineux.',
      );
    }
    final manifest = jsonDecode(utf8.decode(manifestFile.readBytes()!));
    if (manifest is! Map<String, dynamic> ||
        manifest['format'] != _format ||
        manifest['version'] != _version) {
      throw const FormatException(
        'Le format de cette fiche GOPS n’est pas reconnu.',
      );
    }

    final intervention = _asMap(manifest['intervention'], 'intervention');
    final identities = _asList(manifest['identities'], 'identities');
    final vehicles = _asList(manifest['vehicles'], 'vehicles');
    final links = _asList(manifest['vehicle_identities'], 'vehicle_identities');
    final photos = _asList(manifest['photos'], 'photos');
    final now = DateTime.now();
    final newInterventionId = _newId(now);
    final identityIds = <String, String>{};
    final vehicleIds = <String, String>{};
    for (final person in identities) {
      final oldId = person['id']?.toString();
      if (oldId != null) identityIds[oldId] = _newId(now);
    }
    for (final vehicle in vehicles) {
      final oldId = vehicle['id']?.toString();
      if (oldId != null) vehicleIds[oldId] = _newId(now);
    }

    final docs = await getApplicationDocumentsDirectory();
    final photoFolder = Directory(p.join(docs.path, 'gops_photos'));
    await photoFolder.create(recursive: true);
    final preparedPhotos = <({Map<String, Object?> row, File? file})>[];
    for (final photo in photos) {
      final archiveName = photo['file']?.toString();
      File? localFile;
      if (archiveName != null && archiveName.isNotEmpty) {
        if (!archiveName.startsWith('photos/') ||
            archiveName.contains('..') ||
            archiveName.contains('\\')) {
          throw const FormatException(
            'Le fichier contient un chemin de photo invalide.',
          );
        }
        final image = archive.findFile(archiveName);
        if (image == null || image.size > 20 * 1024 * 1024) {
          throw const FormatException(
            'Une photo de la fiche est manquante ou trop volumineuse.',
          );
        }
        final localName = '${_newId(now)}.jpg';
        localFile = File(p.join(photoFolder.path, localName));
        await localFile.writeAsBytes(image.readBytes()!, flush: true);
      }
      preparedPhotos.add((row: photo, file: localFile));
    }

    final database = await GopsDatabase.instance.db;
    try {
      await database.transaction((txn) async {
        await txn.insert('interventions', {
          'id': newInterventionId,
          'reference': intervention['reference'] ?? '',
          'date': intervention['date'] ?? '',
          'time': intervention['time'] ?? '',
          'location': intervention['location'] ?? '',
          'nature': intervention['nature'] ?? '',
          'observations': intervention['observations'] ?? '',
          'report': intervention['report'] ?? '',
          'intervention_type': intervention['intervention_type'] ?? 'libre',
          'tcpm_data': intervention['tcpm_data'] ?? '{}',
          'created_at': now.toIso8601String(),
          'updated_at': now.toIso8601String(),
        });
        for (final person in identities) {
          final id = identityIds[person['id']?.toString()];
          if (id == null) continue;
          await txn.insert('identities', {
            'id': id,
            'intervention_id': newInterventionId,
            for (final key in const [
              'surname',
              'usage_name',
              'first_names',
              'birth_date',
              'birth_place',
              'nationality',
              'address',
              'postal_code',
              'city',
              'phone',
              'email',
              'role',
              'observations',
            ])
              key: person[key] ?? '',
          });
        }
        for (final vehicle in vehicles) {
          final id = vehicleIds[vehicle['id']?.toString()];
          if (id == null) continue;
          await txn.insert('vehicles', {
            'id': id,
            'intervention_id': newInterventionId,
            for (final key in const [
              'registration',
              'make',
              'model',
              'color',
              'kind',
              'country',
              'observations',
            ])
              key: vehicle[key] ?? '',
          });
        }
        for (final link in links) {
          final vehicleId = vehicleIds[link['vehicle_id']?.toString()];
          final identityId = identityIds[link['identity_id']?.toString()];
          if (vehicleId == null || identityId == null) continue;
          await txn.insert('vehicle_identities', {
            'vehicle_id': vehicleId,
            'identity_id': identityId,
          });
        }
        for (final item in preparedPhotos) {
          final row = item.row;
          await txn.insert('photos', {
            'id': _newId(now),
            'intervention_id': newInterventionId,
            'identity_id': identityIds[row['identity_id']?.toString()],
            'vehicle_id': vehicleIds[row['vehicle_id']?.toString()],
            'local_path': item.file?.path ?? '',
            'description': row['description'] ?? '',
            'category': row['category'] ?? 'intervention',
            'created_at': row['created_at'] ?? now.toIso8601String(),
          });
        }
      });
    } catch (_) {
      for (final item in preparedPhotos) {
        if (item.file != null && await item.file!.exists()) {
          await item.file!.delete();
        }
      }
      rethrow;
    }
    return newInterventionId;
  }

  static Map<String, Object?> _asMap(Object? value, String name) {
    if (value is Map<String, dynamic>) return Map<String, Object?>.from(value);
    throw FormatException('La rubrique « $name » est invalide.');
  }

  static List<Map<String, Object?>> _asList(Object? value, String name) {
    if (value is! List) {
      throw FormatException('La rubrique « $name » est invalide.');
    }
    return value.map((item) => _asMap(item, name)).toList();
  }

  static String _newId(DateTime now) =>
      '${now.microsecondsSinceEpoch}_${Random.secure().nextInt(1 << 32)}';
}

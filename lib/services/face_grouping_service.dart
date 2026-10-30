import 'dart:convert';
import 'dart:io';

import 'package:face_verification/face_verification.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/tcloud_file.dart';

class FaceGroup {
  const FaceGroup({required this.id, required this.name, required this.files});

  final String id;
  final String name;
  final List<TCloudFile> files;
}

class FaceScanResult {
  const FaceScanResult({
    required this.groups,
    required this.scannedCount,
    required this.notAvailableLocallyCount,
    required this.unmatchedCount,
  });

  final List<FaceGroup> groups;
  final int scannedCount;
  final int notAvailableLocallyCount;
  final int unmatchedCount;
}

class _FaceIndex {
  const _FaceIndex({required this.associations, required this.names});

  final Map<String, Set<String>> associations;
  final Map<String, String> names;
}

class FaceGroupingService {
  FaceGroupingService._();

  static final instance = FaceGroupingService._();

  static const _indexFileName = 'tcloud_face_groups_v1.json';
  static const _threshold = 0.68;

  Future<void>? _initializeTask;

  Future<void> _initialize() async {
    final task = _initializeTask ??= FaceVerification.instance.init();
    try {
      await task;
    } on Object {
      _initializeTask = null;
      rethrow;
    }
  }

  Future<FaceScanResult> analyze(
    List<TCloudFile> files, {
    required void Function(int completed, int total) onProgress,
  }) async {
    final images = files.where((file) => file.isImage).toList();
    final localImages = <TCloudFile>[];
    for (final file in images) {
      final path = file.localPath?.trim() ?? '';
      if (file.downloaded && path.isNotEmpty && await File(path).exists()) {
        localImages.add(file);
      }
    }

    final index = await _readIndex();
    final associations = index.associations;
    final names = index.names;
    if (localImages.isEmpty) {
      return FaceScanResult(
        groups: _groupsFor(files, associations, names),
        scannedCount: 0,
        notAvailableLocallyCount: images.length,
        unmatchedCount: 0,
      );
    }

    await _initialize();

    final detector = FaceDetector(
      options: FaceDetectorOptions(
        enableLandmarks: false,
        enableContours: false,
        performanceMode: FaceDetectorMode.fast,
      ),
    );
    final unmatchedIdentities = <String>{};
    final cropDirectory = await Directory.systemTemp.createTemp(
      'tcloud_face_scan_',
    );

    try {
      for (var index = 0; index < localImages.length; index++) {
        final file = localImages[index];
        final path = file.localPath!;
        final identity = file.contentIdentity;
        final faces = await detector.processImage(
          InputImage.fromFilePath(path),
        );
        if (faces.isEmpty) {
          unmatchedIdentities.add(identity);
        } else {
          final bytes = await File(path).readAsBytes();
          final decoded = img.decodeImage(bytes);
          if (decoded == null) {
            throw FormatException(
              'Formato de imagem nao suportado: ${file.name}',
            );
          }
          final oriented = img.bakeOrientation(decoded);
          final people = associations.putIfAbsent(identity, () => <String>{});

          for (var faceIndex = 0; faceIndex < faces.length; faceIndex++) {
            final cropped = _cropFace(oriented, faces[faceIndex]);
            final cropFile = File(
              p.join(cropDirectory.path, 'face_${index}_$faceIndex.jpg'),
            );
            await cropFile.writeAsBytes(img.encodeJpg(cropped, quality: 92));

            var personId = await FaceVerification.instance.verifyFromImagePath(
              imagePath: cropFile.path,
              threshold: _threshold,
            );
            if (personId == null) {
              personId =
                  'person_${DateTime.now().microsecondsSinceEpoch}_${index}_$faceIndex';
              final name = 'Pessoa ${names.length + 1}';
              await FaceVerification.instance.registerFromImagePath(
                id: personId,
                imagePath: cropFile.path,
                imageId: '${identity}_$faceIndex',
                name: name,
              );
              names[personId] = name;
            }
            people.add(personId);
            await cropFile.delete();
          }
          unmatchedIdentities.remove(identity);
        }

        onProgress(index + 1, localImages.length);
      }
    } finally {
      try {
        await detector.close();
      } finally {
        if (await cropDirectory.exists()) {
          await cropDirectory.delete(recursive: true);
        }
      }
    }

    await _writeIndex(associations, names);

    return FaceScanResult(
      groups: _groupsFor(files, associations, names),
      scannedCount: localImages.length,
      notAvailableLocallyCount: images.length - localImages.length,
      unmatchedCount: unmatchedIdentities.length,
    );
  }

  Future<List<FaceGroup>> groupsFor(List<TCloudFile> files) async {
    final index = await _readIndex();
    return _groupsFor(files, index.associations, index.names);
  }

  Future<void> renameGroup(String id, String name) async {
    final cleanName = name.trim();
    if (cleanName.isEmpty) {
      throw ArgumentError.value(name, 'name', 'O nome nao pode ficar vazio.');
    }
    final index = await _readIndex();
    index.names[id] = cleanName;
    await _writeIndex(index.associations, index.names);
  }

  Future<_FaceIndex> _readIndex() async {
    final file = await _indexFile();
    if (!await file.exists()) {
      return _FaceIndex(
        associations: <String, Set<String>>{},
        names: <String, String>{},
      );
    }

    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Indice local de rostos invalido.');
    }
    final rawAssociations = decoded['associations'];
    final rawNames = decoded['names'];
    if (rawAssociations is! Map<String, dynamic> ||
        rawNames is! Map<String, dynamic>) {
      throw const FormatException('Indice local de rostos invalido.');
    }

    final associations = rawAssociations.map((identity, people) {
      if (people is! List) {
        throw const FormatException('Grupo facial invalido.');
      }
      return MapEntry(identity, people.map((id) => id.toString()).toSet());
    });
    final names = rawNames.map((id, name) => MapEntry(id, name.toString()));
    return _FaceIndex(associations: associations, names: names);
  }

  Future<void> _writeIndex(
    Map<String, Set<String>> associations,
    Map<String, String> names,
  ) async {
    final file = await _indexFile();
    await file.parent.create(recursive: true);
    await file.writeAsString(
      jsonEncode(<String, Object>{
        'associations': _encodeAssociations(associations),
        'names': names,
      }),
      flush: true,
    );
  }

  Future<File> _indexFile() async {
    final directory = await getApplicationDocumentsDirectory();
    return File(p.join(directory.path, _indexFileName));
  }

  img.Image _cropFace(img.Image source, Face face) {
    final bounds = face.boundingBox;
    final marginX = bounds.width * .2;
    final marginY = bounds.height * .2;
    final left = (bounds.left - marginX).floor().clamp(0, source.width - 1);
    final top = (bounds.top - marginY).floor().clamp(0, source.height - 1);
    final right = (bounds.right + marginX).ceil().clamp(left + 1, source.width);
    final bottom = (bounds.bottom + marginY).ceil().clamp(
      top + 1,
      source.height,
    );

    return img.copyCrop(
      source,
      x: left,
      y: top,
      width: right - left,
      height: bottom - top,
    );
  }

  Map<String, List<String>> _encodeAssociations(
    Map<String, Set<String>> associations,
  ) => associations.map(
    (identity, people) => MapEntry(identity, people.toList()),
  );

  List<FaceGroup> _groupsFor(
    List<TCloudFile> files,
    Map<String, Set<String>> associations,
    Map<String, String> names,
  ) {
    final filesByPerson = <String, Map<String, TCloudFile>>{};
    for (final file in files.where((item) => item.isImage)) {
      for (final person
          in associations[file.contentIdentity] ?? const <String>{}) {
        filesByPerson.putIfAbsent(
          person,
          () => <String, TCloudFile>{},
        )[file.contentIdentity] = file;
      }
    }

    final groups =
        filesByPerson.entries
            .map(
              (entry) => FaceGroup(
                id: entry.key,
                name: names[entry.key] ?? 'Pessoa',
                files: entry.value.values.toList()
                  ..sort((a, b) => b.createdAt.compareTo(a.createdAt)),
              ),
            )
            .toList()
          ..sort(
            (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
          );
    return groups;
  }
}

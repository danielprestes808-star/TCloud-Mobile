import 'dart:convert';
import 'dart:io';

import 'package:face_verification/face_verification.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/tcloud_file.dart';
import 'tcloud_repository.dart';

class FaceGroup {
  const FaceGroup({
    required this.id,
    required this.name,
    required this.files,
    this.needsReview = false,
  });

  final String id;
  final String name;
  final List<TCloudFile> files;
  final bool needsReview;
}

class FaceScanResult {
  const FaceScanResult({
    required this.groups,
    required this.scannedCount,
    required this.failedFiles,
    required this.unmatchedCount,
    required this.cancelled,
    required this.paused,
  });

  final List<FaceGroup> groups;
  final int scannedCount;
  final List<String> failedFiles;
  final int unmatchedCount;
  final bool cancelled;
  final bool paused;
}

class _FaceIndex {
  const _FaceIndex({
    required this.associations,
    required this.names,
    required this.aliases,
    required this.pendingReview,
    required this.manualOverrides,
  });

  final Map<String, Set<String>> associations;
  final Map<String, String> names;
  final Map<String, String> aliases;
  final Set<String> pendingReview;
  final Map<String, Set<String>> manualOverrides;
}

class _FaceScanCheckpoint {
  const _FaceScanCheckpoint({
    required this.scopeId,
    required this.completedIdentities,
  });

  final String scopeId;
  final Set<String> completedIdentities;
}

class FaceGroupingService {
  FaceGroupingService._();

  static final instance = FaceGroupingService._();

  static const _indexFileName = 'tcloud_face_groups_v1.json';
  static const _scanCheckpointFileName = 'tcloud_face_scan_v1.json';
  static const _threshold = 0.68;
  static const _videoFrameIntervalSeconds = 10;
  static const _maximumVideoFrames = 12;

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
    void Function(String phase, int current, int total)? onStatus,
    bool Function()? shouldCancel,
    bool Function()? shouldPause,
    String scanScope = 'default',
  }) async {
    final media = files.where((file) => file.isImage || file.isVideo).toList();
    final index = await _readIndex();
    final associations = index.associations;
    final names = index.names;
    final aliases = index.aliases;
    final pendingReview = index.pendingReview;
    final manualOverrides = index.manualOverrides;
    if (media.isEmpty) {
      return FaceScanResult(
        groups: _groupsFor(files, associations, names, aliases, pendingReview),
        scannedCount: 0,
        failedFiles: const [],
        unmatchedCount: 0,
        cancelled: false,
        paused: false,
      );
    }

    if (shouldCancel?.call() == true) {
      return FaceScanResult(
        groups: _groupsFor(files, associations, names, aliases, pendingReview),
        scannedCount: 0,
        failedFiles: const [],
        unmatchedCount: 0,
        cancelled: true,
        paused: false,
      );
    }

    final savedCheckpoint = await _readScanCheckpoint();
    final currentIdentities = media.map((file) => file.contentIdentity).toSet();
    final completedIdentities = savedCheckpoint?.scopeId == scanScope
        ? savedCheckpoint!.completedIdentities.intersection(currentIdentities)
        : <String>{};
    completedIdentities.addAll(
      manualOverrides.keys.where(currentIdentities.contains),
    );

    await _initialize();

    final detector = FaceDetector(
      options: FaceDetectorOptions(
        enableLandmarks: false,
        enableContours: false,
        performanceMode: FaceDetectorMode.fast,
      ),
    );
    final unmatchedIdentities = <String>{};
    final failedFiles = <String>[];
    var cancelled = false;
    var paused = false;
    var scannedCount = 0;
    onProgress(completedIdentities.length, media.length);
    final cropDirectory = await Directory.systemTemp.createTemp(
      'tcloud_face_scan_',
    );

    try {
      for (var mediaIndex = 0; mediaIndex < media.length; mediaIndex++) {
        final file = media[mediaIndex];
        final identity = file.contentIdentity;
        if (completedIdentities.contains(identity)) continue;

        if (shouldCancel?.call() == true) {
          cancelled = true;
          break;
        }
        final localPath = file.localPath?.trim() ?? '';
        final alreadyLocal =
            localPath.isNotEmpty && await File(localPath).exists();
        TCloudTemporaryMediaDownload? temporary;
        onStatus?.call(
          alreadyLocal ? 'Analisando' : 'Baixando',
          mediaIndex + 1,
          media.length,
        );
        try {
          try {
            temporary = alreadyLocal
                ? null
                : await TCloudRepository.instance.downloadForTemporaryAnalysis(
                    file,
                  );
            if (!alreadyLocal) {
              onStatus?.call('Analisando', mediaIndex + 1, media.length);
            }
            final path = temporary?.path ?? localPath;
            final people = <String>{};
            var foundFace = false;
            final timestamps = file.isVideo
                ? videoFrameTimestampsMs(file.durationSeconds)
                : const <int>[];
            final frameCount = file.isVideo ? timestamps.length : 1;
            var processedFrameCount = 0;

            for (var frameIndex = 0; frameIndex < frameCount; frameIndex++) {
              TCloudTemporaryMediaDownload? temporaryFrame;
              try {
                final framePath = file.isVideo
                    ? (temporaryFrame = await TCloudRepository.instance
                              .extractVideoFrameForTemporaryAnalysis(
                                videoPath: path,
                                timeMs: timestamps[frameIndex],
                              ))
                          .path
                    : path;
                final faces = await detector.processImage(
                  InputImage.fromFilePath(framePath),
                );
                processedFrameCount++;
                if (faces.isEmpty) continue;

                foundFace = true;
                final bytes = await File(framePath).readAsBytes();
                final decoded = img.decodeImage(bytes);
                if (decoded == null) {
                  throw FormatException(
                    'Formato de imagem nao suportado: ${file.name}',
                  );
                }
                final oriented = img.bakeOrientation(decoded);

                for (var faceIndex = 0; faceIndex < faces.length; faceIndex++) {
                  final cropped = _cropFace(oriented, faces[faceIndex]);
                  final cropFile = File(
                    p.join(
                      cropDirectory.path,
                      'face_${mediaIndex}_${frameIndex}_$faceIndex.jpg',
                    ),
                  );
                  try {
                    await cropFile.writeAsBytes(
                      img.encodeJpg(cropped, quality: 92),
                    );

                    var personId = await FaceVerification.instance
                        .verifyFromImagePath(
                          imagePath: cropFile.path,
                          threshold: _threshold,
                        );
                    if (personId == null) {
                      personId =
                          'person_${DateTime.now().microsecondsSinceEpoch}_'
                          '${mediaIndex}_${frameIndex}_$faceIndex';
                      final name = 'Pessoa ${names.length + 1}';
                      await FaceVerification.instance.registerFromImagePath(
                        id: personId,
                        imagePath: cropFile.path,
                        imageId: file.isImage
                            ? '${identity}_$faceIndex'
                            : '${identity}_frame${frameIndex}_face$faceIndex',
                        name: name,
                      );
                      names[personId] = name;
                      pendingReview.add(personId);
                    }
                    people.add(_resolveAlias(personId, aliases));
                  } finally {
                    if (await cropFile.exists()) await cropFile.delete();
                  }
                }
              } on Object catch (error) {
                failedFiles.add(
                  file.isVideo
                      ? '${file.name} (quadro ${frameIndex + 1}): '
                            '${error.runtimeType}'
                      : '${file.name}: ${error.runtimeType}',
                );
                if (!file.isVideo) rethrow;
              } finally {
                try {
                  await temporaryFrame?.release();
                } on Object catch (error) {
                  failedFiles.add(
                    '${file.name} (quadro ${frameIndex + 1}): falha ao '
                    'limpar arquivo temporário (${error.runtimeType})',
                  );
                }
              }
            }
            if (processedFrameCount == 0) {
              throw StateError('Nenhum quadro do arquivo pôde ser analisado.');
            }

            if (!foundFace) {
              unmatchedIdentities.add(identity);
            } else {
              unmatchedIdentities.remove(identity);
            }
            if (people.isEmpty) {
              associations.remove(identity);
            } else {
              associations[identity] = people;
            }
            scannedCount++;
            completedIdentities.add(identity);
          } on Object catch (error) {
            if (failedFiles.every(
              (failure) => !failure.startsWith(file.name),
            )) {
              failedFiles.add('${file.name}: ${error.runtimeType}');
            }
          }
        } finally {
          try {
            await temporary?.release();
          } on Object catch (error) {
            failedFiles.add(
              '${file.name}: falha ao limpar arquivo temporário '
              '(${error.runtimeType})',
            );
          }
        }

        await _writeIndex(
          associations,
          names,
          aliases,
          pendingReview: pendingReview,
          manualOverrides: manualOverrides,
        );
        await _writeScanCheckpoint(scanScope, completedIdentities);
        onProgress(completedIdentities.length, media.length);
        if (shouldPause?.call() == true &&
            completedIdentities.length < media.length) {
          paused = true;
          break;
        }
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

    if (cancelled || (!paused && completedIdentities.length >= media.length)) {
      await _deleteScanCheckpoint();
    }

    return FaceScanResult(
      groups: _groupsFor(files, associations, names, aliases, pendingReview),
      scannedCount: scannedCount,
      failedFiles: failedFiles,
      unmatchedCount: unmatchedIdentities.length,
      cancelled: cancelled,
      paused: paused,
    );
  }

  static List<int> videoFrameTimestampsMs(int durationSeconds) {
    final frameCount = durationSeconds <= 0
        ? 1
        : ((durationSeconds + _videoFrameIntervalSeconds - 1) ~/
                  _videoFrameIntervalSeconds)
              .clamp(1, _maximumVideoFrames);
    if (durationSeconds <= 0) return const <int>[1_000];

    final durationMs = durationSeconds * 1_000;
    return List<int>.generate(
      frameCount,
      (index) => ((index + 0.5) * durationMs / frameCount).round(),
      growable: false,
    );
  }

  Future<List<FaceGroup>> groupsFor(List<TCloudFile> files) async {
    final index = await _readIndex();
    return _groupsFor(
      files,
      index.associations,
      index.names,
      index.aliases,
      index.pendingReview,
    );
  }

  Future<List<TCloudFile>> loadAllLibraryMedia() async {
    final repository = TCloudRepository.instance;
    final folders = await repository.discoverFolders();
    final filesByIdentity = <String, TCloudFile>{};

    for (final folder in folders) {
      var cursors = const <String, int>{};
      var hasMore = true;
      while (hasMore) {
        final page = await repository.loadFilePage(
          folder,
          fromMessageIds: cursors,
        );
        for (final file in page.files) {
          if (file.isImage || file.isVideo) {
            filesByIdentity[file.contentIdentity] = file;
          }
        }
        if (!page.hasMore) break;
        if (page.nextFromMessageIds.isEmpty ||
            jsonEncode(page.nextFromMessageIds) == jsonEncode(cursors)) {
          throw StateError(
            'A paginação da pasta "${folder.title}" não avançou.',
          );
        }
        cursors = page.nextFromMessageIds;
      }
    }

    return filesByIdentity.values.toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  Future<bool> hasPendingScan(String scanScope) async {
    final checkpoint = await _readScanCheckpoint();
    return checkpoint?.scopeId == scanScope &&
        checkpoint!.completedIdentities.isNotEmpty;
  }

  Future<void> confirmGroupReviewed(String id) async {
    final index = await _readIndex();
    index.pendingReview.remove(_resolveAlias(id, index.aliases));
    await _writeIndex(
      index.associations,
      index.names,
      index.aliases,
      pendingReview: index.pendingReview,
      manualOverrides: index.manualOverrides,
    );
  }

  Future<void> moveFilesToGroup(
    String sourceId,
    String destinationId,
    Iterable<String> fileIdentities,
  ) async {
    final index = await _readIndex();
    final source = _resolveAlias(sourceId, index.aliases);
    final destination = _resolveAlias(destinationId, index.aliases);
    if (source == destination) {
      throw ArgumentError('Escolha duas pessoas diferentes.');
    }

    for (final identity in fileIdentities.toSet()) {
      final people = index.associations[identity];
      if (people == null) continue;
      people
        ..removeWhere(
          (person) => _resolveAlias(person, index.aliases) == source,
        )
        ..add(destination);
      index.manualOverrides[identity] = people
          .map((person) => _resolveAlias(person, index.aliases))
          .toSet();
    }

    await _writeIndex(
      index.associations,
      index.names,
      index.aliases,
      pendingReview: index.pendingReview,
      manualOverrides: index.manualOverrides,
    );
  }

  Future<void> clearAllFaceData() async {
    await _initialize();
    final registeredUsers = await FaceVerification.instance
        .getAllRegisteredUsers();
    for (final id in registeredUsers) {
      await FaceVerification.instance.deleteUserFaces(id);
    }

    final indexFile = await _indexFile();
    if (await indexFile.exists()) await indexFile.delete();
    await _deleteScanCheckpoint();
  }

  Future<void> renameGroup(String id, String name) async {
    final cleanName = name.trim();
    if (cleanName.isEmpty) {
      throw ArgumentError.value(name, 'name', 'O nome nao pode ficar vazio.');
    }
    final index = await _readIndex();
    final canonicalId = _resolveAlias(id, index.aliases);
    index.names[canonicalId] = cleanName;
    index.pendingReview.remove(canonicalId);
    await _writeIndex(
      index.associations,
      index.names,
      index.aliases,
      pendingReview: index.pendingReview,
      manualOverrides: index.manualOverrides,
    );
  }

  Future<void> removeFilesFromGroup(
    String personId,
    Iterable<String> fileIdentities,
  ) async {
    final index = await _readIndex();
    final target = _resolveAlias(personId, index.aliases);

    for (final identity in fileIdentities.toSet()) {
      final people = index.associations[identity];
      if (people == null) {
        index.manualOverrides[identity] = <String>{};
        continue;
      }
      people.removeWhere(
        (person) => _resolveAlias(person, index.aliases) == target,
      );
      if (people.isEmpty) index.associations.remove(identity);
      index.manualOverrides[identity] = people
          .map((person) => _resolveAlias(person, index.aliases))
          .toSet();
    }

    await _writeIndex(
      index.associations,
      index.names,
      index.aliases,
      pendingReview: index.pendingReview,
      manualOverrides: index.manualOverrides,
    );
  }

  Future<void> mergeGroups(String sourceId, String destinationId) async {
    final index = await _readIndex();
    final source = _resolveAlias(sourceId, index.aliases);
    final destination = _resolveAlias(destinationId, index.aliases);
    if (source == destination) {
      throw ArgumentError('Escolha duas pessoas diferentes para combinar.');
    }

    index.aliases[source] = destination;
    for (final alias in index.aliases.keys.toList()) {
      index.aliases[alias] = _resolveAlias(alias, index.aliases);
    }

    for (final people in index.associations.values) {
      final canonicalPeople = people
          .map((person) => _resolveAlias(person, index.aliases))
          .toSet();
      people
        ..clear()
        ..addAll(canonicalPeople);
    }
    for (final identity in index.manualOverrides.keys.toList()) {
      index.manualOverrides[identity] = index.manualOverrides[identity]!
          .map((person) => _resolveAlias(person, index.aliases))
          .toSet();
    }
    index.names.remove(source);
    index.pendingReview.remove(source);
    await _writeIndex(
      index.associations,
      index.names,
      index.aliases,
      pendingReview: index.pendingReview,
      manualOverrides: index.manualOverrides,
    );
  }

  Future<_FaceIndex> _readIndex() async {
    final file = await _indexFile();
    if (!await file.exists()) {
      return _FaceIndex(
        associations: <String, Set<String>>{},
        names: <String, String>{},
        aliases: <String, String>{},
        pendingReview: <String>{},
        manualOverrides: <String, Set<String>>{},
      );
    }

    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Indice local de rostos invalido.');
    }
    final rawAssociations = decoded['associations'];
    final rawNames = decoded['names'];
    final rawAliases = decoded['aliases'];
    final rawPendingReview = decoded['pendingReview'];
    final rawManualOverrides = decoded['manualOverrides'];
    if (rawAssociations is! Map<String, dynamic> ||
        rawNames is! Map<String, dynamic> ||
        (rawAliases != null && rawAliases is! Map<String, dynamic>) ||
        (rawPendingReview != null && rawPendingReview is! List) ||
        (rawManualOverrides != null &&
            rawManualOverrides is! Map<String, dynamic>)) {
      throw const FormatException('Indice local de rostos invalido.');
    }

    final associations = rawAssociations.map((identity, people) {
      if (people is! List) {
        throw const FormatException('Grupo facial invalido.');
      }
      return MapEntry(identity, people.map((id) => id.toString()).toSet());
    });
    final names = rawNames.map((id, name) => MapEntry(id, name.toString()));
    final aliases = rawAliases == null
        ? <String, String>{}
        : (rawAliases as Map<String, dynamic>).map(
            (id, canonical) => MapEntry(id, canonical.toString()),
          );
    return _FaceIndex(
      associations: associations,
      names: names,
      aliases: aliases,
      pendingReview:
          (rawPendingReview as List?)?.map((id) => id.toString()).toSet() ??
          <String>{},
      manualOverrides: rawManualOverrides == null
          ? <String, Set<String>>{}
          : (rawManualOverrides as Map<String, dynamic>).map((
              identity,
              people,
            ) {
              if (people is! List) {
                throw const FormatException(
                  'Correção manual de grupo facial inválida.',
                );
              }
              return MapEntry(
                identity,
                people.map((id) => id.toString()).toSet(),
              );
            }),
    );
  }

  Future<void> _writeIndex(
    Map<String, Set<String>> associations,
    Map<String, String> names,
    Map<String, String> aliases, {
    Set<String> pendingReview = const <String>{},
    Map<String, Set<String>> manualOverrides = const <String, Set<String>>{},
  }) async {
    final file = await _indexFile();
    await file.parent.create(recursive: true);
    await file.writeAsString(
      jsonEncode(<String, Object>{
        'associations': _encodeAssociations(associations),
        'names': names,
        'aliases': aliases,
        'pendingReview': pendingReview.toList(),
        'manualOverrides': _encodeAssociations(manualOverrides),
      }),
      flush: true,
    );
  }

  Future<File> _indexFile() async {
    final directory = await getApplicationDocumentsDirectory();
    return File(p.join(directory.path, _indexFileName));
  }

  Future<File> _scanCheckpointFile() async {
    final directory = await getApplicationDocumentsDirectory();
    return File(p.join(directory.path, _scanCheckpointFileName));
  }

  Future<_FaceScanCheckpoint?> _readScanCheckpoint() async {
    final file = await _scanCheckpointFile();
    if (!await file.exists()) return null;

    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map<String, dynamic> ||
        decoded['scopeId'] is! String ||
        decoded['completedIdentities'] is! List) {
      throw const FormatException('Ponto de retomada facial inválido.');
    }
    return _FaceScanCheckpoint(
      scopeId: decoded['scopeId'] as String,
      completedIdentities: (decoded['completedIdentities'] as List)
          .map((identity) => identity.toString())
          .toSet(),
    );
  }

  Future<void> _writeScanCheckpoint(
    String scopeId,
    Set<String> completedIdentities,
  ) async {
    final file = await _scanCheckpointFile();
    await file.parent.create(recursive: true);
    await file.writeAsString(
      jsonEncode(<String, Object>{
        'scopeId': scopeId,
        'completedIdentities': completedIdentities.toList(),
      }),
      flush: true,
    );
  }

  Future<void> _deleteScanCheckpoint() async {
    final file = await _scanCheckpointFile();
    if (await file.exists()) await file.delete();
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
    Map<String, String> aliases,
    Set<String> pendingReview,
  ) {
    final filesByPerson = <String, Map<String, TCloudFile>>{};
    for (final file in files.where((item) => item.isImage || item.isVideo)) {
      for (final person
          in associations[file.contentIdentity] ?? const <String>{}) {
        final canonicalPerson = _resolveAlias(person, aliases);
        filesByPerson.putIfAbsent(
          canonicalPerson,
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
                needsReview: pendingReview.contains(entry.key),
              ),
            )
            .toList()
          ..sort(
            (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
          );
    return groups;
  }

  String _resolveAlias(String personId, Map<String, String> aliases) {
    var current = personId;
    final visited = <String>{};
    while (visited.add(current)) {
      final next = aliases[current];
      if (next == null || next.isEmpty || next == current) break;
      current = next;
    }
    return current;
  }
}

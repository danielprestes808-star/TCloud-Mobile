import 'dart:async';
import 'dart:io';

import 'package:flutter_chrome_cast/flutter_chrome_cast.dart';

import '../models/tcloud_file.dart';
import '../telegram/tdlib_service.dart';

class CastService {
  CastService._();

  static final instance = CastService._();
  bool _initialized = false;

  Future<void> initialize() async {
    if (_initialized || !Platform.isAndroid) return;
    await GoogleCastContext.instance.setSharedInstanceWithOptions(
      GoogleCastOptionsAndroid(
        appId: GoogleCastDiscoveryCriteria.kDefaultApplicationId,
        stopCastingOnAppTerminated: false,
      ),
    );
    _initialized = true;
  }

  Stream<List<GoogleCastDevice>> get devices =>
      GoogleCastDiscoveryManager.instance.devicesStream;

  Future<void> startDiscovery() async {
    await initialize();
    await GoogleCastDiscoveryManager.instance.startDiscovery();
  }

  Future<void> cast(TCloudFile file, GoogleCastDevice device) async {
    await initialize();
    if (!GoogleCastSessionManager.instance.hasConnectedSession) {
      final started = await GoogleCastSessionManager.instance
          .startSessionWithDevice(device);
      if (!started) throw StateError('Nao foi possivel conectar a TV.');
      await GoogleCastSessionManager.instance.currentSessionStream
          .where(
            (session) =>
                session?.connectionState == GoogleCastConnectState.connected,
          )
          .first
          .timeout(const Duration(seconds: 20));
    }

    final url = await TdlibService.instance.prepareCastStream(
      fileId: file.fileId,
      size: file.size,
      mimeType: file.mimeType,
    );
    await GoogleCastRemoteMediaClient.instance.loadMedia(
      GoogleCastMediaInformation(
        contentId: file.syncIdentity,
        streamType: CastMediaStreamType.buffered,
        contentUrl: Uri.parse(url),
        contentType:
            file.mimeType ?? (file.isVideo ? 'video/mp4' : 'image/jpeg'),
        metadata: GoogleCastMovieMediaMetadata(title: file.name),
      ),
    );
  }
}

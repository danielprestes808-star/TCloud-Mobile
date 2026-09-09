import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';

import '../models/tcloud_file.dart';
import '../services/tcloud_repository.dart';
import '../services/thumbnail_cache_service.dart';
import '../telegram/tdlib_service.dart';
import '../services/media_cache_policy.dart';
import '../services/cast_service.dart';
import 'package:flutter_chrome_cast/flutter_chrome_cast.dart';

class MediaViewerScreen extends StatefulWidget {
  const MediaViewerScreen({super.key, required this.file, this.files});

  final TCloudFile file;
  final List<TCloudFile>? files;

  @override
  State<MediaViewerScreen> createState() => _MediaViewerScreenState();
}

class _MediaViewerScreenState extends State<MediaViewerScreen> {
  static const _blue = Color(0xFF2AABEE);

  final _repo = TCloudRepository.instance;
  final _thumbs = ThumbnailCacheService.instance;

  late final PageController _pages;
  late List<TCloudFile> _items;
  late int _index;

  VideoPlayerController? _video;
  TCloudFile? _activeVideoFile;
  String? _path;
  String? _previewPath;
  String? _error;
  String? _errorDetails;

  bool _loading = true;
  bool _controlsVisible = true;
  bool _usingStream = false;
  bool _fallbackUsed = false;
  bool _fallbackBusy = false;
  bool _actionBusy = false;

  int _loadGeneration = 0;
  String _lastResumeSaveKey = '';
  int _seekGeneration = 0;
  int _seekSeconds = 0;
  bool _seekVisible = false;

  double _doubleTapDx = 0;
  double _dismissOffset = 0;
  double _speed = 1;
  Timer? _hideTimer;

  TCloudFile get _file => _items[_index];

  @override
  void initState() {
    super.initState();
    final supplied = widget.files?.where((e) => e.isMedia).toList();
    _items = supplied == null || supplied.isEmpty
        ? <TCloudFile>[widget.file]
        : supplied;
    _index = _items.indexWhere(
      (e) => e.syncIdentity == widget.file.syncIdentity,
    );
    if (_index < 0) {
      _items.insert(0, widget.file);
      _index = 0;
    }
    _pages = PageController(initialPage: _index);
    unawaited(_prepare(_file));
    _prewarmAround();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    final c = _video;
    c?.removeListener(_onVideoChanged);
    unawaited(_saveVideoPosition());
    unawaited(c?.dispose());
    _pages.dispose();
    super.dispose();
  }

  String _resumeKey(TCloudFile file) =>
      'tcloud:video-resume:${file.syncIdentity}';

  Future<void> _saveVideoPosition() async {
    final file = _activeVideoFile;
    final c = _video;
    if (file == null || c == null || !c.value.isInitialized) return;
    final p = c.value.position.inMilliseconds;
    final d = c.value.duration.inMilliseconds;
    if (d <= 0) return;
    final prefs = await SharedPreferences.getInstance();
    if (p >= d - 2000) {
      await prefs.remove(_resumeKey(file));
    } else if (p > 1500) {
      await prefs.setInt(_resumeKey(file), p);
    }
  }

  Future<void> _restorePosition(
    TCloudFile file,
    VideoPlayerController c, [
    Duration? override,
  ]) async {
    Duration? target = override;
    if (target == null) {
      final prefs = await SharedPreferences.getInstance();
      final ms = prefs.getInt(_resumeKey(file)) ?? 0;
      if (ms > 0) target = Duration(milliseconds: ms);
    }
    if (target == null || target <= Duration.zero) return;
    if (c.value.duration > Duration.zero &&
        target < c.value.duration - const Duration(seconds: 2)) {
      await c.seekTo(target);
    }
  }

  void _prewarmAround() {
    // TCLOUD_MEDIA_MANAGER_90_MOBILE_WARM
    unawaited(MediaCachePolicy.instance.optimize());

    if (_items.isNotEmpty) {
      for (final delta in const <int>[-1, 1, 2]) {
        final candidate = _index + delta;
        if (candidate >= 0 && candidate < _items.length) {
          unawaited(MediaCachePolicy.instance.warm(_items[candidate]));
        }
      }
    }

    final currentIdentity = _file.syncIdentity;

    final near = <TCloudFile>[];

    for (final delta in const [-1, 1]) {
      final index = _index + delta;

      if (index >= 0 && index < _items.length) {
        near.add(_items[index]);
      }
    }

    if (near.isNotEmpty) {
      unawaited(_thumbs.prewarm(near, maximum: 4, concurrency: 2));
    }

    if (_index + 1 >= _items.length) {
      return;
    }

    final next = _items[_index + 1];

    if (!next.isVideo) {
      return;
    }

    Future<void>.delayed(const Duration(milliseconds: 1200), () {
      if (!mounted || _file.syncIdentity != currentIdentity) {
        return;
      }

      final current = _video;

      if (current == null ||
          !current.value.isPlaying ||
          current.value.isBuffering) {
        return;
      }

      unawaited(_warmVideo(next));
    });
  }

  Future<void> _warmVideo(TCloudFile file) async {
    HttpClient? client;

    try {
      final current = await _repo.resolveCurrentMedia(file);

      final local = current.localPath;
      if (local != null && local.isNotEmpty && await File(local).exists()) {
        return;
      }

      final url = await TdlibService.instance.prepareVideoStream(
        fileId: current.fileId,
        size: current.size,
        mimeType: current.mimeType,
      );

      client = HttpClient()..connectionTimeout = const Duration(seconds: 6);

      final request = await client.getUrl(Uri.parse(url));

      request.headers.set('Range', 'bytes=0-262143');

      final response = await request.close();
      await response.drain<void>();
    } catch (_) {
      // Prefetch e apenas uma otimizacao.
    } finally {
      client?.close(force: true);
    }
  }

  Future<void> _upgradePreview(TCloudFile file, int generation) async {
    try {
      final preview = await _thumbs.fullPreviewPath(file);
      if (!mounted ||
          generation != _loadGeneration ||
          _file.stableIdentity != file.stableIdentity ||
          preview == null ||
          preview.isEmpty) {
        return;
      }
      setState(() => _previewPath = preview);
    } catch (_) {}
  }

  Future<VideoPlayerController> _networkController(TCloudFile file) async {
    final url = await TdlibService.instance.prepareVideoStream(
      fileId: file.fileId,
      size: file.size,
      mimeType: file.mimeType,
    );

    return VideoPlayerController.networkUrl(Uri.parse(url));
  }

  Future<VideoPlayerController> _localController(
    TCloudFile file, [
    String? known,
    bool repair = false,
  ]) async {
    final candidate = known?.trim() ?? '';
    final downloaded = candidate.isNotEmpty && await File(candidate).exists()
        ? candidate
        : await _repo.download(file, forceRefresh: repair);

    final path = await _repo.validateDownloadedFilePath(file, downloaded);

    _path = path;

    return VideoPlayerController.file(File(path));
  }

  Future<void> _prepare(
    TCloudFile file, {
    bool forceLocal = false,
    bool refreshRemote = false,
    bool repairLocal = false,
    Duration? resume,
  }) async {
    final generation = ++_loadGeneration;
    unawaited(_saveVideoPosition());

    final old = _video;
    old?.removeListener(_onVideoChanged);
    _video = null;
    _activeVideoFile = null;
    await old?.dispose();

    if (!mounted || generation != _loadGeneration) return;
    _hideTimer?.cancel();
    setState(() {
      _path = null;
      _previewPath = file.thumbnailLocalPath;
      _error = null;
      _errorDetails = null;
      _loading = true;
      _controlsVisible = true;
      _usingStream = false;
      _fallbackUsed = forceLocal;
    });

    try {
      final current = refreshRemote
          ? await _repo.refreshCurrentMedia(file)
          : await _repo.resolveCurrentMedia(file);

      if (!mounted ||
          generation != _loadGeneration ||
          _file.stableIdentity != file.stableIdentity) {
        return;
      }

      _items[_index] = current;
      unawaited(_upgradePreview(current, generation));

      if (current.isVideo) {
        final candidate = current.localPath;
        final localExists =
            candidate != null &&
            candidate.isNotEmpty &&
            await File(candidate).exists();

        VideoPlayerController c;
        if (localExists || forceLocal) {
          c = await _localController(
            current,
            forceLocal ? null : (localExists ? candidate : null),
            repairLocal,
          );
          _usingStream = false;
        } else {
          try {
            c = await _networkController(current);
            _usingStream = true;
          } catch (_) {
            c = await _localController(current);
            _usingStream = false;
            _fallbackUsed = true;
          }
        }

        try {
          await c.initialize().timeout(const Duration(seconds: 12));
        } catch (_) {
          await c.dispose();
          if (_usingStream && !forceLocal) {
            _usingStream = false;
            _fallbackUsed = true;
            c = await _localController(current);
            await c.initialize().timeout(const Duration(seconds: 45));
          } else if (localExists && !forceLocal) {
            _fallbackUsed = true;
            c = await _localController(current);
            await c.initialize().timeout(const Duration(seconds: 45));
          } else {
            rethrow;
          }
        }

        await c.setLooping(false);
        await c.setPlaybackSpeed(_speed);
        await _restorePosition(current, c, resume);

        if (!mounted ||
            generation != _loadGeneration ||
            _file.stableIdentity != current.stableIdentity) {
          await c.dispose();
          return;
        }

        _video = c;
        _activeVideoFile = current;
        c.addListener(_onVideoChanged);
        setState(() => _loading = false);
        await c.play();
        _scheduleHide();
        return;
      }

      final path = await _repo.download(current);
      if (!mounted ||
          generation != _loadGeneration ||
          _file.stableIdentity != current.stableIdentity) {
        return;
      }
      setState(() {
        _path = path;
        _loading = false;
      });
    } catch (e) {
      debugPrint('TCloud player: $e');
      if (!mounted ||
          generation != _loadGeneration ||
          _file.stableIdentity != file.stableIdentity) {
        return;
      }
      setState(() {
        _loading = false;
        final detail = e.toString().replaceFirst('Bad state: ', '').trim();
        _errorDetails = detail.length > 160
            ? '${detail.substring(0, 157)}...'
            : detail;
        _error = file.isVideo
            ? 'Nao foi possivel reproduzir este video.'
            : 'Nao foi possivel abrir esta midia.';
      });
    }
  }

  void _onVideoChanged() {
    final c = _video;

    if (!mounted || c == null) {
      return;
    }

    final value = c.value;

    if (value.hasError) {
      debugPrint('TCloud backend: ${value.errorDescription}');

      if (_usingStream && !_fallbackUsed && !_fallbackBusy) {
        unawaited(_fallbackToLocal());
        return;
      }

      if (!_usingStream && _error == null) {
        setState(() {
          _error = 'Nao foi possivel reproduzir este video.';
        });
      }

      return;
    }

    // Salva a retomada no maximo uma vez a cada 10 segundos.
    // A chave inclui o arquivo, entao nao precisa resetar em _prepare.
    final second = value.position.inSeconds;

    if (value.isPlaying && second >= 10 && second % 10 == 0) {
      final saveKey = '${_file.syncIdentity}:$second';

      if (saveKey != _lastResumeSaveKey) {
        _lastResumeSaveKey = saveKey;
        unawaited(_saveVideoPosition());
      }
    }

    // Video e barra escutam o controller diretamente.
    // Nao ha setState global a cada 250 ms.
  }

  Future<void> _fallbackToLocal() async {
    if (_fallbackBusy) return;
    _fallbackBusy = true;
    _fallbackUsed = true;
    final position = _video?.value.position ?? Duration.zero;
    final file = _file;
    if (mounted) setState(() => _loading = true);
    try {
      await _prepare(file, forceLocal: true, resume: position);
    } finally {
      _fallbackBusy = false;
    }
  }

  Future<void> _changePage(int index) async {
    if (index == _index) return;
    unawaited(_saveVideoPosition());
    if (!mounted) return;
    setState(() {
      _index = index;
      _dismissOffset = 0;
    });
    await _prepare(_file);
    _prewarmAround();
  }

  Future<String> _ensureLocal(TCloudFile file) async {
    final candidate = file.localPath;
    if (candidate != null &&
        candidate.isNotEmpty &&
        await File(candidate).exists()) {
      return candidate;
    }
    if (_path != null && _path!.isNotEmpty && await File(_path!).exists()) {
      return _path!;
    }
    return _repo.download(file);
  }

  Future<void> _share() async {
    if (_actionBusy) return;
    setState(() => _actionBusy = true);
    try {
      final path = await _ensureLocal(_file);
      await TdlibService.instance.shareFile(path, mimeType: _file.mimeType);
    } catch (_) {
      if (mounted) _message('Nao foi possivel compartilhar.');
    } finally {
      if (mounted) setState(() => _actionBusy = false);
    }
  }

  Future<void> _cast() async {
    if (!_file.isVideo && !_file.isImage) {
      _message('A transmissao esta disponivel para fotos e videos.');
      return;
    }
    try {
      await CastService.instance.startDiscovery();
      if (!mounted) return;
      final device = await showModalBottomSheet<GoogleCastDevice>(
        context: context,
        showDragHandle: true,
        builder: (sheetContext) => SafeArea(
          child: StreamBuilder<List<GoogleCastDevice>>(
            stream: CastService.instance.devices,
            builder: (context, snapshot) {
              final devices = snapshot.data ?? const <GoogleCastDevice>[];
              return SizedBox(
                height: 320,
                child: devices.isEmpty
                    ? const Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            CircularProgressIndicator(),
                            SizedBox(height: 16),
                            Text('Procurando TVs na mesma rede Wi-Fi...'),
                          ],
                        ),
                      )
                    : ListView.builder(
                        itemCount: devices.length,
                        itemBuilder: (_, index) => ListTile(
                          leading: const Icon(Icons.cast),
                          title: Text(devices[index].friendlyName),
                          subtitle: Text(
                            devices[index].modelName ?? 'Google Cast',
                          ),
                          onTap: () =>
                              Navigator.pop(sheetContext, devices[index]),
                        ),
                      ),
              );
            },
          ),
        ),
      );
      if (device == null || !mounted) return;
      setState(() => _actionBusy = true);
      await CastService.instance.cast(_file, device);
      if (mounted) _message('Transmitindo em ${device.friendlyName}.');
    } catch (error) {
      if (mounted) _message('Nao foi possivel transmitir: $error');
    } finally {
      if (mounted) setState(() => _actionBusy = false);
    }
  }

  Future<void> _offline() async {
    if (_actionBusy) return;
    setState(() => _actionBusy = true);
    try {
      final path = await _ensureLocal(_file);
      await _repo.rememberOffline(
        _file.copyWith(localPath: path, downloaded: true),
      );
      if (mounted) _message('Disponivel offline.');
    } catch (_) {
      if (mounted) _message('Nao foi possivel baixar o arquivo.');
    } finally {
      if (mounted) setState(() => _actionBusy = false);
    }
  }

  Future<void> _openExternal() async {
    if (_actionBusy) return;
    setState(() => _actionBusy = true);
    try {
      final path = await _ensureLocal(_file);
      await OpenFilex.open(path);
    } catch (_) {
      if (mounted) _message('Não foi possível abrir em outro aplicativo.');
    } finally {
      if (mounted) setState(() => _actionBusy = false);
    }
  }

  Future<void> _pictureInPicture() async {
    final ratio = _video?.value.aspectRatio ?? (16 / 9);
    final width = (ratio * 1000).round().clamp(1, 2390);
    final entered = await TdlibService.instance.enterPictureInPicture(
      width: width,
      height: 1000,
    );
    if (!entered && mounted) {
      _message('Picture-in-picture não está disponível.');
    }
  }

  void _message(String text) => ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(text), duration: const Duration(seconds: 2)),
  );

  void _scheduleHide() {
    _hideTimer?.cancel();
    if (_video?.value.isPlaying != true) return;
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _controlsVisible = false);
    });
  }

  void _toggleControls() {
    _hideTimer?.cancel();
    setState(() => _controlsVisible = !_controlsVisible);
    if (_controlsVisible) _scheduleHide();
  }

  Future<void> _togglePlay() async {
    final c = _video;
    if (c == null || !c.value.isInitialized) return;
    if (c.value.isPlaying) {
      await c.pause();
      _hideTimer?.cancel();
      if (mounted) setState(() => _controlsVisible = true);
    } else {
      await c.play();
      if (mounted) setState(() => _controlsVisible = true);
      _scheduleHide();
    }
  }

  void _captureDoubleTap(TapDownDetails d) => _doubleTapDx = d.localPosition.dx;

  Future<void> _doubleTapSeek() async {
    final c = _video;
    if (c == null || !c.value.isInitialized) return;
    final seconds = _doubleTapDx < MediaQuery.sizeOf(context).width / 2
        ? -10
        : 10;
    var target = c.value.position + Duration(seconds: seconds);
    if (target.isNegative) target = Duration.zero;
    if (c.value.duration > Duration.zero && target > c.value.duration) {
      target = c.value.duration;
    }
    await c.seekTo(target);
    if (!mounted) return;
    final generation = ++_seekGeneration;
    setState(() {
      _seekSeconds = seconds;
      _seekVisible = true;
      _controlsVisible = true;
    });
    _scheduleHide();
    await Future<void>.delayed(const Duration(milliseconds: 520));
    if (mounted && generation == _seekGeneration) {
      setState(() => _seekVisible = false);
    }
  }

  Future<void> _chooseSpeed() async {
    final selected = await showModalBottomSheet<double>(
      context: context,
      backgroundColor: const Color(0xFF1C1C1E),
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(
              title: Text(
                'Velocidade de reproducao',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            for (final s in const <double>[.5, .75, 1, 1.25, 1.5, 2])
              ListTile(
                leading: Icon(
                  s == _speed
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off,
                  color: s == _speed ? _blue : null,
                ),
                title: Text('${s}x'),
                onTap: () => Navigator.pop(context, s),
              ),
          ],
        ),
      ),
    );
    if (selected == null) return;
    _speed = selected;
    await _video?.setPlaybackSpeed(selected);
    if (mounted) setState(() {});
    _scheduleHide();
  }

  Future<void> _more() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1C1C1E),
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_file.isVideo)
              ListTile(
                leading: const Icon(Icons.speed_rounded),
                title: const Text('Velocidade'),
                trailing: Text(
                  '${_speed}x',
                  style: const TextStyle(color: _blue),
                ),
                onTap: () {
                  Navigator.pop(sheet);
                  _chooseSpeed();
                },
              ),
            if (_file.isVideo)
              ListTile(
                leading: const Icon(Icons.picture_in_picture_alt_outlined),
                title: const Text('Picture-in-picture'),
                onTap: () {
                  Navigator.pop(sheet);
                  _pictureInPicture();
                },
              ),
            ListTile(
              leading: const Icon(Icons.open_in_new_rounded),
              title: const Text('Abrir em outro aplicativo'),
              onTap: () {
                Navigator.pop(sheet);
                _openExternal();
              },
            ),
            ListTile(
              leading: const Icon(Icons.download_for_offline_outlined),
              title: const Text('Disponibilizar offline'),
              onTap: () {
                Navigator.pop(sheet);
                _offline();
              },
            ),
            ListTile(
              leading: const Icon(Icons.share_outlined),
              title: const Text('Compartilhar'),
              onTap: () {
                Navigator.pop(sheet);
                _share();
              },
            ),
          ],
        ),
      ),
    );
  }

  void _vertical(DragUpdateDetails d) {
    final next = _dismissOffset + d.delta.dy;
    if (next >= 0) {
      setState(() => _dismissOffset = next.clamp(0.0, 220.0).toDouble());
    }
  }

  void _verticalEnd(DragEndDetails d) {
    if (_dismissOffset > 105 || (d.primaryVelocity ?? 0) > 850) {
      Navigator.maybePop(context);
    } else {
      setState(() => _dismissOffset = 0);
    }
  }

  String _clock(Duration d) {
    var s = d.inSeconds;
    if (s < 0) s = 0;
    final h = s ~/ 3600;
    final m = (s % 3600) ~/ 60;
    final sec = s % 60;
    return h > 0
        ? '$h:${m.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}'
        : '$m:${sec.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Transform.translate(
        offset: Offset(0, _dismissOffset),
        child: Stack(
          fit: StackFit.expand,
          children: [
            PageView.builder(
              controller: _pages,
              itemCount: _items.length,
              onPageChanged: _changePage,
              itemBuilder: (context, i) {
                if (i != _index) return _preview(_items[i]);
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _toggleControls,
                  onDoubleTapDown: _file.isVideo ? _captureDoubleTap : null,
                  onDoubleTap: _file.isVideo ? _doubleTapSeek : null,
                  onVerticalDragUpdate: _vertical,
                  onVerticalDragEnd: _verticalEnd,
                  child: _body(),
                );
              },
            ),
            _top(),
            if (_file.isVideo) _bottom(),
            if (_seekVisible) _seekOverlay(),
            if (_actionBusy)
              const IgnorePointer(
                child: Center(
                  child: CircularProgressIndicator(color: Colors.white),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _body() {
    if (_error != null) return _errorWidget();
    if (_file.isVideo) return _videoWidget();
    if (_path != null && File(_path!).existsSync()) {
      return InteractiveViewer(
        maxScale: 5,
        child: Center(child: Image.file(File(_path!), fit: BoxFit.contain)),
      );
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        _preview(_file),
        if (_loading)
          const Center(child: CircularProgressIndicator(color: Colors.white)),
      ],
    );
  }

  Widget _videoWidget() {
    final c = _video;

    if (c == null) {
      return ColoredBox(
        color: Colors.black,
        child: Stack(
          fit: StackFit.expand,
          children: [
            _preview(_file),
            if (_loading)
              const Center(
                child: CircularProgressIndicator(
                  strokeWidth: 2.8,
                  color: Colors.white,
                ),
              ),
          ],
        ),
      );
    }

    return ColoredBox(
      color: Colors.black,
      child: ValueListenableBuilder<VideoPlayerValue>(
        valueListenable: c,
        builder: (context, value, _) {
          final initialized = value.isInitialized;

          return Stack(
            fit: StackFit.expand,
            children: [
              if (!initialized) _preview(_file),

              if (initialized)
                Center(
                  child: RepaintBoundary(
                    child: AspectRatio(
                      aspectRatio: value.aspectRatio > 0
                          ? value.aspectRatio
                          : 16 / 9,
                      child: VideoPlayer(c),
                    ),
                  ),
                ),

              if (_loading || value.isBuffering)
                Center(
                  child: Container(
                    width: 46,
                    height: 46,
                    padding: const EdgeInsets.all(11),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: .48),
                      shape: BoxShape.circle,
                    ),
                    child: const CircularProgressIndicator(
                      strokeWidth: 2.6,
                      color: Colors.white,
                    ),
                  ),
                ),

              if (initialized &&
                  _controlsVisible &&
                  !value.isPlaying &&
                  !value.isBuffering)
                Center(
                  child: InkWell(
                    onTap: _togglePlay,
                    customBorder: const CircleBorder(),
                    child: Container(
                      width: 68,
                      height: 68,
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: .48),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.play_arrow_rounded,
                        color: Colors.white,
                        size: 47,
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _preview(TCloudFile file) {
    final p = file.syncIdentity == _file.syncIdentity
        ? _previewPath
        : file.thumbnailLocalPath;
    if (p != null && p.isNotEmpty && File(p).existsSync()) {
      return Center(
        child: Image.file(File(p), fit: BoxFit.contain, gaplessPlayback: true),
      );
    }
    final bytes = _thumbs.instantPreview(file);
    if (bytes != null && bytes.isNotEmpty) {
      return Center(
        child: Image.memory(bytes, fit: BoxFit.contain, gaplessPlayback: true),
      );
    }
    return const ColoredBox(color: Colors.black);
  }

  Widget _top() => AnimatedOpacity(
    opacity: _controlsVisible ? 1 : 0,
    duration: const Duration(milliseconds: 160),
    child: IgnorePointer(
      ignoring: !_controlsVisible,
      child: Align(
        alignment: Alignment.topCenter,
        child: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Color(0xD9000000),
                Color(0x70000000),
                Colors.transparent,
              ],
            ),
          ),
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(6, 4, 4, 28),
              child: Row(
                children: [
                  IconButton(
                    onPressed: () => Navigator.maybePop(context),
                    icon: const Icon(
                      Icons.arrow_back_rounded,
                      color: Colors.white,
                      size: 30,
                    ),
                  ),
                  Expanded(
                    child: Text(
                      _file.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  Text(
                    '${_index + 1}/${_items.length}',
                    style: const TextStyle(color: Colors.white70),
                  ),
                  if (_file.isVideo || _file.isImage)
                    IconButton(
                      tooltip: 'Transmitir para TV',
                      onPressed: _actionBusy ? null : _cast,
                      icon: const Icon(Icons.cast, color: Colors.white),
                    ),
                  IconButton(
                    onPressed: _actionBusy ? null : _share,
                    icon: const Icon(Icons.share_outlined, color: Colors.white),
                  ),
                  IconButton(
                    onPressed: _actionBusy ? null : _more,
                    icon: const Icon(Icons.more_vert, color: Colors.white),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );

  Widget _bottom() {
    final c = _video;

    if (c == null) {
      return const SizedBox.shrink();
    }

    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: c,
      builder: (context, v, _) {
        if (!v.isInitialized) {
          return const SizedBox.shrink();
        }

        return Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: RepaintBoundary(
            child: AnimatedOpacity(
              opacity: _controlsVisible ? 1 : 0,
              duration: const Duration(milliseconds: 160),
              child: IgnorePointer(
                ignoring: !_controlsVisible,
                child: Container(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.transparent,
                        Color(0x82000000),
                        Color(0xEE000000),
                      ],
                    ),
                  ),
                  child: SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 36, 12, 8),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          VideoProgressIndicator(
                            c,
                            allowScrubbing: true,
                            padding: const EdgeInsets.symmetric(vertical: 10),
                            colors: const VideoProgressColors(
                              playedColor: _blue,
                              bufferedColor: Colors.white38,
                              backgroundColor: Colors.white24,
                            ),
                          ),
                          Row(
                            children: [
                              IconButton(
                                onPressed: _togglePlay,
                                padding: const EdgeInsets.all(4),
                                constraints: const BoxConstraints(
                                  minWidth: 38,
                                  minHeight: 38,
                                ),
                                icon: Icon(
                                  v.isPlaying
                                      ? Icons.pause_rounded
                                      : Icons.play_arrow_rounded,
                                  color: Colors.white,
                                  size: 30,
                                ),
                              ),
                              const SizedBox(width: 2),
                              Text(
                                _clock(v.position),
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                ),
                              ),
                              const Spacer(),
                              Text(
                                _clock(v.duration),
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 12,
                                ),
                              ),
                              const SizedBox(width: 6),
                              TextButton(
                                onPressed: _chooseSpeed,
                                style: TextButton.styleFrom(
                                  foregroundColor: Colors.white,
                                  minimumSize: const Size(42, 38),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 4,
                                  ),
                                ),
                                child: Text(
                                  _speed == 1 ? '1x' : '${_speed}x',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _seekOverlay() {
    final right = _seekSeconds > 0;
    return IgnorePointer(
      child: Align(
        alignment: right ? const Alignment(.55, 0) : const Alignment(-.55, 0),
        child: Container(
          width: 82,
          height: 82,
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: .48),
            shape: BoxShape.circle,
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                right ? Icons.forward_10_rounded : Icons.replay_10_rounded,
                color: Colors.white,
                size: 34,
              ),
              const Text(
                '10 s',
                style: TextStyle(color: Colors.white, fontSize: 11),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _errorWidget() => ColoredBox(
    color: Colors.black,
    child: Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.play_circle_outline_rounded,
              color: Colors.white70,
              size: 56,
            ),
            const SizedBox(height: 14),
            Text(
              _error!,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 18),
            if (_errorDetails != null && _errorDetails!.isNotEmpty) ...[
              Text(
                _errorDetails!,
                textAlign: TextAlign.center,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white54, fontSize: 12),
              ),
              const SizedBox(height: 14),
            ],
            FilledButton.icon(
              onPressed: () => _prepare(_file, refreshRemote: true),
              icon: const Icon(Icons.refresh),
              label: const Text('Tentar novamente'),
            ),
            if (_file.isVideo)
              TextButton.icon(
                onPressed: () => _prepare(
                  _file,
                  forceLocal: true,
                  refreshRemote: true,
                  repairLocal: true,
                ),
                icon: const Icon(Icons.download_rounded),
                label: const Text('Baixar e reproduzir'),
              ),
          ],
        ),
      ),
    ),
  );
}

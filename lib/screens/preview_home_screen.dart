import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_document_scanner/google_mlkit_document_scanner.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:open_filex/open_filex.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/tcloud_theme.dart';
import '../design_system/tcloud_design_system.dart';
import '../models/tcloud_file.dart';
import '../models/tcloud_folder.dart';
import '../models/tcloud_transfer.dart';
import '../services/gallery_sync_service.dart';
import '../services/tcloud_repository.dart';
import '../services/account_service.dart';
import '../services/transfer_center.dart';
import '../services/thumbnail_cache_service.dart';
import '../telegram/tdlib_service.dart';
import 'login_screen.dart';
import 'media_viewer_screen.dart';

import 'update_screen.dart';
import 'sync_queue_screen.dart';

import '../services/app_update_service.dart';
import 'folder_screen.dart';
import 'gallery_folders_screen.dart';
import 'integrity_center_screen.dart';
import '../services/media_cache_policy.dart';
import '../services/library_preferences_service.dart';
import '../services/tcloud_device_auth.dart';
import '../services/biometric_lock_service.dart';
import '../services/tcloud_foundation5_bridge.dart';

import '../widgets/tcloud_theme_selector.dart';

// TCLOUD_MOBILE_THEME_CONTROL_202
class PreviewHomeScreen extends StatefulWidget {
  const PreviewHomeScreen({super.key});

  @override
  State<PreviewHomeScreen> createState() => _PreviewHomeScreenState();
}

class _PreviewHomeScreenState extends State<PreviewHomeScreen>
    with WidgetsBindingObserver {
  final _repo = TCloudRepository.instance;
  final _sync = GallerySyncService.instance;
  final _libraryPrefs = LibraryPreferencesService.instance;
  final _folderSearchController = TextEditingController();
  int _currentIndex = 0;

  bool _loadingFolders = true;
  bool _syncingGallery = false;
  final bool _loadingFullAlbum = false;
  String _selectedFolderKey = 'all';
  String _deviceSpace = 'all';
  bool _startupUpdateChecked = false;
  DateTime? _lastUpdateCheckAt;
  bool _showAllAlbums = false;
  String _folderQuery = '';
  bool _filesGrid = false;
  String _filesFilter = 'Todos';
  String _homeFilesFilter = 'Todos';
  String _homeFilesSort = 'Mais recentes';
  int _homeGridColumns = 3;
  bool _hideHomePreviews = false;
  String _homeDateFilter = 'Qualquer data';
  String _homeSizeFilter = 'Qualquer tamanho';
  List<String> _homeSearchHistory = <String>[];
  Set<String> _resumableVideoIds = <String>{};
  bool _showMediaSearch = false;
  String _mediaQuery = '';

  List<TCloudFolder> _folders = <TCloudFolder>[];
  List<TCloudFile> _media = <TCloudFile>[];
  List<TCloudFile> _allFiles = <TCloudFile>[];
  List<TCloudFile> _offline = <TCloudFile>[];
  Set<String> _favorites = <String>{};
  Set<String> _trash = <String>{};
  int _mediaLoadGeneration = 0;

  final Set<int> _selectedMediaIds = <int>{};
  Set<int> _homeVisibleFileIds = <int>{};

  bool get _mediaSelectionMode => _selectedMediaIds.isNotEmpty;

  final ScrollController _mediaScrollController = ScrollController();
  final PageController _recentCarouselController = PageController(
    viewportFraction: .88,
  );
  Timer? _recentCarouselTimer;
  bool _recentCarouselInteracting = false;
  int _recentCarouselItemCount = 0;

  Timer? _mediaDragAutoScrollTimer;
  Offset? _mediaDragLastGlobalPosition;
  double _mediaDragAutoScrollVelocity = 0;

  final Map<String, GlobalKey> _mediaDragTileKeys = <String, GlobalKey>{};

  final Set<String> _mediaDragVisited = <String>{};

  bool _mediaDragActive = false;
  bool _mediaDragSelectValue = true;

  String _mediaDragIdentity(TCloudFile file) {
    return '${file.chatId}:${file.messageId}:${file.fileId}';
  }

  GlobalKey _mediaDragTileKey(TCloudFile file) {
    final identity = _mediaDragIdentity(file);

    return _mediaDragTileKeys.putIfAbsent(identity, GlobalKey.new);
  }

  TCloudFile? _mediaAtGlobalPosition(Offset globalPosition) {
    for (final file in _media) {
      final key = _mediaDragTileKeys[_mediaDragIdentity(file)];

      final context = key?.currentContext;
      if (context == null) continue;

      final renderObject = context.findRenderObject();

      if (renderObject is! RenderBox || !renderObject.hasSize) {
        continue;
      }

      final topLeft = renderObject.localToGlobal(Offset.zero);

      final rect = topLeft & renderObject.size;

      if (rect.contains(globalPosition)) {
        return file;
      }
    }

    return null;
  }

  void _applyDragSelection(TCloudFile file) {
    final identity = _mediaDragIdentity(file);

    if (!_mediaDragVisited.add(identity)) {
      return;
    }

    setState(() {
      if (_mediaDragSelectValue) {
        _selectedMediaIds.add(file.fileId);
      } else {
        _selectedMediaIds.remove(file.fileId);
      }
    });
  }

  void _beginMediaDragSelection(TCloudFile file) {
    unawaited(HapticFeedback.selectionClick());
    _mediaDragActive = true;
    _mediaDragVisited.clear();

    _mediaDragSelectValue = !_selectedMediaIds.contains(file.fileId);

    _applyDragSelection(file);
  }

  void _updateMediaDragSelection(Offset globalPosition) {
    if (!_mediaDragActive) return;

    final file = _mediaAtGlobalPosition(globalPosition);

    if (file == null) return;

    _applyDragSelection(file);
  }

  void _stopMediaDragAutoScroll() {
    _mediaDragAutoScrollTimer?.cancel();
    _mediaDragAutoScrollTimer = null;
    _mediaDragAutoScrollVelocity = 0;
    _mediaDragLastGlobalPosition = null;
  }

  void _updateMediaDragAutoScroll(Offset globalPosition) {
    _mediaDragLastGlobalPosition = globalPosition;

    if (!_mediaDragActive || !_mediaScrollController.hasClients) {
      _stopMediaDragAutoScroll();
      return;
    }

    final mediaQuery = MediaQuery.of(context);

    const edgeSize = 112.0;

    final topEdge = mediaQuery.padding.top + edgeSize;

    final bottomEdge =
        mediaQuery.size.height - mediaQuery.padding.bottom - edgeSize;

    double velocity = 0;

    if (globalPosition.dy < topEdge) {
      final strength = ((topEdge - globalPosition.dy) / edgeSize).clamp(
        0.0,
        1.0,
      );

      velocity = -(7 + (27 * strength));
    } else if (globalPosition.dy > bottomEdge) {
      final strength = ((globalPosition.dy - bottomEdge) / edgeSize).clamp(
        0.0,
        1.0,
      );

      velocity = 7 + (27 * strength);
    }

    _mediaDragAutoScrollVelocity = velocity;

    if (velocity == 0) {
      _mediaDragAutoScrollTimer?.cancel();
      _mediaDragAutoScrollTimer = null;
      return;
    }

    _mediaDragAutoScrollTimer ??= Timer.periodic(
      const Duration(milliseconds: 16),
      (_) {
        if (!mounted ||
            !_mediaDragActive ||
            !_mediaScrollController.hasClients) {
          _stopMediaDragAutoScroll();
          return;
        }

        final position = _mediaScrollController.position;

        final next = (position.pixels + _mediaDragAutoScrollVelocity)
            .clamp(position.minScrollExtent, position.maxScrollExtent)
            .toDouble();

        if ((next - position.pixels).abs() < 0.25) {
          return;
        }

        _mediaScrollController.jumpTo(next);

        final finger = _mediaDragLastGlobalPosition;

        if (finger != null) {
          _updateMediaDragSelection(finger);
        }
      },
    );
  }

  void _endMediaDragSelection() {
    _stopMediaDragAutoScroll();
    _mediaDragActive = false;
    _mediaDragVisited.clear();
  }

  @override
  void initState() {
    // TCLOUD_MEDIA_MANAGER_90_HOME_OPTIMIZE
    unawaited(MediaCachePolicy.instance.optimize());

    super.initState();

    unawaited(_loadHomeDisplayPreferences());

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _checkForUpdatePopup();
      if (!mounted || await TCloudDeviceAuth.instance.validate()) return;
      await Future<void>.delayed(const Duration(milliseconds: 450));
      if (mounted) await _showDevicePairing();
    });
    WidgetsBinding.instance.addObserver(this);
    _recentCarouselTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted ||
          _recentCarouselInteracting ||
          !_recentCarouselController.hasClients ||
          _recentCarouselItemCount < 2) {
        return;
      }
      final current = (_recentCarouselController.page ?? 0).round();
      final count = _recentCarouselItemCount;
      if (count < 2) return;
      _recentCarouselController.animateToPage(
        (current + 1) % count,
        duration: const Duration(milliseconds: 680),
        curve: Curves.easeInOutCubic,
      );
    });

    _loadEverything().then((_) async {
      await _consumeSharedFiles();
      await _autoSyncGallery();
    });
  }

  Future<void> _loadHomeDisplayPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    final columns = (prefs.getInt('tcloud:home-grid-columns') ?? 3).clamp(2, 4);
    final resumable = prefs
        .getKeys()
        .where((key) => key.startsWith('tcloud:video-resume:'))
        .where((key) => (prefs.getInt(key) ?? 0) >= 5000)
        .map((key) => key.substring('tcloud:video-resume:'.length))
        .toSet();
    if (!mounted) return;
    setState(() {
      _homeGridColumns = columns;
      _homeFilesSort =
          prefs.getString('tcloud:home-files-sort') ?? 'Mais recentes';
      _hideHomePreviews = prefs.getBool('tcloud:hide-home-previews') ?? false;
      _homeSearchHistory =
          prefs.getStringList('tcloud:home-search-history') ?? <String>[];
      _resumableVideoIds = resumable;
    });
  }

  Future<void> _setHomeGridColumns(int value) async {
    setState(() => _homeGridColumns = value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('tcloud:home-grid-columns', value);
  }

  Future<void> _setHomeFilesSort(String value) async {
    setState(() => _homeFilesSort = value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('tcloud:home-files-sort', value);
  }

  Future<void> _toggleHomePreviewPrivacy() async {
    setState(() => _hideHomePreviews = !_hideHomePreviews);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('tcloud:hide-home-previews', _hideHomePreviews);
  }

  Future<void> _rememberHomeSearch(String value) async {
    final clean = value.trim();
    if (clean.length < 2) return;
    final next = <String>[
      clean,
      ..._homeSearchHistory.where(
        (item) => item.toLowerCase() != clean.toLowerCase(),
      ),
    ].take(6).toList();
    setState(() => _homeSearchHistory = next);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('tcloud:home-search-history', next);
  }

  Future<void> _showHomeSearchFilters() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) {
          void update(VoidCallback change) {
            setState(change);
            setSheetState(() {});
          }

          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Refinar pesquisa',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 18),
                  const Text('PERÍODO'),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final value in const [
                        'Qualquer data',
                        'Hoje',
                        'Últimos 7 dias',
                        'Últimos 30 dias',
                        'Este ano',
                      ])
                        ChoiceChip(
                          label: Text(value),
                          selected: _homeDateFilter == value,
                          onSelected: (_) =>
                              update(() => _homeDateFilter = value),
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  const Text('TAMANHO'),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final value in const [
                        'Qualquer tamanho',
                        'Até 10 MB',
                        '10 a 100 MB',
                        'Mais de 100 MB',
                      ])
                        ChoiceChip(
                          label: Text(value),
                          selected: _homeSizeFilter == value,
                          onSelected: (_) =>
                              update(() => _homeSizeFilter = value),
                        ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: () => Navigator.pop(sheetContext),
                      child: const Text('Aplicar filtros'),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  void dispose() {
    _stopMediaDragAutoScroll();
    _recentCarouselTimer?.cancel();
    _recentCarouselController.dispose();
    _folderSearchController.dispose();
    _mediaScrollController.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      Future<void>(() async {
        await _consumeSharedFiles();
        await _autoSyncGallery();
        final lastCheck = _lastUpdateCheckAt;
        if (lastCheck == null ||
            DateTime.now().difference(lastCheck) > const Duration(hours: 6)) {
          _startupUpdateChecked = false;
          await _checkForUpdatePopup();
        }
      });
    }
  }

  Future<void> _loadEverything() async {
    await _loadFolders();

    await Future.wait([
      _loadMedia(),
      _loadOffline(),
      _loadFavorites(),
      _loadTrash(),
    ]);
  }

  Future<void> _loadFavorites() async {
    final values = await _libraryPrefs.favorites();
    if (mounted) setState(() => _favorites = values);
  }

  Future<void> _loadTrash() async {
    final values = await _libraryPrefs.trash();
    if (mounted) setState(() => _trash = values);
  }

  Future<void> _loadFolders() async {
    if (mounted) {
      setState(() => _loadingFolders = true);
    }

    final cached = await _repo.loadCachedFolders();

    if (cached.isNotEmpty && mounted) {
      setState(() => _folders = cached);
    }

    try {
      final fresh = await _repo.discoverFolders();

      if (!mounted) return;

      setState(() {
        _folders = fresh;
        _loadingFolders = false;

        if (_selectedFolderKey != 'all' &&
            !_folders.any((folder) => folder.cacheKey == _selectedFolderKey)) {
          _selectedFolderKey = 'all';
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingFolders = false);
    }
  }

  Future<void> _loadMedia() async {
    final generation = ++_mediaLoadGeneration;
    if (_folders.isEmpty) {
      if (mounted) setState(() => _media = <TCloudFile>[]);
      return;
    }
    final requested = _selectedFolderKey == 'all'
        ? _folders
        : _folders.where((f) => f.cacheKey == _selectedFolderKey).toList();
    final uniqueFolders = <String, TCloudFolder>{};
    for (final f in requested) {
      uniqueFolders.putIfAbsent(f.cacheKey, () => f);
    }
    final folders = uniqueFolders.values.toList();
    final allFolders = _selectedFolderKey == 'all';
    final collected = <String, TCloudFile>{};
    final allCollected = <String, TCloudFile>{};

    void collect(Iterable<TCloudFile> files) {
      for (final file in files) {
        allCollected[file.contentIdentity] = file;
        if (file.isMedia) collected[file.contentIdentity] = file;
      }
    }

    void publish() {
      if (!mounted || generation != _mediaLoadGeneration) return;
      final sorted = collected.values.toList()
        ..sort((a, b) {
          final d = b.createdAt.compareTo(a.createdAt);
          return d != 0 ? d : b.messageId.compareTo(a.messageId);
        });
      final allSorted = allCollected.values.toList()
        ..sort((a, b) {
          final d = b.createdAt.compareTo(a.createdAt);
          return d != 0 ? d : b.messageId.compareTo(a.messageId);
        });
      setState(() {
        _media = sorted.take(allFolders ? 120 : 160).toList();
        _allFiles = allSorted;
      });
    }

    // Mostra primeiro o catálogo local. A rede atualiza cada bloco depois,
    // sem manter a grade vazia durante várias consultas ao Telegram.
    for (var offset = 0; offset < folders.length; offset += 16) {
      final end = (offset + 16).clamp(0, folders.length);
      final cachedPages = await Future.wait(
        folders.sublist(offset, end).map(_repo.loadCachedFilePage),
      );
      if (generation != _mediaLoadGeneration) return;
      for (final page in cachedPages) {
        collect(page.files);
      }
      publish();
    }

    final liveFolders = allFolders ? folders.take(12).toList() : folders;
    for (var offset = 0; offset < liveFolders.length; offset += 4) {
      final end = (offset + 4).clamp(0, liveFolders.length);
      final batch = liveFolders.sublist(offset, end);
      final pages = await Future.wait(
        batch.map((folder) async {
          // TCLOUD_EXISTING_MEDIA_LIVE_REFRESH_1046
          // O cache continua sendo fallback, mas nunca mais impede a consulta
          // viva. Isso faz imagens/videos ja existentes no Telegram aparecerem
          // mesmo quando a pasta foi carregada anteriormente com cache antigo.
          try {
            return await _repo.loadFilePage(
              folder,
              limit: allFolders ? 36 : 100,
            );
          } catch (_) {
            return null;
          }
        }),
      );
      if (generation != _mediaLoadGeneration) return;
      for (final page in pages) {
        if (page != null) collect(page.files);
      }
      publish();
      await Future<void>.delayed(Duration.zero);
    }
  }

  void _toggleMediaSelection(TCloudFile file) {
    setState(() {
      if (!_selectedMediaIds.add(file.fileId)) {
        _selectedMediaIds.remove(file.fileId);
      }
    });
  }

  void _clearMediaSelection() {
    setState(_selectedMediaIds.clear);
  }

  void _selectAllVisibleHomeFiles() {
    setState(() => _selectedMediaIds.addAll(_homeVisibleFileIds));
  }

  Future<void> _favoriteSelectedMedia() async {
    final selected = _selectedMedia;
    if (selected.isEmpty) return;
    for (final file in selected) {
      if (!_favorites.contains(file.contentIdentity)) {
        await _libraryPrefs.toggleFavorite(file);
      }
    }
    await _loadFavorites();
    _clearMediaSelection();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${selected.length} item(ns) favoritado(s).')),
    );
  }

  List<TCloudFile> get _selectedMedia {
    return _allFiles
        .where((file) => _selectedMediaIds.contains(file.fileId))
        .toList();
  }

  Future<void> _openHomeFile(
    TCloudFile file,
    List<TCloudFile> visibleFiles,
  ) async {
    if (file.isMedia) {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => MediaViewerScreen(
            file: file,
            files: visibleFiles.where((item) => item.isMedia).toList(),
          ),
        ),
      );
      await _loadHomeDisplayPreferences();
      return;
    }

    try {
      var path = file.localPath;
      if (path == null || path.isEmpty || !File(path).existsSync()) {
        path = await _repo.download(file);
      }
      await OpenFilex.open(path);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Não foi possível abrir ${file.name}: $error')),
      );
    }
  }

  Future<String?> _askAlbumName() async {
    if (!mounted) return null;

    var draft = '';

    late final DialogRoute<String> route;

    route = DialogRoute<String>(
      context: context,
      barrierDismissible: true,
      builder: (dialogContext) {
        void closeWith(String? value) {
          FocusScope.of(dialogContext).unfocus();

          final clean = value?.trim();

          Navigator.of(
            dialogContext,
          ).pop(clean == null || clean.isEmpty ? null : clean);
        }

        return AlertDialog(
          title: const Text('Novo álbum'),
          content: TextField(
            autofocus: true,
            maxLength: 128,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Nome do álbum',
              hintText: 'Ex.: Viagens',
            ),
            onChanged: (value) {
              draft = value;
            },
            onSubmitted: closeWith,
          ),
          actions: [
            TextButton(
              onPressed: () => closeWith(null),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () => closeWith(draft),
              child: const Text('Criar'),
            ),
          ],
        );
      },
    );

    final navigator = Navigator.of(context, rootNavigator: true);

    final value = await navigator.push<String>(route);

    // Aguarda a animacao de saida e a remocao completa do overlay.
    // Isso evita reconstruir Albuns enquanto o dialogo ainda possui
    // dependencias ativas no framework.
    await route.completed;

    if (!mounted) return null;

    final clean = value?.trim();

    if (clean == null || clean.isEmpty) {
      return null;
    }

    return clean;
  }

  Future<TCloudFolder?> _createAlbum() async {
    if (_folders.isEmpty) return null;

    final name = await _askAlbumName();

    if (name == null) return null;

    TCloudFolder base = _folders.first;

    if (_selectedFolderKey != 'all') {
      for (final folder in _folders) {
        if (folder.cacheKey == _selectedFolderKey) {
          base = folder;
          break;
        }
      }
    }

    try {
      final created = await _repo.createFolderAndReturn(
        chatId: base.chatId,
        forumTitle: base.forumTitle,
        name: name,
      );

      await _loadFolders();

      if (!mounted) return created;

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Pasta "$name" criada.')));

      return created;
    } catch (error) {
      if (!mounted) return null;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Nao foi possivel criar a pasta: $error')),
      );

      return null;
    }
  }

  Future<TCloudFolder?> _chooseMoveDestination() async {
    if (_folders.isEmpty) return null;

    final selectedFiles = _selectedMedia;

    return showModalBottomSheet<TCloudFolder>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        return SafeArea(
          child: SizedBox(
            height: MediaQuery.sizeOf(sheetContext).height * .62,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 2, 8, 8),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Mover para',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      TextButton.icon(
                        onPressed: () async {
                          Navigator.pop(sheetContext);

                          final created = await _createAlbum();

                          if (created == null || selectedFiles.isEmpty) {
                            return;
                          }

                          await _moveFilesTo(selectedFiles, created);
                        },
                        icon: const Icon(Icons.create_new_folder_outlined),
                        label: const Text('Novo'),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    itemCount: _folders.length,
                    itemBuilder: (context, index) {
                      final folder = _folders[index];

                      return ListTile(
                        leading: Icon(
                          Icons.folder_outlined,
                          color: TCloudTheme.primary,
                        ),
                        title: Text(folder.title),
                        subtitle: Text(folder.forumTitle),
                        onTap: () {
                          Navigator.pop(sheetContext, folder);
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _moveFilesTo(
    List<TCloudFile> files,
    TCloudFolder destination,
  ) async {
    try {
      await _repo.moveFiles(files, destination);

      _clearMediaSelection();

      await _loadMedia();

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${files.length} arquivo(s) movido(s) '
            'para ${destination.title}.',
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Nao foi possivel mover: $error')));
    }
  }

  Future<void> _moveSelectedMedia() async {
    final selected = _selectedMedia;

    if (selected.isEmpty) return;

    final destination = await _chooseMoveDestination();

    if (destination == null) return;

    await _moveFilesTo(selected, destination);
  }

  Future<void> _deleteSelectedMedia() async {
    final selected = _selectedMedia;

    if (selected.isEmpty) return;

    final confirmed =
        await showDialog<bool>(
          context: context,
          builder: (dialogContext) {
            return AlertDialog(
              title: Text(
                selected.length == 1
                    ? 'Excluir arquivo?'
                    : 'Excluir ${selected.length} arquivos?',
              ),
              content: const Text(
                'Os itens tambem serao excluidos do Telegram.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: const Text('Cancelar'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(dialogContext, true),
                  child: const Text('Excluir'),
                ),
              ],
            );
          },
        ) ??
        false;

    if (!confirmed) return;

    try {
      await _repo.deleteFiles(selected);

      _clearMediaSelection();

      await _loadMedia();

      if (!mounted) return;

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Arquivos excluidos.')));
    } catch (error) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Nao foi possivel excluir: $error')),
      );
    }
  }

  String _humanSize(int bytes) {
    if (bytes <= 0) return '0 B';

    final kb = bytes / 1024;
    if (kb < 1024) {
      return '${kb.toStringAsFixed(1)} KB';
    }

    final mb = kb / 1024;
    if (mb < 1024) {
      return '${mb.toStringAsFixed(1)} MB';
    }

    return '${(mb / 1024).toStringAsFixed(1)} GB';
  }

  String _fileDate(TCloudFile file) {
    if (file.createdAt <= 0) {
      return 'Data desconhecida';
    }

    final date = DateTime.fromMillisecondsSinceEpoch(
      file.createdAt * 1000,
    ).toLocal();

    String two(int value) => value.toString().padLeft(2, '0');

    return '${two(date.day)}/${two(date.month)}/${date.year} '
        '${two(date.hour)}:${two(date.minute)}';
  }

  Future<void> _showMediaInfo(TCloudFile file) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        final path = file.localPath;

        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  file.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 14),
                _FileInfoRow(label: 'Tipo', value: file.mimeType ?? file.kind),
                _FileInfoRow(label: 'Tamanho', value: _humanSize(file.size)),
                _FileInfoRow(label: 'Data', value: _fileDate(file)),
                if (file.isVideo && file.durationSeconds > 0)
                  _FileInfoRow(
                    label: 'Duracao',
                    value:
                        '${file.durationSeconds ~/ 60}:'
                        '${(file.durationSeconds % 60).toString().padLeft(2, '0')}',
                  ),
                _FileInfoRow(
                  label: 'Disponibilidade',
                  value: file.downloaded ? 'No dispositivo' : 'Na nuvem',
                ),
                if (path != null && path.isNotEmpty)
                  _FileInfoRow(label: 'Arquivo local', value: path),
                _FileInfoRow(label: 'ID Telegram', value: '${file.messageId}'),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _shareSelectedMedia() async {
    final selected = _selectedMedia;
    if (selected.isEmpty) return;

    try {
      final paths = <String>[];
      for (final file in selected) {
        var path = file.localPath;
        if (path == null || path.isEmpty || !File(path).existsSync()) {
          path = await _repo.download(file);
        }
        paths.add(path);
      }
      await TdlibService.instance.shareFiles(paths);
    } catch (error) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Nao foi possivel compartilhar: $error')),
      );
    }
  }

  Future<void> _shareFile(TCloudFile file) async {
    try {
      var path = file.localPath;
      if (path == null || path.isEmpty || !File(path).existsSync()) {
        path = await _repo.download(file);
      }
      await TdlibService.instance.shareFile(path, mimeType: file.mimeType);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Não foi possível compartilhar: $error')),
      );
    }
  }

  Future<void> _makeFileOffline(TCloudFile file) async {
    try {
      final path = await _repo.download(file);
      await _repo.rememberOffline(
        file.copyWith(localPath: path, downloaded: true),
      );
      await _loadOffline();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${file.name} está disponível offline.')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Não foi possível baixar: $error')),
      );
    }
  }

  Future<void> _showDriveFileActions(TCloudFile file) async {
    final isOffline = _offline.any(
      (item) => item.contentIdentity == file.contentIdentity,
    );
    final isFavorite = _favorites.contains(file.contentIdentity);
    final isTrashed = _trash.contains(file.contentIdentity);
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(
                isTrashed
                    ? Icons.restore_from_trash_outlined
                    : Icons.delete_outline,
              ),
              title: Text(
                isTrashed ? 'Restaurar da lixeira' : 'Mover para a lixeira',
              ),
              subtitle: const Text('O arquivo não é apagado imediatamente.'),
              onTap: () =>
                  Navigator.pop(sheetContext, isTrashed ? 'restore' : 'trash'),
            ),
            ListTile(
              leading: Icon(
                isFavorite ? Icons.star_rounded : Icons.star_border_rounded,
              ),
              title: Text(
                isFavorite
                    ? 'Remover dos favoritos'
                    : 'Adicionar aos favoritos',
              ),
              onTap: () => Navigator.pop(sheetContext, 'favorite'),
            ),
            ListTile(
              leading: const Icon(Icons.info_outline_rounded),
              title: const Text('Detalhes e informações'),
              onTap: () => Navigator.pop(sheetContext, 'info'),
            ),
            ListTile(
              leading: const Icon(Icons.share_outlined),
              title: const Text('Compartilhar uma cópia'),
              onTap: () => Navigator.pop(sheetContext, 'share'),
            ),
            ListTile(
              leading: Icon(
                isOffline ? Icons.cloud_outlined : Icons.offline_pin_outlined,
              ),
              title: Text(
                isOffline ? 'Remover do dispositivo' : 'Disponibilizar offline',
              ),
              subtitle: Text(
                isOffline
                    ? 'O arquivo continuará no TCloud.'
                    : 'Abra mesmo quando estiver sem internet.',
              ),
              onTap: () => Navigator.pop(
                sheetContext,
                isOffline ? 'removeOffline' : 'offline',
              ),
            ),
          ],
        ),
      ),
    );

    if (!mounted || action == null) return;
    if (action == 'favorite') {
      final added = await _libraryPrefs.toggleFavorite(file);
      await _loadFavorites();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            added ? 'Adicionado aos favoritos.' : 'Removido dos favoritos.',
          ),
        ),
      );
    }
    if (action == 'trash') {
      await _libraryPrefs.moveToTrash([file]);
      await _loadTrash();
    }
    if (action == 'restore') {
      await _libraryPrefs.restoreFromTrash([file]);
      await _loadTrash();
    }
    if (action == 'info') await _showMediaInfo(file);
    if (action == 'share') await _shareFile(file);
    if (action == 'offline') await _makeFileOffline(file);
    if (action == 'removeOffline') {
      await _repo.removeOffline(file);
      await _loadOffline();
    }
  }

  Future<void> _offlineSelectedMedia() async {
    final selected = _selectedMedia;
    if (selected.isEmpty) return;

    for (final file in selected) {
      try {
        final path = await _repo.download(file);

        await _repo.rememberOffline(
          file.copyWith(localPath: path, downloaded: true),
        );
      } catch (_) {}
    }

    await _loadOffline();

    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('${selected.length} item(ns) disponivel(is) offline.'),
      ),
    );
  }

  Future<void> _loadOffline() async {
    final files = await _repo.loadOffline();

    if (!mounted) return;

    setState(() => _offline = files);
  }

  Future<void> _openOffline(TCloudFile file) async {
    final path = file.localPath;

    if (path == null || path.isEmpty) return;

    if (file.isMedia) {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => MediaViewerScreen(
            file: file,
            files: _offline.where((item) => item.isMedia).toList(),
          ),
        ),
      );

      return;
    }

    await OpenFilex.open(path);
  }

  Future<TCloudFolder?> _chooseDestination({
    String title = 'Enviar para',
  }) async {
    if (_folders.isEmpty) {
      return null;
    }

    return showModalBottomSheet<TCloudFolder>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        return SafeArea(
          child: SizedBox(
            height: MediaQuery.sizeOf(context).height * .58,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 4, 18, 10),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      title,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    itemCount: _folders.length,
                    itemBuilder: (context, index) {
                      final folder = _folders[index];

                      return ListTile(
                        leading: Icon(
                          Icons.folder_outlined,
                          color: TCloudTheme.primary,
                        ),
                        title: Text(folder.title),
                        subtitle: Text(folder.forumTitle),
                        onTap: () {
                          Navigator.pop(context, folder);
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _uploadPaths(List<String> paths, TCloudFolder folder) async {
    for (final path in paths) {
      final name = path.replaceAll('\\', '/').split('/').last;

      final transfer = TCloudTransfer(
        name: name,
        direction: 'upload',
        status: TCloudTransferStatus.running,
      );

      TransferCenter.instance.add(transfer);

      try {
        await _repo.upload(folder: folder, path: path);

        transfer.status = TCloudTransferStatus.completed;
      } catch (error) {
        transfer.status = TCloudTransferStatus.failed;
        transfer.error = error.toString();
      }

      TransferCenter.instance.changed();
    }

    await _loadMedia();
  }

  Future<void> _importFiles() async {
    final destination = await _chooseDestination(
      title: 'Enviar para qual pasta?',
    );

    if (destination == null || !mounted) return;

    final paths = await TdlibService.instance.pickFiles();

    if (paths.isEmpty || !mounted) return;

    await _uploadPaths(paths, destination);

    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          paths.length == 1
              ? 'Arquivo enviado para ${destination.title}.'
              : '${paths.length} arquivos enviados para ${destination.title}.',
        ),
      ),
    );
  }

  String _scannerPath(String value) {
    final uri = Uri.tryParse(value);
    if (uri != null && uri.scheme == 'file') return uri.toFilePath();
    return value;
  }

  Future<void> _scanDocument() async {
    final scanner = DocumentScanner(
      options: DocumentScannerOptions(
        documentFormats: const {DocumentFormat.jpeg, DocumentFormat.pdf},
        pageLimit: 25,
        mode: ScannerMode.full,
        isGalleryImport: true,
      ),
    );

    try {
      final result = await scanner.scanDocument();
      final images = (result.images ?? const <String>[])
          .map(_scannerPath)
          .where((path) => path.isNotEmpty)
          .toList();
      final pdf = result.pdf == null ? null : _scannerPath(result.pdf!.uri);
      if (!mounted || (images.isEmpty && (pdf == null || pdf.isEmpty))) return;

      final action = await showModalBottomSheet<String>(
        context: context,
        showDragHandle: true,
        useSafeArea: true,
        builder: (sheetContext) => Wrap(
          children: [
            ListTile(
              title: Text(
                '${images.length} pagina(s) digitalizada(s)',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              subtitle: const Text(
                'Bordas, perspectiva e contraste foram corrigidos.',
              ),
            ),
            if (pdf != null && pdf.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.picture_as_pdf_outlined),
                title: const Text('Salvar PDF no TCloud'),
                onTap: () => Navigator.pop(sheetContext, 'pdf'),
              ),
            if (images.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.photo_library_outlined),
                title: const Text('Salvar paginas como imagens'),
                onTap: () => Navigator.pop(sheetContext, 'images'),
              ),
            if (images.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.document_scanner_outlined),
                title: const Text('Extrair texto (OCR)'),
                subtitle: const Text(
                  'Reconhece texto em portugues no aparelho.',
                ),
                onTap: () => Navigator.pop(sheetContext, 'ocr'),
              ),
          ],
        ),
      );
      if (!mounted || action == null) return;

      if (action == 'ocr') {
        await _recognizeScannedText(images);
        return;
      }

      final destination = await _chooseDestination(
        title: 'Salvar documento em qual pasta?',
      );
      if (destination == null || !mounted) return;
      final paths = action == 'pdf' && pdf != null ? <String>[pdf] : images;
      await _uploadPaths(paths, destination);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Documento salvo em ${destination.title}.')),
      );
    } on PlatformException catch (error) {
      if (!mounted || error.code == 'CANCELLED') return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Nao foi possivel digitalizar: ${error.message}'),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Nao foi possivel digitalizar: $error')),
      );
    } finally {
      await scanner.close();
    }
  }

  Future<void> _recognizeScannedText(List<String> images) async {
    final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
    try {
      final parts = <String>[];
      for (final path in images) {
        final result = await recognizer.processImage(
          InputImage.fromFilePath(path),
        );
        if (result.text.trim().isNotEmpty) parts.add(result.text.trim());
      }
      if (!mounted) return;
      final text = parts.join('\n\n');
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        useSafeArea: true,
        builder: (sheetContext) => SizedBox(
          height: MediaQuery.sizeOf(sheetContext).height * .78,
          child: Column(
            children: [
              ListTile(
                title: const Text(
                  'Texto reconhecido',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                subtitle: Text('${text.length} caracteres'),
                trailing: IconButton(
                  tooltip: 'Copiar texto',
                  onPressed: text.isEmpty
                      ? null
                      : () async {
                          await Clipboard.setData(ClipboardData(text: text));
                          if (sheetContext.mounted) Navigator.pop(sheetContext);
                        },
                  icon: const Icon(Icons.copy_all_outlined),
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(18),
                  child: SelectableText(
                    text.isEmpty ? 'Nenhum texto foi encontrado.' : text,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    } finally {
      await recognizer.close();
    }
  }

  Future<void> _consumeSharedFiles() async {
    final paths = await TdlibService.instance.takePendingSharedFiles();

    if (paths.isEmpty || !mounted) return;

    final destination = await _chooseDestination(
      title: paths.length == 1
          ? 'Enviar arquivo compartilhado para'
          : 'Enviar ${paths.length} arquivos para',
    );

    if (destination == null) return;

    await _uploadPaths(paths, destination);

    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('${paths.length} arquivo(s) recebido(s) pelo TCloud.'),
      ),
    );
  }

  Future<void> _autoSyncGallery() async {
    if (_syncingGallery || _folders.isEmpty) return;

    final enabled = await _sync.isEnabled();

    if (!enabled) return;

    await _runGallerySync(showResult: false);
  }

  Future<void> _runGallerySync({bool showResult = true}) async {
    if (_syncingGallery || _folders.isEmpty) {
      return;
    }

    setState(() => _syncingGallery = true);

    try {
      final result = await _sync.syncNow(_folders);

      await _loadFolders();
      await _loadMedia();

      if (!mounted || !showResult) {
        return;
      }

      String message;

      if (result.failed > 0 || result.pending > 0) {
        final lastError = await _sync.lastBackupError();

        message =
            'Backup: ${result.uploaded} enviado(s), '
            '${result.failed} falha(s), '
            '${result.pending} pendente(s).';

        if (lastError != null && lastError.trim().isNotEmpty) {
          message += '\nUltimo erro: $lastError';
        }
      } else if (result.uploaded > 0) {
        message = '${result.uploaded} nova(s) midia(s) sincronizada(s).';
      } else {
        message = 'Nenhuma midia nova para enviar.';
      }

      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 8)),
      );
    } on GallerySyncRateLimitException catch (error) {
      if (!mounted || !showResult) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_sync.rateLimitMessage(error.until)),
          duration: const Duration(seconds: 8),
        ),
      );
    } catch (error) {
      final limitedUntil = await _sync.registerRateLimit(error);
      if (!mounted || !showResult) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            limitedUntil != null
                ? _sync.rateLimitMessage(limitedUntil)
                : 'Não foi possível concluir o backup agora. Os arquivos foram mantidos na fila para uma nova tentativa.',
          ),
          duration: const Duration(seconds: 8),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _syncingGallery = false);
      }
    }
  }

  Future<void> _configureGallerySync(bool enabled) async {
    if (!enabled) {
      await _sync.setEnabled(false);
      if (mounted) setState(() {});
      return;
    }
    final permission = await TdlibService.instance.requestMediaPermission();
    if (!permission) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Permita o acesso a fotos e videos para ativar o backup.',
          ),
        ),
      );
      return;
    }
    if (_folders.isEmpty) await _loadFolders();
    if (!mounted) return;
    if (_folders.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Nao foi possivel localizar o armazenamento do TCloud.',
          ),
        ),
      );
      return;
    }
    var base = _folders.first;
    for (final folder in _folders) {
      if (folder.isGeneral) {
        base = folder;
        break;
      }
    }
    await _sync.setTargetFolder(base);
    await TdlibService.instance.requestBackupNotifications();
    await _sync.setEnabled(true);
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Backup ativado. As pastas da galeria serao organizadas automaticamente no TCloud.',
        ),
      ),
    );
    await _runGallerySync(showResult: false);
  }

  String _formatCacheBytes(dynamic raw) {
    final bytes = raw is num
        ? raw.toInt()
        : int.tryParse(raw?.toString() ?? '') ?? 0;
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(0)} KB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  Future<void> _openSmartStorage() async {
    var limit = await _sync.cacheLimitMb();
    var info = await _sync.cacheInfo();
    final cloudBytes = _allFiles.fold<int>(
      0,
      (total, file) => total + file.size,
    );
    final offlineBytes = _offline.fold<int>(
      0,
      (total, file) => total + file.size,
    );
    final largeFiles = _allFiles
        .where((file) => file.size > 100 * 1024 * 1024)
        .length;
    final oldThreshold =
        DateTime.now()
            .subtract(const Duration(days: 365))
            .millisecondsSinceEpoch ~/
        1000;
    final oldFiles = _allFiles
        .where((file) => file.createdAt > 0 && file.createdAt < oldThreshold)
        .length;
    final duplicateGroups = <String, List<TCloudFile>>{};
    for (final file in _allFiles) {
      duplicateGroups
          .putIfAbsent(
            '${file.name.trim().toLowerCase()}:${file.size}',
            () => [],
          )
          .add(file);
    }
    final duplicates = duplicateGroups.values.where(
      (group) => group.length > 1,
    );
    final duplicateCount = duplicates.fold<int>(
      0,
      (total, group) => total + group.length - 1,
    );
    final duplicateBytes = duplicates.fold<int>(
      0,
      (total, group) => total + (group.length - 1) * group.first.size,
    );
    if (!mounted) return;

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            return SafeArea(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      'Armazenamento do TCloud',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Cache temporario: ${_formatCacheBytes(info['bytes'])}',
                      style: TextStyle(color: TCloudTheme.textSecondary),
                    ),
                    const SizedBox(height: 16),
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        _StorageMetricCard(
                          label: 'Na nuvem',
                          value: _humanSize(cloudBytes),
                          icon: Icons.cloud_outlined,
                        ),
                        _StorageMetricCard(
                          label: 'Offline',
                          value: _humanSize(offlineBytes),
                          icon: Icons.offline_pin_outlined,
                        ),
                        _StorageMetricCard(
                          label: 'Arquivos grandes',
                          value: '$largeFiles',
                          icon: Icons.data_usage_rounded,
                        ),
                        _StorageMetricCard(
                          label: 'Duplicados',
                          value: '$duplicateCount',
                          icon: Icons.content_copy_rounded,
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.copy_all_outlined),
                      title: Text('$duplicateCount possível(is) duplicado(s)'),
                      subtitle: Text(
                        'Até ${_humanSize(duplicateBytes)} para revisar com segurança.',
                      ),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: duplicateCount == 0
                          ? null
                          : () {
                              Navigator.pop(sheetContext);
                              setState(() {
                                _currentIndex = 0;
                                _homeFilesFilter = 'Duplicados';
                              });
                            },
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.sd_storage_outlined),
                      title: Text('$largeFiles arquivo(s) acima de 100 MB'),
                      subtitle: const Text('Revise os maiores primeiro.'),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: largeFiles == 0
                          ? null
                          : () {
                              Navigator.pop(sheetContext);
                              setState(() {
                                _currentIndex = 0;
                                _homeFilesFilter = 'Todos';
                                _homeSizeFilter = 'Mais de 100 MB';
                                _homeFilesSort = 'Maior tamanho';
                              });
                            },
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.history_rounded),
                      title: Text('$oldFiles arquivo(s) com mais de um ano'),
                      subtitle: const Text(
                        'Informativo; nada será apagado automaticamente.',
                      ),
                    ),
                    const Divider(height: 28),
                    const SizedBox(height: 16),
                    DropdownButtonFormField<int>(
                      initialValue: limit,
                      decoration: const InputDecoration(
                        labelText: 'Limite de cache',
                      ),
                      items: const [
                        DropdownMenuItem(value: 100, child: Text('100 MB')),
                        DropdownMenuItem(value: 250, child: Text('250 MB')),
                        DropdownMenuItem(value: 500, child: Text('500 MB')),
                        DropdownMenuItem(value: 1024, child: Text('1 GB')),
                      ],
                      onChanged: (value) async {
                        if (value == null) return;
                        await _sync.setCacheLimitMb(value);
                        info = await _sync.cacheInfo();
                        setSheetState(() => limit = value);
                      },
                    ),
                    const SizedBox(height: 14),
                    FilledButton.icon(
                      onPressed: () async {
                        info = await _sync.clearCacheNow();
                        setSheetState(() {});
                      },
                      icon: const Icon(Icons.cleaning_services_outlined),
                      label: const Text('Liberar espaco agora'),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'Os originais do celular nao sao apagados. '
                      'Arquivos offline continuam protegidos.',
                      style: TextStyle(
                        color: TCloudTheme.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _chooseBiometricTimeout(int current) async {
    final selected = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(
              title: Text(
                'Bloquear automaticamente',
                style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800),
              ),
            ),
            for (final option in const <(int, String)>[
              (0, 'Imediatamente'),
              (8, 'Após 8 segundos'),
              (30, 'Após 30 segundos'),
              (60, 'Após 1 minuto'),
              (300, 'Após 5 minutos'),
            ])
              ListTile(
                leading: Icon(
                  option.$1 == current
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off,
                ),
                title: Text(option.$2),
                onTap: () => Navigator.pop(sheetContext, option.$1),
              ),
          ],
        ),
      ),
    );
    if (selected == null) return;
    await BiometricLockService.instance.setTimeoutSeconds(selected);
    if (mounted) setState(() {});
  }

  Future<void> _undoGalleryBackup() async {
    final count = await _sync.backupRecordCount();
    if (!mounted) return;

    if (count == 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Nao ha backups rastreados para desfazer.'),
        ),
      );
      return;
    }

    final confirmed =
        await showDialog<bool>(
          context: context,
          builder: (dialogContext) {
            return AlertDialog(
              title: const Text('Desfazer backup da galeria?'),
              content: Text(
                'O backup sera desligado e $count copia(s) enviadas '
                'automaticamente serao removidas do TCloud. '
                'As fotos e videos originais do celular serao mantidos.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: const Text('Cancelar'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(dialogContext, true),
                  child: const Text('Desfazer backup'),
                ),
              ],
            );
          },
        ) ??
        false;

    if (!confirmed) return;

    try {
      final removed = await _sync.undoBackup();
      if (!mounted) return;
      await _loadFolders();
      await _loadMedia();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '$removed copia(s) removida(s). Os originais do celular foram mantidos.',
          ),
        ),
      );
      setState(() {});
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Falha ao desfazer backup: $error')),
      );
    }
  }

  Future<void> _logout() async {
    await TdlibService.instance.logout();

    if (!mounted) return;

    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute<void>(builder: (_) => const LoginScreen()),
      (_) => false,
    );
  }

  Future<String?> _askRenameAlbum(TCloudFolder folder) async {
    final controller = TextEditingController(text: folder.title);

    final value = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Renomear pasta'),
          content: TextField(
            controller: controller,
            autofocus: true,
            maxLength: 128,
            decoration: const InputDecoration(labelText: 'Nome da pasta'),
            onSubmitted: (value) {
              Navigator.pop(dialogContext, value.trim());
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.pop(dialogContext, controller.text.trim());
              },
              child: const Text('Salvar'),
            ),
          ],
        );
      },
    );

    controller.dispose();

    final clean = value?.trim();
    if (clean == null || clean.isEmpty || clean == folder.title) {
      return null;
    }

    return clean;
  }

  Future<void> _renameAlbum(TCloudFolder folder) async {
    final name = await _askRenameAlbum(folder);
    if (name == null) return;

    try {
      await _repo.renameFolder(folder, name);
      await _loadFolders();

      if (!mounted) return;

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Pasta renomeada para "$name".')));
    } catch (error) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Nao foi possivel renomear: $error')),
      );
    }
  }

  Future<void> _deleteAlbum(TCloudFolder folder) async {
    if (folder.isGeneral) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('A pasta Geral do Telegram nao pode ser excluida.'),
        ),
      );
      return;
    }

    final confirmed =
        await showDialog<bool>(
          context: context,
          builder: (dialogContext) {
            return AlertDialog(
              title: Text('Excluir "${folder.title}"?'),
              content: const Text(
                'A pasta/topico sera excluida tambem no Telegram. '
                'Essa acao nao pode ser desfeita pelo TCloud.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: const Text('Cancelar'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(dialogContext, true),
                  child: const Text('Excluir'),
                ),
              ],
            );
          },
        ) ??
        false;

    if (!confirmed) return;

    try {
      await _repo.deleteFolder(folder);

      if (_selectedFolderKey == folder.cacheKey) {
        _selectedFolderKey = 'all';
      }

      await _loadFolders();
      await _loadMedia();

      if (!mounted) return;

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Pasta excluida.')));
    } catch (error) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Nao foi possivel excluir a pasta: $error')),
      );
    }
  }

  Future<void> _showPrimaryActions() async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      useSafeArea: true,
      builder: (sheetContext) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 2, 12, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const ListTile(
                title: Text(
                  'Adicionar ao TCloud',
                  style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
                ),
                subtitle: Text('Escolha o que voce quer fazer.'),
              ),
              ListTile(
                leading: const CircleAvatar(
                  child: Icon(Icons.upload_file_outlined),
                ),
                title: const Text(TCloudLabels.upload),
                subtitle: const Text('Escolha fotos, vídeos ou documentos.'),
                onTap: () => Navigator.pop(sheetContext, 'upload'),
              ),
              ListTile(
                leading: const CircleAvatar(
                  child: Icon(Icons.document_scanner_outlined),
                ),
                title: const Text('Digitalizar documento'),
                subtitle: const Text(
                  'Escaneie paginas, gere PDF e extraia o texto.',
                ),
                onTap: () => Navigator.pop(sheetContext, 'scan'),
              ),
              ListTile(
                leading: const CircleAvatar(
                  child: Icon(Icons.create_new_folder_outlined),
                ),
                title: const Text(TCloudLabels.newFolder),
                subtitle: const Text('Crie uma pasta no local atual.'),
                onTap: () => Navigator.pop(sheetContext, 'folder'),
              ),
              ListTile(
                leading: const CircleAvatar(
                  child: Icon(Icons.folder_copy_outlined),
                ),
                title: const Text('Gerenciar pastas'),
                subtitle: const Text('Renomeie, exclua ou escolha uma pasta.'),
                onTap: () => Navigator.pop(sheetContext, 'manage'),
              ),
            ],
          ),
        );
      },
    );

    if (!mounted || action == null) return;

    switch (action) {
      case 'upload':
        await _importFiles();
        break;

      case 'scan':
        await _scanDocument();
        break;

      case 'folder':
        await _createAlbum();
        break;
      case 'manage':
        await _showFolderManager();
        break;
    }
  }

  String _galleryChildTitle(TCloudFolder folder) {
    final title = folder.title.trim();
    const prefix = 'Galeria / ';

    if (title.toLowerCase().startsWith(prefix.toLowerCase())) {
      return title.substring(prefix.length).trim();
    }

    return title;
  }

  Future<void> _showGalleryChildren() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => GalleryFoldersScreen(
          loadFolders: () async {
            await _loadFolders();
            return _folders
                .where(
                  (folder) => folder.title.trim().toLowerCase().startsWith(
                    'galeria / ',
                  ),
                )
                .toList();
          },
          onFolderOptions: _showAlbumActions,
        ),
      ),
    );
  }

  Future<void> _showAlbumActions(TCloudFolder folder) async {
    final title = folder.title.trim();

    if (title.toLowerCase() == 'galeria') {
      await _showGalleryChildren();
      return;
    }

    final displayTitle = _galleryChildTitle(folder);
    final galleryChild = title.toLowerCase().startsWith('galeria / ');
    final hiddenFromBackup = galleryChild
        ? await _libraryPrefs.isAlbumHidden(folder)
        : false;
    if (!mounted) return;

    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      useSafeArea: true,
      builder: (sheetContext) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: Icon(
                  folder.isGeneral
                      ? Icons.forum_outlined
                      : Icons.folder_outlined,
                  color: TCloudTheme.primary,
                ),
                title: Text(
                  displayTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  folder.isGeneral
                      ? 'Pasta principal'
                      : 'Escolha o que deseja fazer',
                ),
              ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.folder_open_outlined),
                title: const Text('Abrir pasta'),
                onTap: () => Navigator.pop(sheetContext, 'open'),
              ),
              ListTile(
                leading: const Icon(Icons.download_for_offline_outlined),
                title: const Text('Disponibilizar pasta offline'),
                subtitle: const Text(
                  'Baixa os arquivos desta pasta e preserva o progresso.',
                ),
                onTap: () => Navigator.pop(sheetContext, 'offline'),
              ),
              if (!folder.isGeneral) ...[
                if (galleryChild)
                  ListTile(
                    leading: Icon(
                      hiddenFromBackup
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined,
                    ),
                    title: Text(
                      hiddenFromBackup
                          ? 'Incluir no backup'
                          : 'Ignorar no backup',
                    ),
                    subtitle: const Text(
                      'Controla novos arquivos desta pasta do celular.',
                    ),
                    onTap: () => Navigator.pop(sheetContext, 'visibility'),
                  ),
                ListTile(
                  leading: const Icon(Icons.edit_outlined),
                  title: const Text('Renomear'),
                  onTap: () => Navigator.pop(sheetContext, 'rename'),
                ),
                ListTile(
                  leading: const Icon(
                    Icons.delete_outline,
                    color: Colors.redAccent,
                  ),
                  title: const Text(
                    'Excluir',
                    style: TextStyle(color: Colors.redAccent),
                  ),
                  onTap: () => Navigator.pop(sheetContext, 'delete'),
                ),
              ],
            ],
          ),
        );
      },
    );

    if (!mounted || action == null) {
      return;
    }

    switch (action) {
      case 'open':
        await Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => FolderScreen(folder: folder)),
        );
        break;
      case 'rename':
        await _renameAlbum(folder);
        break;
      case 'offline':
        await _makeFolderOffline(folder);
        break;
      case 'visibility':
        await _libraryPrefs.setAlbumHidden(folder, !hiddenFromBackup);
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              hiddenFromBackup
                  ? '$displayTitle voltou ao backup.'
                  : '$displayTitle será ignorada nos próximos backups.',
            ),
          ),
        );
        break;
      case 'delete':
        await _deleteAlbum(folder);
        break;
    }
  }

  Future<void> _makeFolderOffline(TCloudFolder folder) async {
    final progress = ValueNotifier<(int, int, String)>((0, 0, 'Preparando...'));
    var cancelled = false;

    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => PopScope(
          canPop: false,
          child: AlertDialog(
            title: const Text('Pasta offline'),
            content: ValueListenableBuilder<(int, int, String)>(
              valueListenable: progress,
              builder: (_, value, _) => Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  LinearProgressIndicator(
                    value: value.$2 > 0 ? value.$1 / value.$2 : null,
                  ),
                  const SizedBox(height: 14),
                  Text(value.$3),
                  if (value.$2 > 0)
                    Text(
                      '${value.$1} de ${value.$2}',
                      style: TextStyle(color: TCloudTheme.textSecondary),
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () {
                  cancelled = true;
                  Navigator.pop(dialogContext);
                },
                child: const Text('Pausar'),
              ),
            ],
          ),
        ),
      ),
    );

    var fromMessageId = 0;
    var fromMessageIds = <String, int>{};
    final files = <String, TCloudFile>{};
    try {
      for (var pageIndex = 0; pageIndex < 100 && !cancelled; pageIndex++) {
        progress.value = (0, 0, 'Localizando arquivos...');
        final page = await _repo.loadFilePage(
          folder,
          fromMessageId: fromMessageId,
          fromMessageIds: fromMessageIds,
          limit: 100,
        );
        for (final file in page.files) {
          files[file.contentIdentity] = file;
        }
        if (!page.hasMore) break;
        fromMessageId = page.nextFromMessageId;
        fromMessageIds = page.nextFromMessageIds;
      }

      final existing = _offline.map((file) => file.contentIdentity).toSet();
      final pending = files.values
          .where((file) => !existing.contains(file.contentIdentity))
          .toList();
      var completed = 0;
      var failed = 0;
      for (var start = 0; start < pending.length && !cancelled; start += 2) {
        final batch = pending.skip(start).take(2).toList();
        progress.value = (
          completed,
          pending.length,
          'Baixando ${batch.first.name}',
        );
        await Future.wait(
          batch.map((file) async {
            try {
              final path = await _repo.download(file);
              await _repo.rememberOffline(
                file.copyWith(localPath: path, downloaded: true),
              );
            } catch (_) {
              failed++;
            } finally {
              completed++;
              progress.value = (
                completed,
                pending.length,
                'Salvando para uso offline...',
              );
            }
          }),
        );
      }
      await _loadOffline();
      if (!mounted || cancelled) return;
      Navigator.of(context, rootNavigator: true).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            failed == 0
                ? '${folder.title} está disponível offline.'
                : '$completed concluído(s), $failed com falha. Tente novamente para retomar.',
          ),
        ),
      );
    } catch (error) {
      if (!mounted || cancelled) return;
      Navigator.of(context, rootNavigator: true).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Não foi possível baixar a pasta: $error')),
      );
    } finally {
      progress.dispose();
    }
  }

  Future<void> _showFolderManager() async {
    var query = '';
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) {
          final map = <String, TCloudFolder>{};
          for (final f in _folders) {
            final key = f.title.trim().toLowerCase();
            if (key.isNotEmpty) map.putIfAbsent(key, () => f);
          }
          final clean = query.trim().toLowerCase();
          final folders =
              map.values
                  .where(
                    (f) =>
                        clean.isEmpty ||
                        f.title.toLowerCase().contains(clean) ||
                        f.forumTitle.toLowerCase().contains(clean),
                  )
                  .toList()
                ..sort((a, b) {
                  if (a.isGeneral != b.isGeneral) return a.isGeneral ? -1 : 1;
                  return a.title.toLowerCase().compareTo(b.title.toLowerCase());
                });
          return SizedBox(
            height: MediaQuery.sizeOf(sheetContext).height * .78,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 2, 8, 8),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Pastas do TCloud',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      TextButton.icon(
                        onPressed: () async {
                          Navigator.pop(sheetContext);
                          await _createAlbum();
                        },
                        icon: const Icon(Icons.create_new_folder_outlined),
                        label: const Text('Novo'),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: TextField(
                    onChanged: (v) => setSheetState(() => query = v),
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search),
                      hintText: 'Pesquisar pastas',
                      isDense: true,
                    ),
                  ),
                ),
                Expanded(
                  child: folders.isEmpty
                      ? const Center(child: Text('Nenhuma pasta encontrada.'))
                      : ListView.builder(
                          itemCount: folders.length,
                          itemBuilder: (_, i) {
                            final f = folders[i];
                            return ListTile(
                              leading: Icon(
                                f.isGeneral
                                    ? Icons.forum_outlined
                                    : Icons.folder_outlined,
                                color: TCloudTheme.primary,
                              ),
                              title: Text(
                                f.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                f.isGeneral ? 'Principal' : 'Pasta do TCloud',
                              ),
                              onTap: () async {
                                Navigator.pop(sheetContext);
                                await _showAlbumActions(f);
                              },
                              trailing: f.isGeneral
                                  ? null
                                  : PopupMenuButton<String>(
                                      onSelected: (action) async {
                                        Navigator.pop(sheetContext);
                                        if (action == 'rename') {
                                          await _renameAlbum(f);
                                        }
                                        if (action == 'delete') {
                                          await _deleteAlbum(f);
                                        }
                                      },
                                      itemBuilder: (_) => const [
                                        PopupMenuItem(
                                          value: 'rename',
                                          child: Text('Renomear'),
                                        ),
                                        PopupMenuItem(
                                          value: 'delete',
                                          child: Text(
                                            'Excluir',
                                            style: TextStyle(
                                              color: Colors.redAccent,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                            );
                          },
                        ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  String _mediaDateLabel(TCloudFile file) {
    if (file.createdAt <= 0) {
      return 'Sem data';
    }

    final date = DateTime.fromMillisecondsSinceEpoch(
      file.createdAt * 1000,
    ).toLocal();

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(date.year, date.month, date.day);

    final difference = today.difference(day).inDays;

    if (difference == 0) return 'Hoje';
    if (difference == 1) return 'Ontem';

    const months = <String>[
      '',
      'janeiro',
      'fevereiro',
      'marco',
      'abril',
      'maio',
      'junho',
      'julho',
      'agosto',
      'setembro',
      'outubro',
      'novembro',
      'dezembro',
    ];

    if (date.year == now.year) {
      return '${date.day} de ${months[date.month]}';
    }

    return '${date.day} de ${months[date.month]} de ${date.year}';
  }

  List<TCloudFile> get _visibleMedia {
    final query = _mediaQuery.trim().toLowerCase();

    if (query.isEmpty) {
      return _media;
    }

    return _media.where((file) {
      final haystack = '${file.name} ${file.kind} ${file.mimeType ?? ''}'
          .toLowerCase();

      return haystack.contains(query);
    }).toList();
  }

  Map<String, List<TCloudFile>> _groupVisibleMedia() {
    final groups = <String, List<TCloudFile>>{};

    for (final file in _visibleMedia) {
      final label = _mediaDateLabel(file);

      groups.putIfAbsent(label, () => <TCloudFile>[]).add(file);
    }

    return groups;
  }

  // ignore: unused_element
  List<TCloudFolder> get _visibleFolders {
    final query = _folderQuery.trim().toLowerCase();

    final folders = List<TCloudFolder>.from(_folders)
      ..sort((a, b) {
        if (a.isGeneral != b.isGeneral) {
          return a.isGeneral ? -1 : 1;
        }

        return a.title.toLowerCase().compareTo(b.title.toLowerCase());
      });

    if (query.isEmpty) {
      return folders;
    }

    return folders.where((folder) {
      return folder.title.toLowerCase().contains(query) ||
          folder.forumTitle.toLowerCase().contains(query);
    }).toList();
  }

  // ignore: unused_element
  Future<void> _openFolderAlbum(TCloudFolder folder) async {
    setState(() {
      _currentIndex = 0;
      _selectedFolderKey = folder.cacheKey;
      _mediaQuery = '';
      _showMediaSearch = false;
    });

    await _loadMedia();
  }

  // ignore: unused_element
  Widget _mediaPage() {
    if (_loadingFolders && _folders.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    final visible = _visibleMedia;
    final groups = _groupVisibleMedia();
    final entries = groups.entries.toList();

    return Column(
      children: [
        if (_loadingFullAlbum)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 7, 14, 5),
            child: Row(
              children: [
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    'Carregando todo o album... '
                    '${_media.length} item(ns)',
                    style: TextStyle(
                      color: TCloudTheme.textSecondary,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
          ),

        if (_syncingGallery) const LinearProgressIndicator(minHeight: 2),
        if (_showMediaSearch)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
            child: TextField(
              autofocus: true,
              onChanged: (value) {
                setState(() => _mediaQuery = value);
              },
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                hintText: 'Pesquisar fotos e videos',
                isDense: true,
                suffixIcon: _mediaQuery.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Limpar pesquisa',
                        onPressed: () {
                          setState(() => _mediaQuery = '');
                        },
                        icon: const Icon(Icons.close),
                      ),
              ),
            ),
          ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () async {
              await _loadFolders();
              await _loadMedia();
              await _autoSyncGallery();
            },
            child: visible.isEmpty
                ? ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.only(bottom: 110),
                    children: [
                      const SizedBox(height: 120),
                      Icon(
                        _mediaQuery.isEmpty
                            ? Icons.photo_library_outlined
                            : Icons.search_off_outlined,
                        size: 54,
                        color: TCloudTheme.textSecondary,
                      ),
                      const SizedBox(height: 14),
                      Text(
                        _mediaQuery.isEmpty
                            ? 'Nenhuma foto ou video nesta pasta.'
                            : 'Nenhum resultado encontrado.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: TCloudTheme.textSecondary),
                      ),
                    ],
                  )
                : ListView.builder(
                    controller: _mediaScrollController,
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.only(bottom: 110),
                    itemCount: entries.length,
                    itemBuilder: (context, groupIndex) {
                      final entry = entries[groupIndex];
                      final files = entry.value;

                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    entry.key,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w800,
                                      fontSize: 16,
                                    ),
                                  ),
                                ),
                                Text(
                                  '${files.length}',
                                  style: TextStyle(
                                    color: TCloudTheme.textSecondary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          GridView.builder(
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            padding: const EdgeInsets.symmetric(horizontal: 2),
                            gridDelegate:
                                const SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: 3,
                                  crossAxisSpacing: 2,
                                  mainAxisSpacing: 2,
                                ),
                            itemCount: files.length,
                            itemBuilder: (context, index) {
                              final file = files[index];

                              return KeyedSubtree(
                                key: _mediaDragTileKey(file),
                                child: _HomeThumbnail(
                                  key: ValueKey<String>(
                                    'media:${file.chatId}:${file.messageThreadId}:${file.messageId}:${file.fileId}',
                                  ),
                                  file: file,
                                  repo: _repo,
                                  selected: _selectedMediaIds.contains(
                                    file.fileId,
                                  ),
                                  onLongPress: () {},
                                  onLongPressStart: (_) {
                                    _beginMediaDragSelection(file);
                                  },
                                  onLongPressMoveUpdate: (details) {
                                    _updateMediaDragAutoScroll(
                                      details.globalPosition,
                                    );
                                    _updateMediaDragSelection(
                                      details.globalPosition,
                                    );
                                  },
                                  onLongPressEnd: (_) {
                                    _endMediaDragSelection();
                                  },
                                  onLongPressCancel: () {
                                    _endMediaDragSelection();
                                  },
                                  onTap: () {
                                    if (_mediaSelectionMode) {
                                      _toggleMediaSelection(file);
                                      return;
                                    }

                                    Navigator.of(context).push(
                                      MaterialPageRoute<void>(
                                        builder: (_) => MediaViewerScreen(
                                          file: file,
                                          files: _media,
                                        ),
                                      ),
                                    );
                                  },
                                ),
                              );
                            },
                          ),
                        ],
                      );
                    },
                  ),
          ),
        ),
      ],
    );
  }

  Widget _offlinePage() {
    if (_offline.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.offline_pin_outlined,
              size: 52,
              color: TCloudTheme.textSecondary,
            ),
            SizedBox(height: 12),
            Text(
              'Nenhum arquivo offline.',
              style: TextStyle(color: TCloudTheme.textSecondary),
            ),
          ],
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 100),
      itemCount: _offline.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final file = _offline[index];

        return ListTile(
          leading: Icon(
            file.isImage
                ? Icons.image_outlined
                : file.isVideo
                ? Icons.movie_outlined
                : Icons.insert_drive_file_outlined,
            color: Colors.green,
          ),
          title: Text(file.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text('${_humanSize(file.size)} - ${file.kind}'),
          trailing: PopupMenuButton<String>(
            tooltip: 'Opcoes',
            onSelected: (action) async {
              if (action == 'info') {
                await _showMediaInfo(file);
              } else if (action == 'remove') {
                await _repo.removeOffline(file);
                await _loadOffline();

                if (!context.mounted) return;

                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text(
                      'Removido da lista offline. O arquivo continua no TCloud.',
                    ),
                  ),
                );
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'info',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.info_outline),
                  title: Text('Informacoes'),
                ),
              ),
              PopupMenuItem(
                value: 'remove',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.cloud_outlined),
                  title: Text('Remover do offline'),
                ),
              ),
            ],
          ),
          onTap: () => _openOffline(file),
        );
      },
    );
  }

  Widget _transfersPage() {
    final center = TransferCenter.instance;

    return AnimatedBuilder(
      animation: center,
      builder: (context, _) {
        final running = center.runningCount;
        final failed = center.failedCount;

        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: TCloudTheme.surface,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: TCloudTheme.border),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: TCloudTheme.primary.withValues(alpha: .10),
                        borderRadius: BorderRadius.circular(7),
                      ),
                      child: Icon(
                        Icons.cloud_sync_outlined,
                        color: TCloudTheme.primary,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            running > 0
                                ? '$running em andamento'
                                : failed > 0
                                ? '$failed precisam de atenção'
                                : 'Tudo em dia',
                            style: const TextStyle(fontWeight: FontWeight.w800),
                          ),
                          Text(
                            '${center.transfers.length} atividades recentes',
                            style: TextStyle(
                              color: TCloudTheme.textSecondary,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (center.transfers.isNotEmpty)
                      IconButton(
                        tooltip: 'Limpar concluídas',
                        onPressed: running > 0 ? null : center.clearCompleted,
                        icon: const Icon(Icons.cleaning_services_outlined),
                      ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 10, 18, 4),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Atividade recente',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const SyncQueueScreen(),
                      ),
                    ),
                    child: const Text('Ver fila'),
                  ),
                ],
              ),
            ),
            Expanded(
              child: center.transfers.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.swap_vert_circle_outlined,
                            size: 52,
                            color: TCloudTheme.textSecondary,
                          ),
                          SizedBox(height: 12),
                          const Text(
                            'Nenhuma atividade recente.',
                            style: TextStyle(fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Envios e downloads aparecerão aqui.',
                            style: TextStyle(color: TCloudTheme.textSecondary),
                          ),
                        ],
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.only(bottom: 100),
                      itemCount: center.transfers.length,
                      itemBuilder: (context, index) {
                        final transfer = center.transfers[index];

                        return ListTile(
                          leading: Icon(
                            transfer.direction == 'upload'
                                ? Icons.cloud_upload_outlined
                                : Icons.cloud_download_outlined,
                          ),
                          title: Text(
                            transfer.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            switch (transfer.status) {
                              TCloudTransferStatus.running => 'Em andamento',
                              TCloudTransferStatus.completed => 'Concluída',
                              TCloudTransferStatus.failed =>
                                transfer.error ?? 'Falhou',
                              _ => transfer.status.name,
                            },
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing:
                              transfer.status == TCloudTransferStatus.running
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : transfer.status ==
                                    TCloudTransferStatus.completed
                              ? const Icon(
                                  Icons.check_circle,
                                  color: Colors.green,
                                )
                              : transfer.status == TCloudTransferStatus.failed
                              ? const Icon(
                                  Icons.error_outline,
                                  color: Colors.redAccent,
                                )
                              : null,
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _showDiagnostics() async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.monitor_heart_outlined),
        title: const Text('Diagnóstico do TCloud'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _FileInfoRow(label: 'Pastas', value: '${_folders.length}'),
            _FileInfoRow(label: 'Mídias', value: '${_media.length}'),
            _FileInfoRow(label: 'Offline', value: '${_offline.length}'),
            _FileInfoRow(
              label: 'Atualizações',
              value: _lastUpdateCheckAt == null
                  ? 'Ainda não verificado'
                  : 'Verificado nesta sessão',
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Fechar'),
          ),
        ],
      ),
    );
  }

  // TCLOUD_UPDATER_STARTUP_RETRY_1039
  Future<void> _checkForUpdatePopup() async {
    if (_startupUpdateChecked) return;

    try {
      final update = await TCloudAppUpdateService.instance.check();

      if (!mounted) return;

      // Uma consulta concluida com sucesso pode ser marcada como feita.
      // Em erro, liberamos nova tentativa automaticamente.
      _startupUpdateChecked = true;
      _lastUpdateCheckAt = DateTime.now();

      if (update == null) return;

      final go =
          await showDialog<bool>(
            context: context,
            builder: (dialogContext) => AlertDialog(
              icon: const Icon(Icons.system_update_alt_rounded),
              title: const Text('Nova atualizacao disponivel'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('TCloud Mobile ${update.version} esta disponivel.'),
                  if (update.notes.trim().isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Text(
                      update.notes.trim(),
                      style: TextStyle(color: TCloudTheme.textSecondary),
                    ),
                  ],
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: const Text('Agora nao'),
                ),
                FilledButton.icon(
                  onPressed: () => Navigator.pop(dialogContext, true),
                  icon: const Icon(Icons.download_rounded),
                  label: const Text('Atualizar'),
                ),
              ],
            ),
          ) ??
          false;

      if (!go || !mounted) return;

      await Navigator.of(
        context,
      ).push(MaterialPageRoute<void>(builder: (_) => const UpdateScreen()));
    } catch (_) {
      _startupUpdateChecked = false;

      // Primeira abertura pode coincidir com rede ainda inicializando.
      // Faz uma unica nova tentativa poucos segundos depois.
      if (mounted) {
        Future<void>.delayed(const Duration(seconds: 5), () {
          if (mounted && !_startupUpdateChecked) {
            _checkForUpdatePopup();
          }
        });
      }
    }
  }

  Future<void> _showDevicePairing() async {
    final controller = TextEditingController();
    var busy = false;
    String? error;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          icon: const Icon(Icons.devices_other_rounded),
          title: const Text('Conectar ao TCloud'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Em um TCloud já conectado, abra Configurações, escolha “Conectar novo dispositivo” e informe aqui o código temporário. Você também pode ler o QR code.',
              ),
              const SizedBox(height: 16),
              TextField(
                controller: controller,
                enabled: !busy,
                autofocus: true,
                textCapitalization: TextCapitalization.characters,
                maxLength: 10,
                decoration: InputDecoration(
                  labelText: 'Código de 10 caracteres',
                  errorText: error,
                  prefixIcon: const Icon(Icons.key_rounded),
                ),
              ),
            ],
          ),
          actions: [
            TextButton.icon(
              onPressed: busy
                  ? null
                  : () async {
                      final code = await Navigator.of(dialogContext)
                          .push<String>(
                            MaterialPageRoute<String>(
                              builder: (_) => const _PairingQrScannerScreen(),
                            ),
                          );
                      if (code != null && code.isNotEmpty) {
                        controller.text = code;
                        setDialogState(() => error = null);
                      }
                    },
              icon: const Icon(Icons.qr_code_scanner_rounded),
              label: const Text('Ler QR'),
            ),
            TextButton(
              onPressed: busy ? null : () => Navigator.pop(dialogContext),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: busy
                  ? null
                  : () async {
                      setDialogState(() {
                        busy = true;
                        error = null;
                      });
                      try {
                        await TCloudDeviceAuth.instance.pair(controller.text);
                        await TCloudFoundation5Bridge.instance.refresh();
                        if (dialogContext.mounted) Navigator.pop(dialogContext);
                        if (mounted) {
                          setState(() {});
                          ScaffoldMessenger.of(this.context).showSnackBar(
                            const SnackBar(
                              content: Text(
                                'Dispositivo conectado com segurança.',
                              ),
                            ),
                          );
                        }
                      } catch (failure) {
                        setDialogState(() {
                          busy = false;
                          error = '$failure'.replaceFirst('Bad state: ', '');
                        });
                      }
                    },
              child: busy
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Conectar'),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
  }

  Future<void> _editTCloudProfile() async {
    final current = await AccountService.instance.activeAccount();
    final remote = await TCloudDeviceAuth.instance.profile();
    if (!mounted) return;
    final name = TextEditingController(
      text: remote?['displayName']?.toString() ?? current.displayName ?? '',
    );
    final username = TextEditingController(
      text: remote?['username']?.toString() ?? current.username ?? '',
    );
    String? avatarDataUrl = remote?['avatarUrl']?.toString();
    String? error;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Perfil TCloud'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircleAvatar(
                radius: 38,
                backgroundImage:
                    avatarDataUrl?.startsWith('data:image/') == true
                    ? MemoryImage(base64Decode(avatarDataUrl!.split(',').last))
                    : null,
                child: avatarDataUrl?.startsWith('data:image/') == true
                    ? null
                    : const Icon(Icons.person_outline, size: 34),
              ),
              TextButton.icon(
                onPressed: () async {
                  final image = await ImagePicker().pickImage(
                    source: ImageSource.gallery,
                    maxWidth: 720,
                    maxHeight: 720,
                    imageQuality: 78,
                  );
                  if (image == null) return;
                  final bytes = await image.readAsBytes();
                  if (bytes.length > 500000) {
                    setDialogState(
                      () => error = 'Escolha uma imagem com até 500 KB.',
                    );
                    return;
                  }
                  final extension = image.name.toLowerCase();
                  final mime = extension.endsWith('.png')
                      ? 'image/png'
                      : extension.endsWith('.webp')
                      ? 'image/webp'
                      : 'image/jpeg';
                  setDialogState(() {
                    avatarDataUrl = 'data:$mime;base64,${base64Encode(bytes)}';
                    error = null;
                  });
                },
                icon: const Icon(Icons.photo_camera_outlined),
                label: const Text('Alterar foto'),
              ),
              TextField(
                controller: name,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                  labelText: 'Seu nome',
                  prefixIcon: Icon(Icons.person_outline),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: username,
                autocorrect: false,
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[a-zA-Z0-9_]')),
                  LengthLimitingTextInputFormatter(32),
                ],
                decoration: InputDecoration(
                  labelText: 'Nome de usuário',
                  prefixText: '@',
                  prefixIcon: const Icon(Icons.alternate_email),
                  errorText: error,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () async {
                try {
                  final profile = await AccountService.instance.saveProfile(
                    name.text,
                    username.text,
                  );
                  await TCloudDeviceAuth.instance.register(
                    displayName: profile.displayName!,
                    username: profile.username!,
                    avatarDataUrl: avatarDataUrl,
                  );
                  if (dialogContext.mounted) Navigator.pop(dialogContext);
                  if (mounted) setState(() {});
                } catch (failure) {
                  setDialogState(
                    () => error = '$failure'.replaceFirst('Bad state: ', ''),
                  );
                }
              },
              child: const Text('Salvar'),
            ),
          ],
        ),
      ),
    );
    name.dispose();
    username.dispose();
  }

  Future<void> _manageDevices() async {
    List<Map<String, dynamic>> devices;
    try {
      devices = await TCloudDeviceAuth.instance.devices();
    } catch (failure) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$failure'.replaceFirst('Bad state: ', ''))),
        );
      }
      return;
    }
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Dispositivos e acessos',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 6),
                const Text('Revogue aparelhos que você não reconhece.'),
                const SizedBox(height: 12),
                SizedBox(
                  height: (devices.length * 72.0).clamp(
                    72.0,
                    MediaQuery.sizeOf(context).height * .55,
                  ),
                  child: devices.isEmpty
                      ? const Center(
                          child: Text('Nenhum dispositivo encontrado.'),
                        )
                      : ListView.builder(
                          itemCount: devices.length,
                          itemBuilder: (context, index) {
                            final device = devices[index];
                            return ListTile(
                              leading: Icon(
                                device['platform'] == 'android'
                                    ? Icons.smartphone
                                    : Icons.computer,
                              ),
                              title: Text(
                                device['name']?.toString() ?? 'Dispositivo',
                              ),
                              subtitle: Text(
                                '${device['active'] == true ? 'Ativo' : 'Sessão encerrada'}${device['current'] == true ? ' · Este aparelho' : ''}',
                              ),
                              trailing:
                                  device['active'] == true &&
                                      device['current'] != true
                                  ? IconButton(
                                      icon: const Icon(Icons.logout),
                                      tooltip: 'Revogar',
                                      onPressed: () async {
                                        try {
                                          await TCloudDeviceAuth.instance
                                              .revokeDevice(
                                                device['id'].toString(),
                                              );
                                          devices = await TCloudDeviceAuth
                                              .instance
                                              .devices();
                                          setSheetState(() {});
                                        } catch (failure) {
                                          if (sheetContext.mounted) {
                                            ScaffoldMessenger.of(
                                              sheetContext,
                                            ).showSnackBar(
                                              SnackBar(
                                                content: Text(
                                                  '$failure'.replaceFirst(
                                                    'Bad state: ',
                                                    '',
                                                  ),
                                                ),
                                              ),
                                            );
                                          }
                                        }
                                      },
                                    )
                                  : null,
                            );
                          },
                        ),
                ),
                const SizedBox(height: 8),
                FilledButton(
                  onPressed: () => Navigator.pop(sheetContext),
                  child: const Text('Concluir'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _settingsPage() {
    Widget section(String title, List<Widget> children) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
            child: Text(
              title,
              style: TextStyle(
                color: TCloudTheme.textSecondary,
                fontWeight: FontWeight.w800,
                fontSize: 13,
              ),
            ),
          ),
          Container(
            decoration: BoxDecoration(
              color: TCloudTheme.surface,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: TCloudTheme.border),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(children: children),
          ),
        ],
      ),
    );

    return FutureBuilder<List<Object?>>(
      future: Future.wait<Object?>([
        _sync.isEnabled(),
        _sync.wifiOnly(),
        _sync.chargingOnly(),
        _sync.rateLimitUntil(),
        _libraryPrefs.secureScreen(),
        TdlibService.instance.backgroundBackupStatus(),
        TCloudDeviceAuth.instance.paired,
        AccountService.instance.accounts(),
        AccountService.instance.activeId(),
        BiometricLockService.instance.isEnabled(),
        BiometricLockService.instance.timeoutSeconds(),
        _libraryPrefs.documentProviderEnabled(),
      ]),
      builder: (context, snapshot) {
        final v =
            snapshot.data ?? const <Object?>[false, false, false, null, false];
        final enabled = v.isNotEmpty && v[0] == true;
        final wifi = v.length > 1 && v[1] == true;
        final charging = v.length > 2 && v[2] == true;
        final rateLimitUntil = v.length > 3 ? v[3] as DateTime? : null;
        final secureScreen = v.length > 4 && v[4] == true;
        final backgroundStatus = v.length > 5 && v[5] is Map
            ? Map<String, dynamic>.from(v[5] as Map)
            : const <String, dynamic>{};
        final batteryUnrestricted =
            backgroundStatus['batteryUnrestricted'] == true;
        final corePaired = v.length > 6 && v[6] == true;
        final accounts = v.length > 7 && v[7] is List<TCloudAccount>
            ? v[7] as List<TCloudAccount>
            : const <TCloudAccount>[];
        final activeAccount = v.length > 8 ? v[8]?.toString() : 'default';
        final biometricEnabled = v.length > 9 && v[9] == true;
        final biometricTimeout = v.length > 10 && v[10] is int
            ? v[10] as int
            : 8;
        final biometricTimeoutLabel = switch (biometricTimeout) {
          0 => 'Imediatamente',
          30 => 'Após 30 segundos',
          60 => 'Após 1 minuto',
          300 => 'Após 5 minutos',
          _ => 'Após 8 segundos',
        };
        final documentProviderEnabled = v.length > 11 && v[11] == true;
        return ListView(
          padding: const EdgeInsets.only(top: 8, bottom: 120),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: TCloudTheme.surface,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: TCloudTheme.border),
                ),
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 26,
                      backgroundColor: TCloudTheme.surfaceSoft,
                      child: Icon(
                        Icons.cloud_outlined,
                        color: TCloudTheme.primary,
                      ),
                    ),
                    SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'TCloud Mobile',
                            style: TextStyle(
                              fontWeight: FontWeight.w900,
                              fontSize: 17,
                            ),
                          ),
                          SizedBox(height: 3),
                          Text(
                            'Android • versão 1.1.34',
                            style: TextStyle(color: TCloudTheme.textSecondary),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            section('ESTE TELEFONE', [
              SwitchListTile(
                secondary: const Icon(Icons.backup_outlined),
                title: const Text('Backup da galeria'),
                subtitle: const Text(
                  'Mantém fotos e vídeos protegidos automaticamente.',
                ),
                value: enabled,
                onChanged: _configureGallerySync,
              ),
              if (enabled) ...[
                ListTile(
                  leading: Icon(
                    batteryUnrestricted
                        ? Icons.shield_outlined
                        : Icons.battery_alert_outlined,
                  ),
                  title: const Text('Execução em segundo plano'),
                  subtitle: Text(
                    batteryUnrestricted
                        ? 'Proteção contra economia de bateria ativa.'
                        : 'Toque para impedir que o Android interrompa o backup.',
                  ),
                  trailing: Icon(
                    batteryUnrestricted
                        ? Icons.check_circle_rounded
                        : Icons.chevron_right_rounded,
                    color: batteryUnrestricted ? Colors.green : null,
                  ),
                  onTap: batteryUnrestricted
                      ? null
                      : () async {
                          await TdlibService.instance
                              .requestIgnoreBatteryOptimizations();
                          if (mounted) setState(() {});
                        },
                ),
                const Divider(height: 1),
                SwitchListTile(
                  secondary: const Icon(Icons.wifi_outlined),
                  title: const Text('Somente no Wi-Fi'),
                  value: wifi,
                  onChanged: (x) async {
                    await _sync.setBackgroundOptions(
                      wifiOnly: x,
                      chargingOnly: charging,
                    );
                    if (mounted) setState(() {});
                  },
                ),
                SwitchListTile(
                  secondary: const Icon(Icons.battery_charging_full_outlined),
                  title: const Text('Somente carregando'),
                  value: charging,
                  onChanged: (x) async {
                    await _sync.setBackgroundOptions(
                      wifiOnly: wifi,
                      chargingOnly: x,
                    );
                    if (mounted) setState(() {});
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.sync_rounded),
                  title: const Text('Sincronizar agora'),
                  subtitle: Text(
                    rateLimitUntil != null
                        ? _sync.rateLimitMessage(rateLimitUntil)
                        : _syncingGallery
                        ? 'Sincronizando...'
                        : 'Procura novas fotos e vídeos.',
                  ),
                  onTap: _syncingGallery || rateLimitUntil != null
                      ? null
                      : () => _runGallerySync(),
                ),
                const Divider(height: 1),
                // TCLOUD_SYNC_QUEUE_SETTINGS_1051
                ListTile(
                  leading: const Icon(Icons.cloud_sync_outlined),
                  title: const Text('Arquivos sincronizando'),
                  subtitle: const Text(
                    'Veja a fila, o progresso e os arquivos em andamento.',
                  ),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const SyncQueueScreen(),
                    ),
                  ),
                ),
              ],
            ]),
            section('ARQUIVOS DO APLICATIVO', [
              ListTile(
                leading: const Icon(Icons.photo_album_outlined),
                title: const Text('Pastas'),
                subtitle: const Text('Criar, renomear ou excluir.'),
                onTap: _showFolderManager,
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.storage_outlined),
                title: const Text('Armazenamento'),
                subtitle: const Text(
                  'Arquivos offline, cache e liberar espaço.',
                ),
                onTap: _openSmartStorage,
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.system_update_alt),
                title: const Text('Atualizações'),
                subtitle: const Text('Verificar nova versão do aplicativo.'),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const UpdateScreen()),
                ),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.undo_rounded),
                title: const Text('Desfazer backup'),
                subtitle: const Text('Remove apenas as cópias automáticas.'),
                onTap: _undoGalleryBackup,
              ),
            ]),
            section('CONTA E DISPOSITIVOS', [
              SwitchListTile(
                secondary: const Icon(Icons.fingerprint_rounded),
                title: const Text('Desbloquear com biometria'),
                subtitle: Text(
                  biometricEnabled
                      ? 'Proteção ativa ao abrir ou retornar ao aplicativo.'
                      : 'Use a biometria cadastrada neste telefone.',
                ),
                value: biometricEnabled,
                onChanged: (value) async {
                  try {
                    await BiometricLockService.instance.setEnabled(value);
                    if (mounted) setState(() {});
                  } catch (failure) {
                    if (!mounted) return;
                    ScaffoldMessenger.of(this.context).showSnackBar(
                      SnackBar(
                        content: Text(
                          '$failure'.replaceFirst('Bad state: ', ''),
                        ),
                      ),
                    );
                  }
                },
              ),
              if (biometricEnabled) ...[
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.timer_outlined),
                  title: const Text('Bloqueio automático'),
                  subtitle: Text(biometricTimeoutLabel),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => _chooseBiometricTimeout(biometricTimeout),
                ),
              ],
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.badge_outlined),
                title: const Text('Perfil TCloud'),
                subtitle: const Text(
                  'Nome, usuário e identidade nos compartilhamentos.',
                ),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: _editTCloudProfile,
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.devices_outlined),
                title: const Text('Dispositivos e acessos'),
                subtitle: const Text('Veja atividades e revogue aparelhos.'),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: corePaired ? _manageDevices : _showDevicePairing,
              ),
              const Divider(height: 1),
              ...accounts.map(
                (account) => ListTile(
                  leading: Icon(
                    account.id == activeAccount
                        ? Icons.account_circle
                        : Icons.account_circle_outlined,
                  ),
                  title: Text(account.label),
                  subtitle: Text(
                    account.id == activeAccount
                        ? 'Conta ativa'
                        : 'Trocar conta',
                  ),
                  trailing: account.id == activeAccount
                      ? const Icon(Icons.check_rounded)
                      : const Icon(Icons.chevron_right_rounded),
                  onTap: account.id == activeAccount
                      ? null
                      : () async {
                          await AccountService.instance.setActive(account.id);
                          await TdlibService.instance.switchAccount(account.id);
                          if (!context.mounted) return;
                          Navigator.of(context).pushAndRemoveUntil(
                            MaterialPageRoute<void>(
                              builder: (_) => const LoginScreen(),
                            ),
                            (_) => false,
                          );
                        },
                ),
              ),
              ListTile(
                leading: const Icon(Icons.person_add_alt_1_outlined),
                title: const Text('Adicionar outra conta'),
                subtitle: const Text(
                  'Mantem os arquivos e a sessao separados.',
                ),
                onTap: () async {
                  final id = await AccountService.instance.createAccount();
                  await TdlibService.instance.switchAccount(id);
                  if (!context.mounted) return;
                  Navigator.of(context).pushAndRemoveUntil(
                    MaterialPageRoute<void>(
                      builder: (_) => const LoginScreen(),
                    ),
                    (_) => false,
                  );
                },
              ),
              const Divider(height: 1),
              ListTile(
                leading: Icon(
                  corePaired
                      ? Icons.verified_user_rounded
                      : Icons.devices_other_rounded,
                ),
                title: Text(
                  corePaired ? 'Conectado ao TCloud' : 'Conectar este aparelho',
                ),
                subtitle: Text(
                  corePaired
                      ? 'Favoritos, atividade e arquivos podem ser sincronizados com segurança.'
                      : 'Use o código temporário gerado no TCloud Web.',
                ),
                trailing: corePaired
                    ? TextButton(
                        onPressed: () async {
                          await TCloudDeviceAuth.instance.disconnect();
                          if (mounted) setState(() {});
                        },
                        child: const Text('Desconectar'),
                      )
                    : const Icon(Icons.chevron_right_rounded),
                onTap: corePaired ? null : _showDevicePairing,
              ),
            ]),
            section('APARÊNCIA', [const TCloudThemeSelector()]),
            section('PRIVACIDADE', [
              SwitchListTile(
                secondary: const Icon(Icons.screenshot_monitor_outlined),
                title: const Text('Proteger conteúdo na tela'),
                subtitle: const Text(
                  'Bloqueia capturas e oculta o conteúdo nos aplicativos recentes.',
                ),
                value: secureScreen,
                onChanged: (value) async {
                  await _libraryPrefs.setSecureScreen(value);
                  if (mounted) setState(() {});
                },
              ),
              const Divider(height: 1),
              SwitchListTile(
                secondary: const Icon(Icons.drive_file_move_outline),
                title: const Text('Usar arquivos em outros aplicativos'),
                subtitle: const Text(
                  'Mostra o TCloud no seletor de arquivos do Android. Somente itens já disponíveis neste aparelho podem ser enviados.',
                ),
                value: documentProviderEnabled,
                onChanged: (value) async {
                  await _libraryPrefs.setDocumentProviderEnabled(value);
                  if (mounted) setState(() {});
                },
              ),
              if (documentProviderEnabled) ...[
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.open_in_new_rounded),
                  title: const Text('Abrir seletor de arquivos'),
                  subtitle: Text(
                    _offline.isEmpty
                        ? 'Baixe um arquivo ou uma pasta para disponibilizá-los em outros aplicativos.'
                        : '${_offline.length} item(ns) offline pronto(s) para anexar.',
                  ),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () async {
                    try {
                      await TdlibService.instance.openDocumentProvider();
                    } catch (error) {
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            'Não foi possível abrir o seletor: $error',
                          ),
                        ),
                      );
                    }
                  },
                ),
              ],
            ]),
            section('SUPORTE AVANÇADO', [
              ListTile(
                leading: const Icon(Icons.health_and_safety_outlined),
                title: const Text('Centro de integridade'),
                subtitle: const Text(
                  'Encontre e repare IDs e arquivos indisponíveis.',
                ),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        IntegrityCenterScreen(files: _media, folders: _folders),
                  ),
                ),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.monitor_heart_outlined),
                title: const Text('Diagnóstico'),
                subtitle: const Text('Confira o estado local do aplicativo.'),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: _showDiagnostics,
              ),
            ]),
            section('CONTA', [
              ListTile(
                leading: const Icon(Icons.logout, color: Colors.redAccent),
                title: const Text(
                  'Sair da conta',
                  style: TextStyle(color: Colors.redAccent),
                ),
                onTap: _logout,
              ),
            ]),
          ],
        );
      },
    );
  }

  Widget _tcloudGalleryHomePage() {
    final phoneFolderCount = _folders.where((folder) {
      final origin = '${folder.forumTitle} ${folder.title}'.toLowerCase();
      return origin.contains('galeria') || origin.contains('meu telefone');
    }).length;
    final computerFolderCount = _folders.where((folder) {
      final origin = '${folder.forumTitle} ${folder.title}'.toLowerCase();
      return origin.contains('meu computador');
    }).length;
    final unique = <String, TCloudFolder>{};
    for (final f in _folders) {
      final origin = '${f.forumTitle} ${f.title}'.trim().toLowerCase();
      if (_deviceSpace == 'phone' && !origin.contains('galeria')) continue;
      if (_deviceSpace == 'computer' && !origin.contains('meu computador')) {
        continue;
      }
      if (_deviceSpace == 'all' &&
          f.title.trim().toLowerCase().startsWith('galeria / ')) {
        continue;
      }

      unique[f.cacheKey] = f;
    }
    final q = _folderQuery.trim().toLowerCase();
    final all =
        unique.values
            .where(
              (f) =>
                  q.isEmpty ||
                  f.title.toLowerCase().contains(q) ||
                  f.forumTitle.toLowerCase().contains(q),
            )
            .toList()
          ..sort((a, b) {
            if (a.isGeneral != b.isGeneral) return a.isGeneral ? -1 : 1;
            return a.title.toLowerCase().compareTo(b.title.toLowerCase());
          });
    final albums = _showAllAlbums ? all : all.take(12).toList();
    final visibleFolderKeys = unique.values
        .map(
          (folder) =>
              '${folder.chatId}:${folder.messageThreadId != 0 ? folder.messageThreadId : folder.forumTopicId}',
        )
        .toSet();
    bool isVisible(TCloudFile file) =>
        (_deviceSpace == 'all' ||
            visibleFolderKeys.contains(
              '${file.chatId}:${file.messageThreadId}',
            )) &&
        !_trash.contains(file.contentIdentity) &&
        (q.isEmpty ||
            file.name.toLowerCase().contains(q) ||
            file.kind.toLowerCase().contains(q) ||
            (file.mimeType?.toLowerCase().contains(q) ?? false) ||
            file.name.split('.').last.toLowerCase() == q);

    bool matchesAdvancedSearch(TCloudFile file) {
      final now = DateTime.now();
      final created = file.createdAt > 0
          ? DateTime.fromMillisecondsSinceEpoch(file.createdAt * 1000).toLocal()
          : null;
      final dateMatches = switch (_homeDateFilter) {
        'Hoje' =>
          created != null &&
              created.year == now.year &&
              created.month == now.month &&
              created.day == now.day,
        'Últimos 7 dias' =>
          created != null && now.difference(created).inDays <= 7,
        'Últimos 30 dias' =>
          created != null && now.difference(created).inDays <= 30,
        'Este ano' => created != null && created.year == now.year,
        _ => true,
      };
      const mb = 1024 * 1024;
      final sizeMatches = switch (_homeSizeFilter) {
        'Até 10 MB' => file.size <= 10 * mb,
        '10 a 100 MB' => file.size > 10 * mb && file.size <= 100 * mb,
        'Mais de 100 MB' => file.size > 100 * mb,
        _ => true,
      };
      return dateMatches && sizeMatches;
    }

    final recent = _media.where(isVisible).take(12).toList();
    _recentCarouselItemCount = recent.length;
    final duplicateKeys = <String, int>{};
    for (final file in _allFiles.where(isVisible)) {
      final key = '${file.name.trim().toLowerCase()}:${file.size}';
      duplicateKeys[key] = (duplicateKeys[key] ?? 0) + 1;
    }
    final filteredFiles =
        _allFiles.where((file) {
          if (!isVisible(file) || !matchesAdvancedSearch(file)) return false;
          return switch (_homeFilesFilter) {
            'Fotos' => file.isImage,
            'Vídeos' => file.isVideo,
            'Documentos' => !file.isMedia,
            'Capturas' =>
              file.isImage &&
                  (file.name.toLowerCase().contains('screenshot') ||
                      file.name.toLowerCase().contains('captura de tela')),
            'Favoritos' => _favorites.contains(file.contentIdentity),
            'Offline' => _offline.any(
              (item) => item.contentIdentity == file.contentIdentity,
            ),
            'Duplicados' =>
              (duplicateKeys['${file.name.trim().toLowerCase()}:${file.size}'] ??
                      0) >
                  1,
            _ => true,
          };
        }).toList()..sort(
          (a, b) => switch (_homeFilesSort) {
            'Nome' => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
            'Maior tamanho' => b.size.compareTo(a.size),
            'Mais antigos' => a.createdAt.compareTo(b.createdAt),
            _ => b.createdAt.compareTo(a.createdAt),
          },
        );
    final continueWatching = _allFiles
        .where(
          (file) =>
              file.isVideo &&
              isVisible(file) &&
              _resumableVideoIds.contains(file.syncIdentity),
        )
        .take(10)
        .toList();
    _homeVisibleFileIds = filteredFiles.map((file) => file.fileId).toSet();

    String dateGroup(TCloudFile file) {
      if (file.createdAt <= 0) return 'Sem data';
      final date = DateTime.fromMillisecondsSinceEpoch(
        file.createdAt * 1000,
      ).toLocal();
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final day = DateTime(date.year, date.month, date.day);
      final difference = today.difference(day).inDays;
      if (difference == 0) return 'Hoje';
      if (difference == 1) return 'Ontem';
      if (difference < 7) return 'Esta semana';
      const months = [
        'janeiro',
        'fevereiro',
        'março',
        'abril',
        'maio',
        'junho',
        'julho',
        'agosto',
        'setembro',
        'outubro',
        'novembro',
        'dezembro',
      ];
      return '${months[date.month - 1]} de ${date.year}';
    }

    final groupedFiles = <String, List<TCloudFile>>{};
    if (_homeFilesSort == 'Mais recentes' || _homeFilesSort == 'Mais antigos') {
      for (final file in filteredFiles) {
        groupedFiles.putIfAbsent(dateGroup(file), () => []).add(file);
      }
    } else {
      groupedFiles['Resultados'] = filteredFiles;
    }

    return RefreshIndicator(
      onRefresh: () async {
        await _loadFolders();
        await _loadMedia();
        await _loadOffline();
      },
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 12, 18, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _deviceSpace == 'phone'
                        ? 'Meu telefone'
                        : _deviceSpace == 'computer'
                        ? 'Meu computador'
                        : 'Olá! O que você procura?',
                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.w900,
                      letterSpacing: -.7,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Seus arquivos, fotos e vídeos em um só lugar.',
                    style: TextStyle(color: TCloudTheme.textSecondary),
                  ),
                  const SizedBox(height: 16),
                  SearchBar(
                    controller: _folderSearchController,
                    hintText: 'Pesquisar no TCloud',
                    leading: const Icon(Icons.search_rounded),
                    trailing: [
                      IconButton(
                        tooltip: 'Filtrar por data e tamanho',
                        onPressed: _showHomeSearchFilters,
                        icon: Badge(
                          isLabelVisible:
                              _homeDateFilter != 'Qualquer data' ||
                              _homeSizeFilter != 'Qualquer tamanho',
                          child: const Icon(Icons.tune_rounded),
                        ),
                      ),
                      if (_folderQuery.isNotEmpty)
                        IconButton(
                          tooltip: 'Limpar busca',
                          onPressed: () {
                            _folderSearchController.clear();
                            setState(() => _folderQuery = '');
                          },
                          icon: const Icon(Icons.close_rounded),
                        ),
                    ],
                    onChanged: (value) => setState(() {
                      _folderQuery = value.trim();
                    }),
                    onSubmitted: _rememberHomeSearch,
                  ),
                  if (_folderQuery.isEmpty &&
                      _homeSearchHistory.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    SizedBox(
                      height: 34,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: _homeSearchHistory.length,
                        separatorBuilder: (_, _) => const SizedBox(width: 7),
                        itemBuilder: (_, index) {
                          final value = _homeSearchHistory[index];
                          return ActionChip(
                            avatar: const Icon(Icons.history_rounded, size: 16),
                            label: Text(value),
                            onPressed: () {
                              _folderSearchController.text = value;
                              setState(() => _folderQuery = value);
                            },
                          );
                        },
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _showPrimaryActions,
                          icon: const Icon(Icons.add_rounded),
                          label: const Text('Adicionar'),
                          style: FilledButton.styleFrom(
                            minimumSize: const Size.fromHeight(48),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(7),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () => _openSection(1),
                          icon: const Icon(Icons.folder_open_rounded),
                          label: const Text('Arquivos'),
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size.fromHeight(48),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(7),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          if (_deviceSpace == 'all')
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 10, 18, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Meus dispositivos',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: _DeviceSpaceCard(
                            icon: Icons.smartphone_rounded,
                            title: 'Meu telefone',
                            subtitle: phoneFolderCount == 0
                                ? 'Backup não configurado'
                                : '$phoneFolderCount ${phoneFolderCount == 1 ? 'pasta' : 'pastas'}',
                            color: TCloudTheme.primary,
                            onTap: () => _openDeviceSpace(phone: true),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: _DeviceSpaceCard(
                            icon: Icons.computer_rounded,
                            title: 'Meu computador',
                            subtitle: computerFolderCount == 0
                                ? 'Nenhum PC conectado'
                                : '$computerFolderCount ${computerFolderCount == 1 ? 'pasta' : 'pastas'}',
                            color: const Color(0xFF35B987),
                            onTap: () => _openDeviceSpace(phone: false),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          if (_deviceSpace == 'all')
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 8, 18, 8),
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: TCloudTheme.surface,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: TCloudTheme.border),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 48,
                            height: 48,
                            decoration: BoxDecoration(
                              color: TCloudTheme.primary.withValues(alpha: .12),
                              borderRadius: BorderRadius.circular(7),
                            ),
                            child: Icon(
                              Icons.cloud_done_rounded,
                              color: TCloudTheme.primary,
                              size: 27,
                            ),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Seu TCloud',
                                  style: TextStyle(
                                    fontWeight: FontWeight.w900,
                                    fontSize: 18,
                                  ),
                                ),
                                Text(
                                  'Arquivos protegidos e disponíveis',
                                  style: TextStyle(
                                    color: TCloudTheme.textSecondary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          _LibraryMetric(
                            value: '${_folders.length}',
                            label: _folders.length == 1 ? 'pasta' : 'pastas',
                          ),
                          const SizedBox(width: 28),
                          _LibraryMetric(
                            value: '${_media.length}',
                            label: _media.length == 1 ? 'mídia' : 'mídias',
                          ),
                          const Spacer(),
                          IconButton.filledTonal(
                            tooltip: 'Sincronizar agora',
                            onPressed: _syncingGallery
                                ? null
                                : () => _runGallerySync(),
                            style: IconButton.styleFrom(
                              backgroundColor: TCloudTheme.primary.withValues(
                                alpha: .10,
                              ),
                              foregroundColor: TCloudTheme.primary,
                            ),
                            icon: _syncingGallery
                                ? SizedBox.square(
                                    dimension: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: TCloudTheme.primary,
                                    ),
                                  )
                                : const Icon(Icons.sync_rounded),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          if (_deviceSpace == 'all')
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(18, 22, 18, 8),
                child: Text(
                  'Acesso rápido',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                ),
              ),
            ),
          if (_deviceSpace == 'all')
            SliverToBoxAdapter(
              child: SizedBox(
                height: 72,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                  children: [
                    _TCloudQuickCard(
                      icon: Icons.offline_pin_outlined,
                      title: TCloudLabels.offline,
                      subtitle: '${_offline.length} itens',
                      onTap: () => _openSection(4),
                    ),
                    const SizedBox(width: 10),
                    _TCloudQuickCard(
                      icon: Icons.sync_alt_rounded,
                      title: 'Transferências',
                      subtitle: 'Envios e downloads',
                      onTap: () => _openSection(2),
                    ),
                    const SizedBox(width: 10),
                    _TCloudQuickCard(
                      icon: Icons.settings_outlined,
                      title: TCloudLabels.settings,
                      subtitle: 'Backup e armazenamento',
                      onTap: () => _openSection(3),
                    ),
                  ],
                ),
              ),
            ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 24, 10, 6),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Pastas',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: _createAlbum,
                    icon: const Icon(Icons.create_new_folder_outlined),
                    label: const Text('Novo'),
                  ),
                ],
              ),
            ),
          ),
          if (_loadingFolders && all.isEmpty)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: CircularProgressIndicator()),
              ),
            )
          else if (albums.isEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(28, 42, 28, 24),
                child: Column(
                  children: [
                    Icon(
                      _deviceSpace == 'computer'
                          ? Icons.computer_outlined
                          : Icons.folder_off_outlined,
                      size: 48,
                      color: TCloudTheme.textSecondary,
                    ),
                    const SizedBox(height: 14),
                    Text(
                      _deviceSpace == 'computer'
                          ? 'Nenhum computador sincronizado'
                          : _deviceSpace == 'phone'
                          ? 'Nenhuma pasta deste telefone'
                          : 'Nenhuma pasta encontrada',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 7),
                    Text(
                      _deviceSpace == 'computer'
                          ? 'Instale o TCloud no computador, entre na mesma conta e ative pelo menos uma pasta para backup.'
                          : _deviceSpace == 'phone'
                          ? 'Ative o backup da galeria ou escolha pastas deste aparelho nas Configurações.'
                          : 'Crie uma pasta ou conecte outro dispositivo à sua conta.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: TCloudTheme.textSecondary,
                        height: 1.35,
                      ),
                    ),
                    if (_deviceSpace != 'all') ...[
                      const SizedBox(height: 18),
                      OutlinedButton.icon(
                        onPressed: _handleLocalBack,
                        icon: const Icon(Icons.arrow_back_rounded),
                        label: const Text('Voltar aos dispositivos'),
                      ),
                    ],
                  ],
                ),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
              sliver: SliverGrid(
                delegate: SliverChildBuilderDelegate((_, i) {
                  final f = albums[i];
                  return _TCloudAlbumCard(
                    key: ValueKey<String>('album:${f.cacheKey}'),
                    folder: f,
                    displayTitle: _deviceSpace == 'phone'
                        ? f.title.replaceFirst(
                            RegExp(r'^\s*Galeria\s*/\s*', caseSensitive: false),
                            '',
                          )
                        : f.title,
                    sourceCount: _repo.sourceCountForFolder(f),
                    onTap: () async {
                      if (f.title.trim().toLowerCase() == 'galeria') {
                        await _showGalleryChildren();
                        return;
                      }

                      await Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => FolderScreen(folder: f),
                        ),
                      );
                    },
                    onOptions: () => _showAlbumActions(f),
                  );
                }, childCount: albums.length),
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 260,
                  crossAxisSpacing: 10,
                  mainAxisSpacing: 10,
                  childAspectRatio: 1.08,
                ),
              ),
            ),
          if (all.length > 12)
            SliverToBoxAdapter(
              child: Center(
                child: TextButton.icon(
                  onPressed: () =>
                      setState(() => _showAllAlbums = !_showAllAlbums),
                  icon: Icon(
                    _showAllAlbums
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                  ),
                  label: Text(
                    _showAllAlbums ? 'Mostrar menos' : 'Ver todas as pastas',
                  ),
                ),
              ),
            ),
          if (continueWatching.isNotEmpty) ...[
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(18, 24, 18, 10),
                child: Text(
                  'Continuar assistindo',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: SizedBox(
                height: 126,
                child: ListView.separated(
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                  scrollDirection: Axis.horizontal,
                  itemCount: continueWatching.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 10),
                  itemBuilder: (_, index) {
                    final file = continueWatching[index];
                    return SizedBox(
                      width: 190,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: _HomeThumbnail(
                          file: file,
                          repo: _repo,
                          selected: _selectedMediaIds.contains(file.fileId),
                          hidePreview: _hideHomePreviews,
                          onLongPress: () => _toggleMediaSelection(file),
                          onTap: () => _openHomeFile(file, continueWatching),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 24, 18, 10),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Recentes',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Text(
                    '${recent.length}',
                    style: TextStyle(color: TCloudTheme.textSecondary),
                  ),
                ],
              ),
            ),
          ),
          if (recent.isEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(18, 8, 18, 130),
                child: Text(
                  'As fotos e vídeos recentes aparecerão aqui.',
                  style: TextStyle(color: TCloudTheme.textSecondary),
                ),
              ),
            )
          else
            SliverToBoxAdapter(
              child: SizedBox(
                height: 250,
                child: NotificationListener<ScrollNotification>(
                  onNotification: (notification) {
                    if (notification is ScrollStartNotification) {
                      _recentCarouselInteracting = true;
                    } else if (notification is ScrollEndNotification) {
                      _recentCarouselInteracting = false;
                    }
                    return false;
                  },
                  child: PageView.builder(
                    controller: _recentCarouselController,
                    physics: const BouncingScrollPhysics(),
                    padEnds: false,
                    itemCount: recent.length,
                    itemBuilder: (_, i) {
                      final f = recent[i];
                      return Padding(
                        padding: EdgeInsets.only(
                          left: i == 0 ? 18 : 5,
                          right: 5,
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: _HomeThumbnail(
                            key: ValueKey<String>(
                              'home-media:${f.chatId}:${f.messageThreadId}:${f.messageId}:${f.fileId}',
                            ),
                            file: f,
                            repo: _repo,
                            selected: _selectedMediaIds.contains(f.fileId),
                            hidePreview: _hideHomePreviews,
                            onLongPress: () => _toggleMediaSelection(f),
                            onTap: () {
                              if (_mediaSelectionMode) {
                                _toggleMediaSelection(f);
                                return;
                              }
                              _openHomeFile(f, recent);
                            },
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 26, 18, 4),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Arquivos',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Text(
                    '${filteredFiles.length}',
                    style: TextStyle(color: TCloudTheme.textSecondary),
                  ),
                  PopupMenuButton<String>(
                    tooltip: 'Organizar e visualizar',
                    icon: const Icon(Icons.tune_rounded),
                    onSelected: (value) {
                      if (value.startsWith('sort:')) {
                        _setHomeFilesSort(value.substring(5));
                      } else if (value.startsWith('grid:')) {
                        _setHomeGridColumns(int.parse(value.substring(5)));
                      } else if (value == 'privacy') {
                        _toggleHomePreviewPrivacy();
                      }
                    },
                    itemBuilder: (_) => [
                      const PopupMenuItem(
                        enabled: false,
                        child: Text('ORDENAR POR'),
                      ),
                      for (final sort in const [
                        'Mais recentes',
                        'Mais antigos',
                        'Nome',
                        'Maior tamanho',
                      ])
                        PopupMenuItem(
                          value: 'sort:$sort',
                          child: Row(
                            children: [
                              Icon(
                                _homeFilesSort == sort
                                    ? Icons.radio_button_checked
                                    : Icons.radio_button_off,
                                size: 19,
                              ),
                              const SizedBox(width: 10),
                              Text(sort),
                            ],
                          ),
                        ),
                      const PopupMenuDivider(),
                      for (final columns in const [2, 3, 4])
                        PopupMenuItem(
                          value: 'grid:$columns',
                          child: Text('$columns colunas'),
                        ),
                      const PopupMenuDivider(),
                      PopupMenuItem(
                        value: 'privacy',
                        child: Row(
                          children: [
                            Icon(
                              _hideHomePreviews
                                  ? Icons.visibility_outlined
                                  : Icons.visibility_off_outlined,
                            ),
                            const SizedBox(width: 10),
                            Text(
                              _hideHomePreviews
                                  ? 'Mostrar miniaturas'
                                  : 'Ocultar miniaturas',
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: SizedBox(
              height: 52,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 6,
                ),
                children: [
                  for (final filter in const ['Todos', 'Fotos', 'Vídeos'])
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: FilterChip(
                        label: Text(filter),
                        selected: _homeFilesFilter == filter,
                        onSelected: (_) =>
                            setState(() => _homeFilesFilter = filter),
                      ),
                    ),
                  for (final filter in const [
                    'Documentos',
                    'Capturas',
                    'Favoritos',
                    'Offline',
                    'Duplicados',
                  ])
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: FilterChip(
                        label: Text(filter),
                        selected: _homeFilesFilter == filter,
                        onSelected: (_) =>
                            setState(() => _homeFilesFilter = filter),
                      ),
                    ),
                ],
              ),
            ),
          ),
          if (filteredFiles.isEmpty)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(18, 16, 18, 130),
                child: Text('Nenhum arquivo encontrado neste filtro.'),
              ),
            )
          else
            for (final group in groupedFiles.entries) ...[
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(18, 14, 18, 8),
                  child: Text(
                    group.key,
                    style: TextStyle(
                      color: TCloudTheme.textSecondary,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
              SliverPadding(
                padding: EdgeInsets.fromLTRB(
                  12,
                  0,
                  12,
                  group.key == groupedFiles.keys.last ? 130 : 8,
                ),
                sliver: SliverGrid.builder(
                  itemCount: group.value.length,
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: _homeGridColumns,
                    crossAxisSpacing: 6,
                    mainAxisSpacing: 10,
                    childAspectRatio: .78,
                  ),
                  itemBuilder: (context, index) {
                    final file = group.value[index];
                    return _HomeFileGridTile(
                      file: file,
                      repo: _repo,
                      selected: _selectedMediaIds.contains(file.fileId),
                      hidePreview: _hideHomePreviews,
                      onLongPress: () => _toggleMediaSelection(file),
                      onTap: () {
                        if (_mediaSelectionMode) {
                          _toggleMediaSelection(file);
                          return;
                        }
                        _openHomeFile(file, filteredFiles);
                      },
                    );
                  },
                ),
              ),
            ],
        ],
      ),
    );
  }

  Widget _filesPage() {
    final query = _folderQuery.trim().toLowerCase();
    final folders = <String, TCloudFolder>{};
    for (final folder in _folders) {
      if (folder.title.trim().toLowerCase().startsWith('galeria / ')) continue;
      folders[folder.cacheKey] = folder;
    }

    final visibleFolders =
        folders.values.where((folder) {
          return query.isEmpty ||
              folder.title.toLowerCase().contains(query) ||
              folder.forumTitle.toLowerCase().contains(query);
        }).toList()..sort(
          (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
        );

    final visibleFiles = _allFiles.where((file) {
      final trashed = _trash.contains(file.contentIdentity);
      final matchesQuery =
          query.isEmpty ||
          file.name.toLowerCase().contains(query) ||
          file.kind.toLowerCase().contains(query);
      if (_filesFilter == 'Lixeira') return trashed && matchesQuery;
      if (trashed) return false;
      final matchesType = switch (_filesFilter) {
        'Imagens' => file.isImage,
        'Vídeos' => file.isVideo,
        'Offline' => _offline.any(
          (item) => item.contentIdentity == file.contentIdentity,
        ),
        'Favoritos' => _favorites.contains(file.contentIdentity),
        _ => true,
      };
      return matchesQuery && matchesType;
    }).toList();

    Future<void> openFolder(TCloudFolder folder) async {
      if (folder.title.trim().toLowerCase() == 'galeria') {
        await _showGalleryChildren();
        return;
      }
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => FolderScreen(folder: folder)),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadEverything,
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
              child: SearchBar(
                controller: _folderSearchController,
                hintText: 'Pesquisar em todos os arquivos',
                leading: const Icon(Icons.search_rounded),
                trailing: [
                  if (_folderQuery.isNotEmpty)
                    IconButton(
                      tooltip: 'Limpar',
                      onPressed: () {
                        _folderSearchController.clear();
                        setState(() => _folderQuery = '');
                      },
                      icon: const Icon(Icons.close_rounded),
                    ),
                ],
                onChanged: (value) =>
                    setState(() => _folderQuery = value.trim()),
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: SizedBox(
              height: 54,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 7,
                ),
                children: [
                  for (final filter in const [
                    'Todos',
                    'Imagens',
                    'Vídeos',
                    'Favoritos',
                    'Offline',
                    'Lixeira',
                  ])
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: FilterChip(
                        label: Text(filter),
                        selected: _filesFilter == filter,
                        onSelected: (_) =>
                            setState(() => _filesFilter = filter),
                      ),
                    ),
                ],
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 8, 6),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Pastas',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: _filesGrid
                        ? 'Mostrar em lista'
                        : 'Mostrar em grade',
                    onPressed: () => setState(() => _filesGrid = !_filesGrid),
                    icon: Icon(
                      _filesGrid
                          ? Icons.view_list_outlined
                          : Icons.grid_view_outlined,
                    ),
                  ),
                  PopupMenuButton<String>(
                    tooltip: 'Opções',
                    onSelected: (value) {
                      if (value == 'new') _createAlbum();
                      if (value == 'sync') _runGallerySync();
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'new', child: Text('Nova pasta')),
                      PopupMenuItem(
                        value: 'sync',
                        child: Text('Sincronizar agora'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          if (_loadingFolders && visibleFolders.isEmpty)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: CircularProgressIndicator()),
              ),
            )
          else if (visibleFolders.isEmpty)
            const SliverToBoxAdapter(
              child: _DriveEmptyState(
                icon: Icons.folder_off_outlined,
                title: 'Nenhuma pasta encontrada',
                message: 'Crie uma pasta ou ajuste os filtros da pesquisa.',
              ),
            )
          else if (_filesGrid)
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              sliver: SliverGrid(
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 240,
                  childAspectRatio: 2.25,
                  crossAxisSpacing: 10,
                  mainAxisSpacing: 10,
                ),
                delegate: SliverChildBuilderDelegate((_, index) {
                  final folder = visibleFolders[index];
                  return _DriveFolderTile(
                    folder: folder,
                    sourceCount: _repo.sourceCountForFolder(folder),
                    grid: true,
                    onTap: () => openFolder(folder),
                    onOptions: () => _showAlbumActions(folder),
                  );
                }, childCount: visibleFolders.length),
              ),
            )
          else
            SliverList.builder(
              itemCount: visibleFolders.length,
              itemBuilder: (_, index) {
                final folder = visibleFolders[index];
                return _DriveFolderTile(
                  folder: folder,
                  sourceCount: _repo.sourceCountForFolder(folder),
                  grid: false,
                  onTap: () => openFolder(folder),
                  onOptions: () => _showAlbumActions(folder),
                );
              },
            ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 24, 18, 8),
              child: Text(
                _filesFilter == 'Todos' ? 'Arquivos recentes' : _filesFilter,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
          if (visibleFiles.isEmpty)
            const SliverToBoxAdapter(
              child: _DriveEmptyState(
                icon: Icons.search_off_rounded,
                title: 'Nenhum arquivo encontrado',
                message: 'Tente outro nome ou tipo de arquivo.',
              ),
            )
          else
            SliverList.builder(
              itemCount: visibleFiles.take(80).length,
              itemBuilder: (_, index) {
                final file = visibleFiles[index];
                return _DriveFileTile(
                  file: file,
                  favorite: _favorites.contains(file.contentIdentity),
                  offline: _offline.any(
                    (item) => item.contentIdentity == file.contentIdentity,
                  ),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) =>
                          MediaViewerScreen(file: file, files: visibleFiles),
                    ),
                  ),
                  onOptions: () => _showDriveFileActions(file),
                );
              },
            ),
          const SliverToBoxAdapter(child: SizedBox(height: 120)),
        ],
      ),
    );
  }

  Widget _body() {
    switch (_currentIndex) {
      case 1:
        return _filesPage();
      case 2:
        return _transfersPage();
      case 3:
        return _settingsPage();
      case 4:
        return _offlinePage();
      case 0:
      default:
        return _tcloudGalleryHomePage();
    }
  }

  Future<void> _openDeviceSpace({required bool phone}) async {
    setState(() {
      _currentIndex = 0;
      _selectedFolderKey = 'all';
      _folderQuery = '';
      _deviceSpace = phone ? 'phone' : 'computer';
    });
    await _loadFolders();
    await _loadMedia();
  }

  bool get _hasLocalBackAction =>
      _mediaSelectionMode ||
      _currentIndex != 0 ||
      _deviceSpace != 'all' ||
      _selectedFolderKey != 'all' ||
      _folderQuery.isNotEmpty ||
      _mediaQuery.isNotEmpty ||
      _showMediaSearch;

  void _openSection(int index) {
    if (index == _currentIndex && index != 0) return;

    setState(() {
      _currentIndex = index;

      if (index == 0) {
        _selectedFolderKey = 'all';
        _mediaQuery = '';
        _showMediaSearch = false;
      }
    });

    if (index == 0) {
      unawaited(_loadMedia());
    }
  }

  void _handleLocalBack() {
    if (_mediaSelectionMode) {
      _clearMediaSelection();
      return;
    }

    if (_currentIndex != 0) {
      _openSection(0);
      return;
    }

    if (_deviceSpace != 'all') {
      setState(() => _deviceSpace = 'all');
      return;
    }

    if (_selectedFolderKey != 'all' ||
        _mediaQuery.isNotEmpty ||
        _showMediaSearch) {
      setState(() {
        _selectedFolderKey = 'all';
        _mediaQuery = '';
        _showMediaSearch = false;
      });
      unawaited(_loadMedia());
      return;
    }

    if (_folderQuery.isNotEmpty) {
      _folderSearchController.clear();
      setState(() => _folderQuery = '');
    }
  }

  @override
  Widget build(BuildContext context) {
    final insideFolder = _currentIndex == 0 && _selectedFolderKey != 'all';

    return PopScope(
      canPop: !_hasLocalBackAction,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _handleLocalBack();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: insideFolder || _currentIndex == 4 || _deviceSpace != 'all'
              ? IconButton(
                  tooltip: 'Voltar ao início',
                  onPressed: _handleLocalBack,
                  icon: const Icon(Icons.arrow_back_rounded),
                )
              : null,
          toolbarHeight: 60,
          title: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(7),
                ),
                clipBehavior: Clip.antiAlias,
                child: Image.asset(
                  'assets/brand/tcloud-logo.png',
                  fit: BoxFit.cover,
                ),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(switch (_currentIndex) {
                      0 when _deviceSpace == 'phone' => 'Meu telefone',
                      0 when _deviceSpace == 'computer' => 'Meu computador',
                      0 => 'TCloud',
                      1 => TCloudLabels.files,
                      2 => 'Transferências',
                      3 => TCloudLabels.settings,
                      4 => TCloudLabels.offline,
                      _ => 'TCloud',
                    }, style: const TextStyle(fontWeight: FontWeight.w800)),
                    Text(
                      _deviceSpace != 'all'
                          ? 'Pastas desta conta'
                          : _syncingGallery
                          ? 'Sincronizando sua nuvem'
                          : 'Seus arquivos, em um só lugar',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          actions: [
            if (_syncingGallery)
              const Padding(
                padding: EdgeInsets.only(right: 12),
                child: Center(
                  child: SizedBox.square(
                    dimension: 19,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              )
            else
              IconButton(
                tooltip: 'Sincronizar agora',
                onPressed: () => _runGallerySync(),
                icon: const Icon(Icons.cloud_sync_outlined),
              ),
            const SizedBox(width: 4),
          ],
        ),
        body: _body(),
        floatingActionButton: _mediaSelectionMode
            ? null
            : FloatingActionButton.extended(
                onPressed: _showPrimaryActions,
                icon: const Icon(Icons.add_rounded),
                label: const Text('Novo'),
              ),
        bottomNavigationBar: _currentIndex == 0 && _mediaSelectionMode
            ? _MediaSelectionHotbar(
                count: _selectedMediaIds.length,
                onCancel: _clearMediaSelection,
                onSelectAll: _selectAllVisibleHomeFiles,
                onFavorite: _favoriteSelectedMedia,
                onMove: _moveSelectedMedia,
                onDelete: _deleteSelectedMedia,
                onOffline: _offlineSelectedMedia,
                onShare: _shareSelectedMedia,
                onInfo: () {
                  final selected = _selectedMedia;

                  if (selected.length == 1) {
                    _showMediaInfo(selected.first);
                  }
                },
              )
            : NavigationBar(
                selectedIndex: _currentIndex == 4 ? 1 : _currentIndex,
                onDestinationSelected: _openSection,
                destinations: const [
                  NavigationDestination(
                    icon: Icon(Icons.home_outlined),
                    selectedIcon: Icon(Icons.home_rounded),
                    label: 'Início',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.folder_outlined),
                    selectedIcon: Icon(Icons.folder_rounded),
                    label: 'Arquivos',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.swap_vert_circle_outlined),
                    selectedIcon: Icon(Icons.swap_vert_circle_rounded),
                    label: 'Atividade',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.settings_outlined),
                    selectedIcon: Icon(Icons.settings_rounded),
                    label: 'Ajustes',
                  ),
                ],
              ),
      ),
    );
  }
}

class _PairingQrScannerScreen extends StatefulWidget {
  const _PairingQrScannerScreen();

  @override
  State<_PairingQrScannerScreen> createState() =>
      _PairingQrScannerScreenState();
}

class _PairingQrScannerScreenState extends State<_PairingQrScannerScreen> {
  final MobileScannerController _controller = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
    detectionSpeed: DetectionSpeed.noDuplicates,
  );
  bool _completed = false;

  String? _pairingCode(String raw) {
    final value = raw.trim();
    final uri = Uri.tryParse(value);
    final candidate = uri?.scheme == 'tcloud' && uri?.host == 'pair'
        ? uri?.queryParameters['code'] ?? ''
        : value;
    final code = candidate.replaceAll('-', '').toUpperCase();
    return RegExp(r'^[A-F0-9]{10}$').hasMatch(code) ? code : null;
  }

  void _detected(BarcodeCapture capture) {
    if (_completed) return;
    for (final barcode in capture.barcodes) {
      final code = _pairingCode(barcode.rawValue ?? '');
      if (code == null) continue;
      _completed = true;
      _controller.stop();
      Navigator.of(context).pop(code);
      return;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Ler QR do TCloud')),
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(controller: _controller, onDetect: _detected),
          Center(
            child: Container(
              width: 250,
              height: 250,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white, width: 3),
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ),
          const Positioned(
            right: 24,
            bottom: 42,
            left: 24,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Color(0xCC111827),
                borderRadius: BorderRadius.all(Radius.circular(8)),
              ),
              child: Padding(
                padding: EdgeInsets.all(14),
                child: Text(
                  'Aponte a câmera para o QR exibido nas Configurações do TCloud Web.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MediaSelectionHotbar extends StatelessWidget {
  const _MediaSelectionHotbar({
    required this.count,
    required this.onCancel,
    required this.onSelectAll,
    required this.onFavorite,
    required this.onMove,
    required this.onDelete,
    required this.onOffline,
    required this.onShare,
    required this.onInfo,
  });

  final int count;
  final VoidCallback onCancel;
  final VoidCallback onSelectAll;
  final VoidCallback onFavorite;
  final VoidCallback onMove;
  final VoidCallback onDelete;
  final VoidCallback onOffline;
  final VoidCallback onShare;
  final VoidCallback onInfo;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      minimum: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      child: Container(
        height: 70,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: TCloudTheme.surface.withValues(alpha: .98),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: TCloudTheme.border),
          boxShadow: const [
            BoxShadow(
              blurRadius: 20,
              offset: Offset(0, 8),
              color: Color(0x33000000),
            ),
          ],
        ),
        child: Row(
          children: [
            IconButton(
              tooltip: 'Cancelar selecao',
              onPressed: onCancel,
              icon: const Icon(Icons.close),
            ),
            Expanded(
              child: Text(
                '$count selecionado(s)',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            PopupMenuButton<String>(
              tooltip: 'Mais ações',
              onSelected: (value) {
                if (value == 'all') onSelectAll();
                if (value == 'favorite') onFavorite();
                if (value == 'move') onMove();
              },
              itemBuilder: (_) => const [
                PopupMenuItem(
                  value: 'all',
                  child: Text('Selecionar todos os visíveis'),
                ),
                PopupMenuItem(
                  value: 'favorite',
                  child: Text('Adicionar aos favoritos'),
                ),
                PopupMenuItem(value: 'move', child: Text('Mover para pasta')),
              ],
            ),
            IconButton(
              tooltip: 'Offline',
              onPressed: onOffline,
              icon: const Icon(Icons.offline_pin_outlined),
            ),
            IconButton(
              tooltip: 'Compartilhar',
              onPressed: onShare,
              icon: const Icon(Icons.share_outlined),
            ),
            if (count == 1)
              IconButton(
                tooltip: 'Informacoes',
                onPressed: onInfo,
                icon: const Icon(Icons.info_outline),
              ),
            IconButton(
              tooltip: 'Excluir',
              onPressed: onDelete,
              icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
            ),
          ],
        ),
      ),
    );
  }
}

class _StorageMetricCard extends StatelessWidget {
  const _StorageMetricCard({
    required this.label,
    required this.value,
    required this.icon,
  });

  final String label;
  final String value;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final width = (MediaQuery.sizeOf(context).width - 50) / 2;
    return Container(
      width: width,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: TCloudTheme.surfaceSoft,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: TCloudTheme.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: TCloudTheme.primary),
          const SizedBox(height: 10),
          Text(
            value,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: TextStyle(fontSize: 12, color: TCloudTheme.textSecondary),
          ),
        ],
      ),
    );
  }
}

class _FileInfoRow extends StatelessWidget {
  const _FileInfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 112,
            child: Text(
              label,
              style: TextStyle(color: TCloudTheme.textSecondary),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

class _FolderAlbumCard extends StatefulWidget {
  const _FolderAlbumCard({
    required this.folder,
    required this.repo,
    required this.onTap,
    required this.onLongPress,
  });

  final TCloudFolder folder;
  final TCloudRepository repo;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  State<_FolderAlbumCard> createState() => _FolderAlbumCardState();
}

class _FolderAlbumCardState extends State<_FolderAlbumCard> {
  List<TCloudFile> _items = <TCloudFile>[];
  bool _hasMore = false;
  bool _loading = true;
  static final Map<String, List<TCloudFile>> _albumSnapshotCache =
      <String, List<TCloudFile>>{};
  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  @override
  void didUpdateWidget(covariant _FolderAlbumCard oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.folder.cacheKey != widget.folder.cacheKey) {
      _load();
    }
  }

  List<TCloudFile> _stableAlbumItems(Iterable<TCloudFile> source) {
    final unique = <String, TCloudFile>{};

    for (final file in source) {
      unique[file.contentIdentity] = file;
    }

    final result = unique.values.toList();

    result.sort((a, b) {
      final byDate = b.createdAt.compareTo(a.createdAt);

      if (byDate != 0) {
        return byDate;
      }

      final byMessage = b.messageId.compareTo(a.messageId);

      if (byMessage != 0) {
        return byMessage;
      }

      return b.fileId.compareTo(a.fileId);
    });

    return result;
  }

  Future<void> _load() async {
    final requestedFolder = widget.folder;
    final requestedKey = requestedFolder.cacheKey;
    final generation = ++_loadGeneration;

    final snapshot = _albumSnapshotCache[requestedKey];

    if (mounted && snapshot != null && snapshot.isNotEmpty) {
      setState(() {
        _items = List<TCloudFile>.from(snapshot);
        _loading = false;
      });
    } else {
      try {
        final cached = await widget.repo.loadCachedFilePage(requestedFolder);

        if (mounted &&
            generation == _loadGeneration &&
            requestedKey == widget.folder.cacheKey &&
            cached.files.isNotEmpty) {
          final stable = _stableAlbumItems(cached.files);

          _albumSnapshotCache[requestedKey] = stable;

          if (_albumSnapshotCache.length > 80) {
            _albumSnapshotCache.remove(_albumSnapshotCache.keys.first);
          }

          setState(() {
            _items = stable;
            _hasMore = cached.hasMore;
            _loading = false;
          });
        }
      } catch (_) {}
    }

    try {
      final page = await widget.repo.loadFilePage(requestedFolder, limit: 16);

      if (!mounted ||
          generation != _loadGeneration ||
          requestedKey != widget.folder.cacheKey) {
        return;
      }

      final stable = _stableAlbumItems(page.files);

      _albumSnapshotCache[requestedKey] = stable;

      if (_albumSnapshotCache.length > 80) {
        _albumSnapshotCache.remove(_albumSnapshotCache.keys.first);
      }

      setState(() {
        _items = stable;
        _hasMore = page.hasMore;
        _loading = false;
      });
    } catch (_) {
      if (!mounted ||
          generation != _loadGeneration ||
          requestedKey != widget.folder.cacheKey) {
        return;
      }

      if (_items.isEmpty) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    TCloudFile? cover;

    for (final file in _items) {
      if (file.isMedia) {
        cover = file;
        break;
      }
    }

    final countLabel = _hasMore
        ? '${_items.length}+ itens'
        : '${_items.length} ${_items.length == 1 ? 'item' : 'itens'}';

    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Container(
                width: double.infinity,
                color: TCloudTheme.surface,
                child: _loading
                    ? const Center(
                        child: SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : cover == null
                    ? Center(
                        child: Icon(
                          Icons.folder_outlined,
                          size: 46,
                          color: TCloudTheme.textSecondary,
                        ),
                      )
                    : IgnorePointer(
                        child: _HomeThumbnail(
                          key: ValueKey<String>(
                            'album-cover:${widget.folder.cacheKey}:${cover.chatId}:${cover.messageId}:${cover.fileId}',
                          ),
                          file: cover,
                          repo: widget.repo,
                          selected: false,
                          onTap: () {},
                          onLongPress: () {},
                        ),
                      ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            widget.folder.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 2),
          Text(
            countLabel,
            maxLines: 1,
            style: TextStyle(color: TCloudTheme.textSecondary, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

// ignore: unused_element
class _NewFolderAlbumCard extends StatelessWidget {
  const _NewFolderAlbumCard({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Container(
              width: double.infinity,
              decoration: BoxDecoration(
                color: TCloudTheme.primary.withValues(alpha: .09),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: TCloudTheme.primary.withValues(alpha: .32),
                ),
              ),
              child: Center(
                child: Icon(
                  Icons.create_new_folder_outlined,
                  size: 44,
                  color: TCloudTheme.primary,
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Novo \u00e1lbum',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 2),
          Text(
            'Criar',
            style: TextStyle(color: TCloudTheme.textSecondary, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class _TCloudQuickCard extends StatelessWidget {
  const _TCloudQuickCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 166,
      child: Material(
        color: TCloudTheme.surface,
        borderRadius: BorderRadius.circular(8),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(13),
            child: Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: TCloudTheme.primary.withValues(alpha: .14),
                    borderRadius: BorderRadius.circular(7),
                  ),
                  child: Icon(icon, color: TCloudTheme.primary),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w800),
                      ),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: TCloudTheme.textSecondary,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DeviceSpaceCard extends StatelessWidget {
  const _DeviceSpaceCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.color,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: TCloudTheme.surface,
    borderRadius: BorderRadius.circular(8),
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        constraints: const BoxConstraints(minHeight: 132),
        padding: const EdgeInsets.all(15),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: TCloudTheme.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: color.withValues(alpha: .13),
                borderRadius: BorderRadius.circular(7),
              ),
              child: Icon(icon, color: color),
            ),
            const Spacer(),
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 2),
            Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: TCloudTheme.textSecondary),
            ),
          ],
        ),
      ),
    ),
  );
}

class _LibraryMetric extends StatelessWidget {
  const _LibraryMetric({required this.value, required this.label});

  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          value,
          style: TextStyle(
            color: TCloudTheme.textPrimary,
            fontSize: 24,
            height: 1,
            fontWeight: FontWeight.w900,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: TextStyle(
            color: TCloudTheme.textSecondary,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

class _TCloudAlbumCard extends StatelessWidget {
  const _TCloudAlbumCard({
    super.key,
    required this.folder,
    this.displayTitle,
    required this.sourceCount,
    required this.onTap,
    required this.onOptions,
  });
  final TCloudFolder folder;
  final String? displayTitle;
  final int sourceCount;
  final VoidCallback onTap;
  final VoidCallback onOptions;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: TCloudTheme.surface,
      borderRadius: BorderRadius.circular(8),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: onOptions,
        child: Stack(
          fit: StackFit.expand,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [TCloudTheme.surfaceSoft, TCloudTheme.surface],
                ),
              ),
            ),
            Center(
              child: Icon(
                folder.isGeneral ? Icons.forum_outlined : Icons.folder_outlined,
                size: 56,
                color: TCloudTheme.primary,
              ),
            ),
            Positioned(
              left: 13,
              right: 5,
              bottom: 6,
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          displayTitle ?? folder.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w900),
                        ),
                        Text(
                          folder.isGeneral
                              ? 'Pasta principal'
                              : sourceCount > 1
                              ? '$sourceCount pastas unificadas'
                              : folder.forumTitle.trim().isNotEmpty
                              ? folder.forumTitle.trim()
                              : 'Pasta do TCloud',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: TCloudTheme.textSecondary,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    onPressed: onOptions,
                    icon: const Icon(Icons.more_vert, size: 20),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DriveFolderTile extends StatelessWidget {
  const _DriveFolderTile({
    required this.folder,
    required this.sourceCount,
    required this.grid,
    required this.onTap,
    required this.onOptions,
  });

  final TCloudFolder folder;
  final int sourceCount;
  final bool grid;
  final VoidCallback onTap;
  final VoidCallback onOptions;

  @override
  Widget build(BuildContext context) {
    final subtitle = sourceCount > 1
        ? '$sourceCount pastas unificadas'
        : folder.isGeneral
        ? 'Pasta principal'
        : 'Pasta do TCloud';

    return Padding(
      padding: grid
          ? EdgeInsets.zero
          : const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      child: Card(
        margin: EdgeInsets.zero,
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          onLongPress: onOptions,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 11, 4, 11),
            child: Row(
              children: [
                Icon(
                  folder.isGeneral ? Icons.forum_rounded : Icons.folder_rounded,
                  size: 30,
                  color: TCloudTheme.primary,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        folder.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: TCloudTheme.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Mais opções',
                  onPressed: onOptions,
                  icon: const Icon(Icons.more_vert_rounded),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DriveFileTile extends StatelessWidget {
  const _DriveFileTile({
    required this.file,
    required this.favorite,
    required this.offline,
    required this.onTap,
    required this.onOptions,
  });

  final TCloudFile file;
  final bool favorite;
  final bool offline;
  final VoidCallback onTap;
  final VoidCallback onOptions;

  String _size(int bytes) {
    if (bytes <= 0) return 'Tamanho desconhecido';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  @override
  Widget build(BuildContext context) {
    final icon = file.isImage
        ? Icons.image_outlined
        : file.isVideo
        ? Icons.movie_outlined
        : Icons.insert_drive_file_outlined;
    final color = file.isImage
        ? const Color(0xFF188038)
        : file.isVideo
        ? const Color(0xFF9334E6)
        : TCloudTheme.primary;

    return ListTile(
      contentPadding: const EdgeInsets.only(left: 18, right: 6),
      leading: Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          color: color.withValues(alpha: .10),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(icon, color: color),
      ),
      title: Text(file.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${file.kind} • ${_size(file.size)}'
        '${favorite ? ' • Favorito' : ''}${offline ? ' • Offline' : ''}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: IconButton(
        tooltip: 'Mais opções',
        onPressed: onOptions,
        icon: const Icon(Icons.more_vert_rounded),
      ),
      isThreeLine: false,
      onTap: onTap,
    );
  }
}

class _DriveEmptyState extends StatelessWidget {
  const _DriveEmptyState({
    required this.icon,
    required this.title,
    required this.message,
  });

  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 30),
      child: Column(
        children: [
          Icon(icon, size: 46, color: TCloudTheme.textSecondary),
          const SizedBox(height: 12),
          Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(color: TCloudTheme.textSecondary),
          ),
        ],
      ),
    );
  }
}

class _HomeFileGridTile extends StatelessWidget {
  const _HomeFileGridTile({
    required this.file,
    required this.repo,
    required this.selected,
    this.hidePreview = false,
    required this.onTap,
    required this.onLongPress,
  });

  final TCloudFile file;
  final TCloudRepository repo;
  final bool selected;
  final bool hidePreview;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: TCloudTheme.surface,
      borderRadius: BorderRadius.circular(8),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: _HomeThumbnail(
              file: file,
              repo: repo,
              selected: selected,
              hidePreview: hidePreview,
              onTap: onTap,
              onLongPress: onLongPress,
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(9, 8, 9, 2),
            child: Text(
              file.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(9, 0, 9, 8),
            child: Text(
              file.isImage
                  ? 'Foto'
                  : file.isVideo
                  ? 'Vídeo'
                  : file.kind,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 10, color: TCloudTheme.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

class _HomeThumbnail extends StatefulWidget {
  const _HomeThumbnail({
    super.key,
    required this.file,
    required this.repo,
    required this.selected,
    this.hidePreview = false,
    required this.onTap,
    required this.onLongPress,
    this.onLongPressStart,
    this.onLongPressMoveUpdate,
    this.onLongPressEnd,
    this.onLongPressCancel,
  });

  final TCloudFile file;
  final TCloudRepository repo;
  final bool selected;
  final bool hidePreview;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final GestureLongPressStartCallback? onLongPressStart;
  final GestureLongPressMoveUpdateCallback? onLongPressMoveUpdate;
  final GestureLongPressEndCallback? onLongPressEnd;
  final VoidCallback? onLongPressCancel;

  @override
  State<_HomeThumbnail> createState() => _HomeThumbnailState();
}

class _HomeThumbnailState extends State<_HomeThumbnail> {
  final _cache = ThumbnailCacheService.instance;

  String? _path;
  int _previewRequestGeneration = 0;

  @override
  void initState() {
    super.initState();
    _path = widget.file.thumbnailLocalPath;
    if (!widget.hidePreview) _upgradePreviewForCurrentFile();
  }

  String _previewIdentity(TCloudFile file) {
    return '${file.chatId}:'
        '${file.messageThreadId}:'
        '${file.messageId}:'
        '${file.fileId}:'
        '${file.thumbnailFileId}';
  }

  @override
  void didUpdateWidget(covariant _HomeThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.hidePreview) {
      _previewRequestGeneration++;
      return;
    }

    if (oldWidget.hidePreview ||
        _previewIdentity(oldWidget.file) != _previewIdentity(widget.file)) {
      _previewRequestGeneration++;
      _path = widget.file.thumbnailLocalPath;
      _upgradePreviewForCurrentFile();
    }
  }

  Future<void> _upgradePreviewForCurrentFile() async {
    final requestedFile = widget.file;
    final requestedIdentity = _previewIdentity(requestedFile);
    final generation = ++_previewRequestGeneration;

    try {
      final path = await _cache.fullPreviewPath(requestedFile);

      if (!mounted ||
          generation != _previewRequestGeneration ||
          requestedIdentity != _previewIdentity(widget.file) ||
          path == null ||
          path.isEmpty) {
        return;
      }

      setState(() {
        _path = path;
      });
    } catch (_) {}
  }

  String? _duration() {
    final seconds = widget.file.durationSeconds;

    if (!widget.file.isVideo || seconds <= 0) return null;

    final minutes = seconds ~/ 60;
    final remainder = seconds % 60;

    return '$minutes:${remainder.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final path = _path;

    final canShowFile =
        path != null && path.isNotEmpty && File(path).existsSync();

    final instant = _cache.instantPreview(widget.file);

    final Widget image = widget.hidePreview
        ? ColoredBox(
            color: TCloudTheme.surfaceSoft,
            child: Center(
              child: Icon(
                Icons.visibility_off_outlined,
                color: TCloudTheme.textSecondary,
                size: 32,
              ),
            ),
          )
        : canShowFile
        ? Image.file(
            File(path),
            key: ValueKey<String>('file:$path'),
            fit: BoxFit.cover,
            cacheWidth: 384,
            filterQuality: FilterQuality.low,
            gaplessPlayback: false,
            errorBuilder: (_, _, _) => _instantOrFallback(instant),
          )
        : _instantOrFallback(instant);

    final duration = _duration();

    return GestureDetector(
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      onLongPressStart: widget.onLongPressStart,
      onLongPressMoveUpdate: widget.onLongPressMoveUpdate,
      onLongPressEnd: widget.onLongPressEnd,
      onLongPressCancel: widget.onLongPressCancel,
      child: Stack(
        fit: StackFit.expand,
        children: [
          image,
          if (widget.selected)
            Container(color: TCloudTheme.primary.withValues(alpha: .28)),
          if (widget.selected)
            Positioned(
              top: 6,
              right: 6,
              child: CircleAvatar(
                radius: 12,
                backgroundColor: TCloudTheme.primary,
                child: Icon(Icons.check, color: Colors.white, size: 16),
              ),
            ),
          if (widget.file.isVideo)
            Center(
              child: Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: .50),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.play_arrow_rounded,
                  color: Colors.white,
                  size: 30,
                ),
              ),
            ),
          if (duration != null)
            Positioned(
              right: 5,
              bottom: 5,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: .68),
                  borderRadius: BorderRadius.circular(5),
                ),
                child: Text(
                  duration,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _instantOrFallback(Uint8List? instant) {
    if (instant != null && instant.isNotEmpty) {
      return Image.memory(
        instant,
        key: ValueKey<int>(widget.file.fileId),
        fit: BoxFit.cover,
        cacheWidth: 192,
        filterQuality: FilterQuality.low,
        gaplessPlayback: false,
      );
    }

    final extension = widget.file.name.split('.').last.toLowerCase();
    final icon = widget.file.isVideo
        ? Icons.movie_outlined
        : widget.file.isImage
        ? Icons.image_outlined
        : extension == 'pdf'
        ? Icons.picture_as_pdf_outlined
        : const {'mp3', 'wav', 'm4a', 'ogg', 'flac'}.contains(extension)
        ? Icons.audio_file_outlined
        : const {'zip', 'rar', '7z', 'tar', 'gz'}.contains(extension)
        ? Icons.folder_zip_outlined
        : Icons.insert_drive_file_outlined;
    return ColoredBox(
      color: TCloudTheme.surfaceSoft,
      child: Center(child: Icon(icon, color: TCloudTheme.primary, size: 34)),
    );
  }
}

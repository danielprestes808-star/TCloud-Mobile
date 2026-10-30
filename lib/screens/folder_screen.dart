import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:open_filex/open_filex.dart';

import '../core/tcloud_theme.dart';
import '../models/tcloud_file.dart';
import '../models/tcloud_folder.dart';
import '../models/tcloud_transfer.dart';
import '../services/tcloud_repository.dart';
import '../services/transfer_center.dart';
import '../services/thumbnail_cache_service.dart';
import '../services/folder_share_service.dart';
import '../telegram/tdlib_service.dart';
import 'face_groups_screen.dart';
import 'media_viewer_screen.dart';

enum _ViewMode { list, gallery }

enum _SortMode { newest, name, size, type }

enum _MediaFilter { all, images, videos }

class FolderScreen extends StatefulWidget {
  const FolderScreen({super.key, required this.folder});

  final TCloudFolder folder;

  @override
  State<FolderScreen> createState() => _FolderScreenState();
}

class _FolderScreenState extends State<FolderScreen> {
  final _repo = TCloudRepository.instance;
  final _scrollController = ScrollController();
  final Map<String, GlobalKey> _dragTileKeys = <String, GlobalKey>{};
  final Set<String> _dragVisited = <String>{};

  final List<TCloudFile> _files = <TCloudFile>[];
  final Set<int> _selectedFileIds = <int>{};

  Timer? _dragAutoScrollTimer;
  Offset? _dragLastGlobalPosition;
  double _dragAutoScrollVelocity = 0;
  bool _dragActive = false;
  bool _dragSelectValue = true;

  bool _loading = true;
  bool _refreshing = false;
  bool _loadingMore = false;
  bool _hasMore = false;
  bool _autoViewApplied = false;

  int _nextFromMessageId = 0;
  Map<String, int> _nextFromMessageIds = const <String, int>{};

  String? _error;
  String _query = '';

  _ViewMode _viewMode = _ViewMode.list;
  _SortMode _sortMode = _SortMode.newest;
  _MediaFilter _mediaFilter = _MediaFilter.all;

  bool get _selectionMode => _selectedFileIds.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_handleScroll);
    _loadInitial();
  }

  @override
  void dispose() {
    _stopDragAutoScroll();
    _scrollController
      ..removeListener(_handleScroll)
      ..dispose();
    super.dispose();
  }

  String _dragIdentity(TCloudFile file) =>
      '${file.chatId}:${file.messageId}:${file.fileId}';

  GlobalKey _dragTileKey(TCloudFile file) =>
      _dragTileKeys.putIfAbsent(_dragIdentity(file), GlobalKey.new);

  TCloudFile? _fileAtGlobalPosition(Offset globalPosition) {
    for (final file in _visible) {
      final tileContext = _dragTileKeys[_dragIdentity(file)]?.currentContext;
      final renderObject = tileContext?.findRenderObject();
      if (renderObject is! RenderBox || !renderObject.hasSize) continue;
      final rect = renderObject.localToGlobal(Offset.zero) & renderObject.size;
      if (rect.contains(globalPosition)) return file;
    }
    return null;
  }

  void _applyDragSelection(TCloudFile file) {
    if (!_dragVisited.add(_dragIdentity(file))) return;
    setState(() {
      if (_dragSelectValue) {
        _selectedFileIds.add(file.fileId);
      } else {
        _selectedFileIds.remove(file.fileId);
      }
    });
  }

  void _beginDragSelection(TCloudFile file) {
    unawaited(HapticFeedback.selectionClick());
    _dragActive = true;
    _dragVisited.clear();
    _dragSelectValue = !_selectedFileIds.contains(file.fileId);
    _applyDragSelection(file);
  }

  void _updateDragSelection(Offset globalPosition) {
    if (!_dragActive) return;
    final file = _fileAtGlobalPosition(globalPosition);
    if (file != null) _applyDragSelection(file);
  }

  void _stopDragAutoScroll() {
    _dragAutoScrollTimer?.cancel();
    _dragAutoScrollTimer = null;
    _dragAutoScrollVelocity = 0;
    _dragLastGlobalPosition = null;
  }

  void _updateDragAutoScroll(Offset globalPosition) {
    _dragLastGlobalPosition = globalPosition;
    if (!_dragActive || !_scrollController.hasClients) {
      _stopDragAutoScroll();
      return;
    }

    final viewport = MediaQuery.of(context);
    const edge = 104.0;
    final top = viewport.padding.top + kToolbarHeight + edge;
    final bottom = viewport.size.height - viewport.padding.bottom - edge;
    double velocity = 0;
    if (globalPosition.dy < top) {
      velocity = -8 - 24 * ((top - globalPosition.dy) / edge).clamp(0, 1);
    } else if (globalPosition.dy > bottom) {
      velocity = 8 + 24 * ((globalPosition.dy - bottom) / edge).clamp(0, 1);
    }
    _dragAutoScrollVelocity = velocity;

    if (velocity == 0) {
      _dragAutoScrollTimer?.cancel();
      _dragAutoScrollTimer = null;
      return;
    }

    _dragAutoScrollTimer ??= Timer.periodic(const Duration(milliseconds: 16), (
      _,
    ) {
      if (!mounted || !_dragActive || !_scrollController.hasClients) {
        _stopDragAutoScroll();
        return;
      }
      final position = _scrollController.position;
      final next = (position.pixels + _dragAutoScrollVelocity)
          .clamp(position.minScrollExtent, position.maxScrollExtent)
          .toDouble();
      if ((next - position.pixels).abs() > .25) {
        _scrollController.jumpTo(next);
        final finger = _dragLastGlobalPosition;
        if (finger != null) _updateDragSelection(finger);
      }
    });
  }

  void _endDragSelection() {
    _stopDragAutoScroll();
    _dragActive = false;
    _dragVisited.clear();
  }

  void _handleScroll() {
    if (!_hasMore || _loadingMore || !_scrollController.hasClients) return;

    final position = _scrollController.position;

    if (position.pixels >= position.maxScrollExtent - 600) {
      _loadMore();
    }
  }

  void _applyAutoView() {
    if (_autoViewApplied || _files.isEmpty) return;

    final mediaCount = _files.where((file) => file.isMedia).length;
    final mediaRatio = mediaCount / _files.length;

    final title = widget.folder.title.toLowerCase();
    final mediaNamedFolder =
        title.contains('imagem') ||
        title.contains('foto') ||
        title.contains('video') ||
        title.contains('galeria');

    if (mediaNamedFolder || mediaRatio >= .6) {
      _viewMode = _ViewMode.gallery;
    }

    _autoViewApplied = true;
  }

  Future<void> _loadInitial() async {
    setState(() {
      _loading = true;
      _refreshing = false;
      _error = null;
      _files.clear();
      _selectedFileIds.clear();
      _nextFromMessageId = 0;
      _nextFromMessageIds = const <String, int>{};
      _hasMore = false;
      _autoViewApplied = false;
    });

    final cached = await _repo.loadCachedFilePage(widget.folder);

    if (!mounted) return;

    if (cached.files.isNotEmpty) {
      setState(() {
        _files.addAll(cached.files);
        _nextFromMessageId = cached.nextFromMessageId;
        _nextFromMessageIds = cached.nextFromMessageIds;
        _hasMore = cached.hasMore;
        _loading = false;
        _refreshing = true;
        _applyAutoView();
      });
    }

    try {
      final page = await _repo.loadFilePage(widget.folder);

      if (!mounted) return;

      if (page.files.isEmpty && _files.isNotEmpty) {
        setState(() {
          _loading = false;
          _refreshing = false;
          _error = null;
        });
        return;
      }

      setState(() {
        _files
          ..clear()
          ..addAll(page.files);
        _nextFromMessageId = page.nextFromMessageId;
        _nextFromMessageIds = page.nextFromMessageIds;
        _hasMore = page.hasMore;
        _loading = false;
        _refreshing = false;
        _error = null;
        _autoViewApplied = false;
        _applyAutoView();
      });
    } catch (error) {
      if (!mounted) return;

      if (_files.isNotEmpty) {
        setState(() {
          _loading = false;
          _refreshing = false;
          _error = null;
        });

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Sem conexao. Exibindo a ultima versao salva desta pasta.',
            ),
          ),
        );
      } else {
        setState(() {
          _loading = false;
          _refreshing = false;
          _error = error.toString();
        });
      }
    }
  }

  Future<void> _loadMore() async {
    if (!_hasMore ||
        _loadingMore ||
        (_nextFromMessageId == 0 && _nextFromMessageIds.isEmpty)) {
      return;
    }

    setState(() => _loadingMore = true);

    try {
      final page = await _repo.loadFilePage(
        widget.folder,
        fromMessageId: _nextFromMessageId,
        fromMessageIds: _nextFromMessageIds,
      );

      if (!mounted) return;

      final existingIds = _files.map((file) => file.contentIdentity).toSet();

      setState(() {
        _files.addAll(
          page.files.where((file) => existingIds.add(file.contentIdentity)),
        );
        _nextFromMessageId = page.nextFromMessageId;
        _nextFromMessageIds = page.nextFromMessageIds;
        _hasMore = page.hasMore;
        _loadingMore = false;
      });
    } catch (error) {
      if (!mounted) return;

      setState(() => _loadingMore = false);

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Nao foi possivel carregar mais: $error')),
      );
    }
  }

  Future<List<TCloudFile>> _loadAllFilesForFaceGroups() async {
    final files = <String, TCloudFile>{
      for (final file in _files) file.contentIdentity: file,
    };
    var fromMessageId = _nextFromMessageId;
    var fromMessageIds = _nextFromMessageIds;
    var hasMore = _hasMore;
    final seenCursors = <String>{};

    while (hasMore) {
      if (fromMessageId == 0 && fromMessageIds.isEmpty) {
        throw StateError(
          'A pasta informou mais arquivos sem um cursor valido.',
        );
      }
      final cursorKey =
          '$fromMessageId:${fromMessageIds.entries.toList()..sort((a, b) => a.key.compareTo(b.key))}';
      if (!seenCursors.add(cursorKey)) {
        throw StateError('A pasta retornou um cursor de pagina repetido.');
      }

      final page = await _repo.loadFilePage(
        widget.folder,
        fromMessageId: fromMessageId,
        fromMessageIds: fromMessageIds,
      );
      for (final file in page.files) {
        files.putIfAbsent(file.contentIdentity, () => file);
      }

      fromMessageId = page.nextFromMessageId;
      fromMessageIds = page.nextFromMessageIds;
      hasMore = page.hasMore;
    }

    final allFiles = files.values.toList();
    if (mounted) {
      setState(() {
        _files
          ..clear()
          ..addAll(allFiles);
        _nextFromMessageId = fromMessageId;
        _nextFromMessageIds = fromMessageIds;
        _hasMore = hasMore;
      });
    }
    return allFiles;
  }

  Future<String> _ensureLocal(TCloudFile file) async {
    final path = file.localPath;

    if (file.downloaded &&
        path != null &&
        path.isNotEmpty &&
        await File(path).exists()) {
      return path;
    }

    final transfer = TCloudTransfer(
      name: file.name,
      direction: 'download',
      status: TCloudTransferStatus.running,
    );

    TransferCenter.instance.add(transfer);

    try {
      final downloadedPath = await _repo.download(file);

      transfer.status = TCloudTransferStatus.completed;
      TransferCenter.instance.changed();

      final index = _files.indexWhere((item) => item.fileId == file.fileId);

      if (index >= 0 && mounted) {
        setState(() {
          _files[index] = file.copyWith(
            localPath: downloadedPath,
            downloaded: true,
          );
        });
      }

      return downloadedPath;
    } catch (error) {
      transfer.status = TCloudTransferStatus.failed;
      transfer.error = error.toString();
      TransferCenter.instance.changed();
      rethrow;
    }
  }

  Future<void> _open(TCloudFile file) async {
    if (file.isMedia) {
      final media = _files.where((item) => item.isMedia).toList();

      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => MediaViewerScreen(file: file, files: media),
        ),
      );

      return;
    }

    try {
      final path = await _ensureLocal(file);
      await OpenFilex.open(path);
    } catch (error) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Nao foi possivel abrir ${file.name}. ${_friendlyError(error)}',
          ),
          action: SnackBarAction(label: 'Tentar', onPressed: () => _open(file)),
        ),
      );
    }
  }

  Future<void> _makeOffline(TCloudFile file) async {
    try {
      final path = await _ensureLocal(file);

      await _repo.rememberOffline(
        file.copyWith(localPath: path, downloaded: true),
      );

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${file.name} disponivel offline.')),
      );
    } catch (error) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Falha ao disponibilizar offline: $error')),
      );
    }
  }

  Future<void> _share(TCloudFile file) async {
    try {
      final path = await _ensureLocal(file);

      await TdlibService.instance.shareFile(path, mimeType: file.mimeType);
    } catch (error) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Nao foi possivel compartilhar: $error')),
      );
    }
  }

  Future<TCloudFolder?> _chooseMoveDestination() async {
    List<TCloudFolder> folders;

    try {
      folders = await _repo.discoverFolders();
    } catch (_) {
      folders = await _repo.loadCachedFolders();
    }

    folders = folders
        .where((folder) => folder.cacheKey != widget.folder.cacheKey)
        .toList();

    if (!mounted || folders.isEmpty) return null;

    return showModalBottomSheet<TCloudFolder>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        return SafeArea(
          child: SizedBox(
            height: MediaQuery.sizeOf(sheetContext).height * .58,
            child: ListView.builder(
              itemCount: folders.length,
              itemBuilder: (context, index) {
                final folder = folders[index];

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
        );
      },
    );
  }

  Future<void> _deleteSelected() async {
    final selected = _files
        .where((file) => _selectedFileIds.contains(file.fileId))
        .toList();

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
                'A exclusao tambem sera refletida no Telegram.',
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
      _clearSelection();
      await _loadInitial();
    } catch (error) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Nao foi possivel excluir: $error')),
      );
    }
  }

  Future<void> _moveSelected() async {
    final selected = _files
        .where((file) => _selectedFileIds.contains(file.fileId))
        .toList();

    if (selected.isEmpty) return;

    final destination = await _chooseMoveDestination();

    if (destination == null) return;

    try {
      await _repo.moveFiles(selected, destination);

      _clearSelection();
      await _loadInitial();
    } catch (error) {
      if (!mounted) return;

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Nao foi possivel mover: $error')));
    }
  }

  Future<void> _downloadSelected() async {
    final selected = _files
        .where((file) => _selectedFileIds.contains(file.fileId))
        .toList();

    for (final file in selected) {
      await _makeOffline(file);
    }

    if (!mounted) return;
    setState(_selectedFileIds.clear);
  }

  Future<void> _shareSelected() async {
    final selected = _files
        .where((file) => _selectedFileIds.contains(file.fileId))
        .toList();
    if (selected.isEmpty) return;

    try {
      final paths = <String>[];
      for (final file in selected) {
        paths.add(await _ensureLocal(file));
      }
      await TdlibService.instance.shareFiles(paths);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Nao foi possivel compartilhar: $error')),
      );
    }
  }

  Future<void> _shareFolder() async {
    try {
      final link = await FolderShareService.instance.create(widget.folder);
      await Clipboard.setData(ClipboardData(text: link));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Link da pasta copiado. Valido por 7 dias.'),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Nao foi possivel compartilhar a pasta: $error'),
        ),
      );
    }
  }

  Future<void> _upload() async {
    final paths = await TdlibService.instance.pickFiles();
    if (paths.isEmpty) return;

    for (final path in paths) {
      final name = path.replaceAll('\\', '/').split('/').last;

      final transfer = TCloudTransfer(
        name: name,
        direction: 'upload',
        status: TCloudTransferStatus.running,
      );

      TransferCenter.instance.add(transfer);

      try {
        await _repo.upload(folder: widget.folder, path: path);

        transfer.status = TCloudTransferStatus.completed;
      } catch (error) {
        transfer.status = TCloudTransferStatus.failed;
        transfer.error = error.toString();
      }

      TransferCenter.instance.changed();
    }

    await Future<void>.delayed(const Duration(milliseconds: 800));
    await _loadInitial();
  }

  void _toggleSelection(TCloudFile file) {
    setState(() {
      if (!_selectedFileIds.add(file.fileId)) {
        _selectedFileIds.remove(file.fileId);
      }
    });
  }

  void _clearSelection() => setState(_selectedFileIds.clear);

  void _toggleSelectAllVisible() {
    final visibleIds = _visible.map((file) => file.fileId).toSet();
    final allSelected =
        visibleIds.isNotEmpty && visibleIds.every(_selectedFileIds.contains);
    setState(() {
      if (allSelected) {
        _selectedFileIds.removeAll(visibleIds);
      } else {
        _selectedFileIds.addAll(visibleIds);
      }
    });
  }

  List<TCloudFile> get _visible {
    final query = _query.trim().toLowerCase();

    final result = _files.where((file) {
      final matchesType = switch (_mediaFilter) {
        _MediaFilter.all => true,
        _MediaFilter.images => file.isImage || file.kind == 'animacao',
        _MediaFilter.videos => file.isVideo,
      };
      return matchesType &&
          (query.isEmpty ||
              file.name.toLowerCase().contains(query) ||
              file.kind.toLowerCase().contains(query));
    }).toList();

    switch (_sortMode) {
      case _SortMode.name:
        result.sort(
          (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
        );
        break;

      case _SortMode.size:
        result.sort((a, b) => b.size.compareTo(a.size));
        break;

      case _SortMode.type:
        result.sort(
          (a, b) => a.kind.toLowerCase().compareTo(b.kind.toLowerCase()),
        );
        break;

      case _SortMode.newest:
        result.sort((a, b) {
          final date = b.createdAt.compareTo(a.createdAt);
          return date != 0 ? date : b.messageId.compareTo(a.messageId);
        });
        break;
    }

    return result;
  }

  String _kindLabel(TCloudFile file) {
    return switch (file.kind) {
      'video' => 'video',
      'audio' => 'audio',
      'animacao' => 'animacao',
      'imagem' => 'imagem',
      'documento' => 'documento',
      _ => 'arquivo',
    };
  }

  String _size(int bytes) {
    if (bytes < 1024) return '$bytes B';

    final kb = bytes / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';

    final mb = kb / 1024;
    if (mb < 1024) return '${mb.toStringAsFixed(1)} MB';

    return '${(mb / 1024).toStringAsFixed(1)} GB';
  }

  IconData _icon(TCloudFile file) {
    switch (file.kind) {
      case 'imagem':
        return Icons.image_outlined;
      case 'video':
        return Icons.movie_outlined;
      case 'audio':
        return Icons.music_note_outlined;
      case 'animacao':
        return Icons.gif_box_outlined;
      default:
        return Icons.insert_drive_file_outlined;
    }
  }

  Future<void> _showProperties(TCloudFile file) async {
    final date = file.createdAt <= 0
        ? null
        : DateTime.fromMillisecondsSinceEpoch(file.createdAt * 1000).toLocal();

    String two(int value) => value.toString().padLeft(2, '0');

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
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
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.insert_drive_file_outlined),
                  title: Text(file.mimeType ?? _kindLabel(file)),
                  subtitle: Text(_size(file.size)),
                ),
                if (date != null)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.calendar_today_outlined),
                    title: const Text('Adicionado em'),
                    subtitle: Text(
                      '${two(date.day)}/${two(date.month)}/${date.year} '
                      '${two(date.hour)}:${two(date.minute)}',
                    ),
                  ),
                if (file.isVideo && file.durationSeconds > 0)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.timer_outlined),
                    title: const Text('Duracao'),
                    subtitle: Text(
                      '${file.durationSeconds ~/ 60}:'
                      '${(file.durationSeconds % 60).toString().padLeft(2, '0')}',
                    ),
                  ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    file.downloaded ? Icons.offline_pin : Icons.cloud_outlined,
                  ),
                  title: const Text('Disponibilidade'),
                  subtitle: Text(
                    file.downloaded
                        ? 'Disponivel neste dispositivo'
                        : 'Somente na nuvem',
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _showFileMenu(TCloudFile file) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        return SafeArea(
          child: Wrap(
            children: [
              ListTile(
                leading: const Icon(Icons.info_outline),
                title: const Text('Informacoes'),
                onTap: () {
                  Navigator.pop(context);
                  _showProperties(file);
                },
              ),
              ListTile(
                leading: const Icon(Icons.open_in_new),
                title: const Text('Abrir'),
                onTap: () {
                  Navigator.pop(context);
                  _open(file);
                },
              ),
              ListTile(
                leading: const Icon(Icons.cloud_download_outlined),
                title: const Text('Baixar / Dispon\u00edvel offline'),
                onTap: () {
                  Navigator.pop(context);
                  _makeOffline(file);
                },
              ),
              ListTile(
                leading: const Icon(Icons.share_outlined),
                title: const Text('Compartilhar'),
                onTap: () {
                  Navigator.pop(context);
                  _share(file);
                },
              ),
              ListTile(
                leading: const Icon(Icons.checklist_outlined),
                title: const Text('Selecionar'),
                onTap: () {
                  Navigator.pop(context);
                  _toggleSelection(file);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _listItem(TCloudFile file) {
    final selected = _selectedFileIds.contains(file.fileId);

    return Column(
      children: [
        ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 16),
          minTileHeight: 72,
          selected: selected,
          selectedTileColor: TCloudTheme.primary.withValues(alpha: .10),
          leading: _MediaThumbnail(
            key: ValueKey<String>(
              'media:${file.chatId}:${file.messageThreadId}:${file.messageId}:${file.fileId}',
            ),
            file: file,
            repo: _repo,
            width: 50,
            height: 50,
            icon: _icon(file),
            showPlay: file.isVideo,
          ),
          title: Text(
            file.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          subtitle: Text('${_kindLabel(file)} \u2022 ${_size(file.size)}'),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                file.downloaded ? Icons.offline_pin : Icons.cloud_outlined,
                color: file.downloaded
                    ? Colors.green
                    : TCloudTheme.textSecondary,
                size: 20,
              ),
              IconButton(
                tooltip: 'Opções do arquivo ${file.name}',
                onPressed: () => _showFileMenu(file),
                icon: const Icon(Icons.more_vert_rounded),
              ),
            ],
          ),
          onLongPress: () => _toggleSelection(file),
          onTap: () {
            if (_selectionMode) {
              _toggleSelection(file);
            } else {
              _open(file);
            }
          },
        ),
        const Divider(height: 1, indent: 80),
      ],
    );
  }

  Widget _galleryItem(TCloudFile file) {
    final selected = _selectedFileIds.contains(file.fileId);

    return ClipRRect(
      borderRadius: BorderRadius.circular(7),
      child: GestureDetector(
        onLongPressStart: (_) => _beginDragSelection(file),
        onLongPressMoveUpdate: (details) {
          _updateDragAutoScroll(details.globalPosition);
          _updateDragSelection(details.globalPosition);
        },
        onLongPressEnd: (_) => _endDragSelection(),
        onLongPressCancel: _endDragSelection,
        onTap: () {
          if (_selectionMode) {
            _toggleSelection(file);
          } else {
            _open(file);
          }
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(color: TCloudTheme.surfaceSoft),
              child: _MediaThumbnail(
                key: ValueKey<String>(
                  'media:${file.chatId}:${file.messageThreadId}:${file.messageId}:${file.fileId}',
                ),
                file: file,
                repo: _repo,
                width: double.infinity,
                height: double.infinity,
                icon: _icon(file),
                showPlay: file.isVideo,
                square: true,
              ),
            ),
            if (!file.isMedia)
              Positioned(
                left: 6,
                right: 6,
                bottom: 6,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: .62),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(5),
                    child: Text(
                      file.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontSize: 10),
                    ),
                  ),
                ),
              ),
            if (selected)
              Container(color: TCloudTheme.primary.withValues(alpha: .28)),
            if (selected)
              Positioned(
                top: 6,
                right: 6,
                child: CircleAvatar(
                  radius: 12,
                  backgroundColor: TCloudTheme.primary,
                  child: Icon(Icons.check, color: Colors.white, size: 16),
                ),
              ),
            Positioned(
              top: 3,
              left: 3,
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => _showFileMenu(file),
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: .38),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.more_horiz,
                      size: 18,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final visible = _visible;
    final sourceCount = _repo.sourceCountForFolder(widget.folder);
    final imageCount = _files
        .where((file) => file.isImage || file.kind == 'animacao')
        .length;
    final videoCount = _files.where((file) => file.isVideo).length;

    return PopScope(
      canPop: !_selectionMode,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _selectionMode) _clearSelection();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: _selectionMode
              ? IconButton(
                  onPressed: _clearSelection,
                  icon: const Icon(Icons.close),
                )
              : null,
          title: _selectionMode
              ? Text('${_selectedFileIds.length} selecionado(s)')
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      widget.folder.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    if (sourceCount > 1 ||
                        widget.folder.forumTitle.trim().isNotEmpty)
                      Text(
                        sourceCount > 1
                            ? '$sourceCount pastas unificadas'
                            : widget.folder.forumTitle.trim(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: TCloudTheme.textSecondary,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                  ],
                ),
          actions: [
            if (_selectionMode) ...[
              IconButton(
                tooltip: 'Selecionar tudo',
                onPressed: _toggleSelectAllVisible,
                icon: const Icon(Icons.select_all_outlined),
              ),
              IconButton(
                tooltip: 'Compartilhar',
                onPressed: _shareSelected,
                icon: const Icon(Icons.share_outlined),
              ),
              IconButton(
                tooltip: 'Mover',
                onPressed: _moveSelected,
                icon: const Icon(Icons.drive_file_move_outlined),
              ),
              IconButton(
                tooltip: 'Excluir',
                onPressed: _deleteSelected,
                icon: const Icon(Icons.delete_outline),
              ),
              IconButton(
                tooltip: 'Disponivel offline',
                onPressed: _downloadSelected,
                icon: const Icon(Icons.offline_pin_outlined),
              ),
            ] else ...[
              if (_hasMore || _files.any((file) => file.isImage))
                IconButton(
                  tooltip: 'Agrupar por rosto',
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => FaceGroupsScreen(
                          folderTitle: widget.folder.title,
                          scanScope: widget.folder.cacheKey,
                          files: List<TCloudFile>.unmodifiable(_files),
                          loadAllFiles: _loadAllFilesForFaceGroups,
                        ),
                      ),
                    );
                  },
                  icon: const Icon(Icons.face_retouching_natural_outlined),
                ),
              IconButton(
                tooltip: 'Compartilhar pasta',
                onPressed: _shareFolder,
                icon: const Icon(Icons.folder_shared_outlined),
              ),
              PopupMenuButton<_SortMode>(
                tooltip: 'Ordenar',
                initialValue: _sortMode,
                onSelected: (mode) => setState(() => _sortMode = mode),
                itemBuilder: (_) => const [
                  PopupMenuItem(
                    value: _SortMode.newest,
                    child: Text('Mais recentes'),
                  ),
                  PopupMenuItem(value: _SortMode.name, child: Text('Nome')),
                  PopupMenuItem(value: _SortMode.size, child: Text('Tamanho')),
                  PopupMenuItem(value: _SortMode.type, child: Text('Tipo')),
                ],
                icon: const Icon(Icons.sort),
              ),
              IconButton(
                tooltip: _viewMode == _ViewMode.list ? 'Galeria' : 'Lista',
                onPressed: () {
                  setState(() {
                    _viewMode = _viewMode == _ViewMode.list
                        ? _ViewMode.gallery
                        : _ViewMode.list;
                    _autoViewApplied = true;
                  });
                },
                icon: Icon(
                  _viewMode == _ViewMode.list
                      ? Icons.grid_view_outlined
                      : Icons.view_list_outlined,
                ),
              ),
            ],
          ],
        ),
        floatingActionButton: _selectionMode
            ? null
            : FloatingActionButton.extended(
                onPressed: _upload,
                icon: const Icon(Icons.add_rounded),
                label: const Text('Adicionar arquivo'),
              ),
        body: Column(
          children: [
            if (_hasMore || imageCount > 0 || videoCount > 0)
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 2),
                child: Row(
                  children: [
                    ChoiceChip(
                      label: Text('Todos (${_files.length})'),
                      selected: _mediaFilter == _MediaFilter.all,
                      onSelected: (_) =>
                          setState(() => _mediaFilter = _MediaFilter.all),
                    ),
                    const SizedBox(width: 8),
                    ChoiceChip(
                      label: Text('Imagens ($imageCount)'),
                      selected: _mediaFilter == _MediaFilter.images,
                      onSelected: (_) =>
                          setState(() => _mediaFilter = _MediaFilter.images),
                    ),
                    const SizedBox(width: 8),
                    ChoiceChip(
                      label: Text('Vídeos ($videoCount)'),
                      selected: _mediaFilter == _MediaFilter.videos,
                      onSelected: (_) =>
                          setState(() => _mediaFilter = _MediaFilter.videos),
                    ),
                  ],
                ),
              ),
            if (_viewMode == _ViewMode.list)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
                child: TextField(
                  onChanged: (value) => setState(() => _query = value),
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search),
                    hintText: 'Pesquisar nesta pasta',
                  ),
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 5),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        onChanged: (value) => setState(() => _query = value),
                        decoration: const InputDecoration(
                          prefixIcon: Icon(Icons.search),
                          hintText: 'Pesquisar',
                          isDense: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    DecoratedBox(
                      decoration: BoxDecoration(
                        color: TCloudTheme.surface,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: TCloudTheme.border),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 12,
                        ),
                        child: Text(
                          '${visible.length}',
                          style: TextStyle(
                            color: TCloudTheme.textSecondary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            if (_viewMode == _ViewMode.list)
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 0, 18, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '${visible.length} item(ns) carregado(s)'
                    '${_hasMore ? ' \u2022 mais disponiveis' : ''}',
                    style: TextStyle(
                      color: TCloudTheme.textSecondary,
                      fontSize: 11,
                    ),
                  ),
                ),
              ),
            if (_refreshing) const LinearProgressIndicator(minHeight: 2),
            Expanded(
              child: _loading
                  ? const _FolderLoadingState()
                  : _error != null
                  ? _ErrorState(message: _error!, retry: _loadInitial)
                  : visible.isEmpty
                  ? RefreshIndicator(
                      onRefresh: _loadInitial,
                      child: ListView(
                        children: [
                          SizedBox(height: 130),
                          Icon(
                            Icons.folder_open_outlined,
                            size: 48,
                            color: TCloudTheme.textSecondary,
                          ),
                          SizedBox(height: 12),
                          Center(
                            child: Text(
                              'Nenhum arquivo nesta pasta.',
                              style: TextStyle(
                                color: TCloudTheme.textSecondary,
                              ),
                            ),
                          ),
                        ],
                      ),
                    )
                  : RefreshIndicator(
                      onRefresh: _loadInitial,
                      child: _viewMode == _ViewMode.list
                          ? ListView.separated(
                              controller: _scrollController,
                              padding: const EdgeInsets.only(bottom: 110),
                              itemCount:
                                  visible.length + (_loadingMore ? 1 : 0),
                              separatorBuilder: (_, _) =>
                                  const SizedBox.shrink(),
                              itemBuilder: (context, index) {
                                if (index >= visible.length) {
                                  return const Padding(
                                    padding: EdgeInsets.all(18),
                                    child: Center(
                                      child: CircularProgressIndicator(),
                                    ),
                                  );
                                }

                                return _listItem(visible[index]);
                              },
                            )
                          : GridView.builder(
                              controller: _scrollController,
                              padding: const EdgeInsets.fromLTRB(8, 6, 8, 110),
                              gridDelegate:
                                  const SliverGridDelegateWithMaxCrossAxisExtent(
                                    maxCrossAxisExtent: 180,
                                    crossAxisSpacing: 6,
                                    mainAxisSpacing: 6,
                                  ),
                              itemCount:
                                  visible.length + (_loadingMore ? 1 : 0),
                              itemBuilder: (context, index) {
                                if (index >= visible.length) {
                                  return const Center(
                                    child: CircularProgressIndicator(),
                                  );
                                }

                                final file = visible[index];
                                return KeyedSubtree(
                                  key: _dragTileKey(file),
                                  child: _galleryItem(file),
                                );
                              },
                            ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MediaThumbnail extends StatefulWidget {
  const _MediaThumbnail({
    super.key,
    required this.file,
    required this.repo,
    required this.width,
    required this.height,
    required this.icon,
    required this.showPlay,
    this.square = false,
  });

  final TCloudFile file;
  final TCloudRepository repo;
  final double width;
  final double height;
  final IconData icon;
  final bool showPlay;
  final bool square;

  @override
  State<_MediaThumbnail> createState() => _MediaThumbnailState();
}

class _MediaThumbnailState extends State<_MediaThumbnail> {
  final _cache = ThumbnailCacheService.instance;

  String? _path;
  int _previewRequestGeneration = 0;

  @override
  void initState() {
    super.initState();
    _path = widget.file.thumbnailLocalPath;
    _upgradePreviewForCurrentFile();
  }

  String _previewIdentity(TCloudFile file) {
    return '${file.chatId}:'
        '${file.messageThreadId}:'
        '${file.messageId}:'
        '${file.fileId}:'
        '${file.thumbnailFileId}';
  }

  @override
  void didUpdateWidget(covariant _MediaThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (_previewIdentity(oldWidget.file) != _previewIdentity(widget.file)) {
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

  @override
  Widget build(BuildContext context) {
    final path = _path;

    final canShow = path != null && path.isNotEmpty && File(path).existsSync();

    final instant = _cache.instantPreview(widget.file);

    final Widget child = canShow
        ? Image.file(
            File(path),
            key: ValueKey<String>('full:$path'),
            fit: BoxFit.cover,
            filterQuality: FilterQuality.low,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => _instantOrFallback(instant),
          )
        : _instantOrFallback(instant);

    return SizedBox(
      width: widget.width,
      height: widget.height,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(widget.square ? 0 : 10),
        child: Stack(
          fit: StackFit.expand,
          children: [
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 160),
              child: child,
            ),
            if (widget.showPlay)
              Center(
                child: Container(
                  width: widget.square ? 34 : 28,
                  height: widget.square ? 34 : 28,
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: .52),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.play_arrow_rounded,
                    color: Colors.white,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _instantOrFallback(Uint8List? instant) {
    if (instant != null && instant.isNotEmpty) {
      return Image.memory(
        instant,
        key: ValueKey<int>(widget.file.fileId),
        fit: BoxFit.cover,
        filterQuality: FilterQuality.low,
        gaplessPlayback: true,
      );
    }

    return ColoredBox(
      color: TCloudTheme.surfaceSoft,
      child: Center(
        child: Icon(
          widget.icon,
          color: TCloudTheme.primary,
          size: widget.square ? 36 : 25,
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.retry});

  final String message;
  final VoidCallback retry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_outlined, size: 44),
            const SizedBox(height: 12),
            const Text(
              'Nao foi possivel carregar.',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(color: TCloudTheme.textSecondary, fontSize: 12),
            ),
            const SizedBox(height: 18),
            FilledButton(
              onPressed: retry,
              child: const Text('Tentar novamente'),
            ),
          ],
        ),
      ),
    );
  }
}

String _friendlyError(Object error) {
  final raw = error.toString().replaceFirst(
    RegExp(r'^\w+(Error|Exception):\s*'),
    '',
  );
  final normalized = raw.toLowerCase();

  if (normalized.contains('timeout') || normalized.contains('timed out')) {
    return 'A conexao demorou demais.';
  }
  if (normalized.contains('network') || normalized.contains('socket')) {
    return 'Verifique sua conexao.';
  }
  if (normalized.contains('not found') || normalized.contains('nao existe')) {
    return 'O arquivo remoto precisa ser sincronizado novamente.';
  }
  return raw.isEmpty ? 'Tente novamente.' : raw;
}

class _FolderLoadingState extends StatelessWidget {
  const _FolderLoadingState();

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 100),
      physics: const NeverScrollableScrollPhysics(),
      itemCount: 7,
      separatorBuilder: (_, _) => const SizedBox(height: 12),
      itemBuilder: (_, index) => Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: TCloudTheme.surfaceSoft,
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                FractionallySizedBox(
                  widthFactor: index.isEven ? .72 : .56,
                  child: Container(
                    height: 12,
                    decoration: BoxDecoration(
                      color: TCloudTheme.surfaceSoft,
                      borderRadius: BorderRadius.circular(6),
                    ),
                  ),
                ),
                const SizedBox(height: 9),
                FractionallySizedBox(
                  widthFactor: .34,
                  child: Container(
                    height: 9,
                    decoration: BoxDecoration(
                      color: TCloudTheme.surfaceSoft,
                      borderRadius: BorderRadius.circular(5),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

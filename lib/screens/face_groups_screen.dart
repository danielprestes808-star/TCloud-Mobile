import 'dart:io';

import 'package:flutter/material.dart';

import '../core/tcloud_theme.dart';
import '../models/tcloud_file.dart';
import '../services/face_grouping_service.dart';
import '../services/thumbnail_cache_service.dart';
import 'media_viewer_screen.dart';

class FaceGroupsScreen extends StatefulWidget {
  const FaceGroupsScreen({
    super.key,
    required this.folderTitle,
    required this.files,
    required this.loadAllFiles,
    this.scanScope,
    this.loadLibraryOnOpen = false,
  });

  const FaceGroupsScreen.library({super.key})
    : folderTitle = 'Toda a biblioteca',
      files = const <TCloudFile>[],
      loadAllFiles = _loadAllLibraryFiles,
      scanScope = 'library',
      loadLibraryOnOpen = true;

  static Future<List<TCloudFile>> _loadAllLibraryFiles() =>
      FaceGroupingService.instance.loadAllLibraryMedia();

  final String folderTitle;
  final List<TCloudFile> files;
  final Future<List<TCloudFile>> Function() loadAllFiles;
  final String? scanScope;
  final bool loadLibraryOnOpen;

  @override
  State<FaceGroupsScreen> createState() => _FaceGroupsScreenState();
}

class _FaceGroupsScreenState extends State<FaceGroupsScreen> {
  final _service = FaceGroupingService.instance;
  late List<TCloudFile> _files = widget.files;
  List<FaceGroup> _groups = const [];
  bool _loading = true;
  bool _scanning = false;
  bool _loadingAlbum = false;
  bool _cancelRequested = false;
  bool _pauseRequested = false;
  bool _pendingScan = false;
  bool _loadedFullLibrary = false;
  String _currentPhase = 'Preparando análise';
  int _completed = 0;
  int _currentItem = 0;
  int _total = 0;
  int _localImageCount = 0;
  String? _error;

  List<TCloudFile> get _images => _files.where((file) => file.isImage).toList();
  List<TCloudFile> get _videos => _files.where((file) => file.isVideo).toList();
  String get _scanScope => widget.scanScope ?? widget.folderTitle;

  int get _downloadedMediaCount => <TCloudFile>[..._images, ..._videos]
      .where(
        (file) => file.downloaded && file.localPath?.trim().isNotEmpty == true,
      )
      .length;

  Future<void> _clearFaceData() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Apagar dados de rostos?'),
        content: const Text(
          'Os grupos, nomes e dados de reconhecimento serão removidos deste '
          'aparelho. As fotos e vídeos originais não serão apagados.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Apagar dados'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      await _service.clearAllFaceData();
      if (!mounted) return;
      setState(() {
        _groups = const [];
        _pendingScan = false;
        _error = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Dados de rostos apagados do aparelho.')),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = 'Não foi possível apagar os dados: $error');
    }
  }

  @override
  void initState() {
    super.initState();
    _loadGroups();
  }

  Future<void> _loadGroups() async {
    try {
      final files = widget.loadLibraryOnOpen && !_loadedFullLibrary
          ? await widget.loadAllFiles()
          : _files;
      final groups = await _service.groupsFor(files);
      final pendingScan = await _service.hasPendingScan(_scanScope);
      if (!mounted) return;
      setState(() {
        _files = files;
        _loadedFullLibrary = widget.loadLibraryOnOpen;
        _groups = groups;
        _pendingScan = pendingScan;
        _loading = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  String _formatBytes(int bytes) {
    if (bytes <= 0) return '0 MB';
    const units = <String>['B', 'KB', 'MB', 'GB', 'TB'];
    var value = bytes.toDouble();
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    return '${value.toStringAsFixed(value >= 10 ? 0 : 1)} ${units[unit]}';
  }

  Future<void> _analyze() async {
    setState(() {
      _scanning = true;
      _loadingAlbum = true;
      _cancelRequested = false;
      _pauseRequested = false;
      _currentPhase = 'Preparando análise';
      _completed = 0;
      _currentItem = 0;
      _total = 0;
      _error = null;
    });

    try {
      final files = widget.loadLibraryOnOpen && _loadedFullLibrary
          ? _files
          : await widget.loadAllFiles();
      if (!mounted) return;
      final media = files
          .where((file) => file.isImage || file.isVideo)
          .toList();
      final images = media.where((file) => file.isImage).length;
      final videos = media.where((file) => file.isVideo).length;
      var localMediaCount = 0;
      var cloudBytes = 0;
      for (final file in media) {
        final path = file.localPath?.trim() ?? '';
        if (path.isNotEmpty && await File(path).exists()) {
          localMediaCount++;
        } else {
          cloudBytes += file.size > 0 ? file.size : 0;
        }
      }

      if (!mounted) return;
      setState(() {
        _files = files;
        _loadedFullLibrary = widget.loadLibraryOnOpen;
        _loadingAlbum = false;
        _localImageCount = localMediaCount;
        _total = media.length;
      });

      final confirmed =
          await showDialog<bool>(
            context: context,
            builder: (dialogContext) => AlertDialog(
              icon: const Icon(Icons.face_retouching_natural_outlined),
              title: Text(
                widget.loadLibraryOnOpen
                    ? 'Analisar rostos da biblioteca?'
                    : 'Analisar rostos deste álbum?',
              ),
              content: Text(
                '$images fotos e $videos vídeos. '
                '$localMediaCount itens já estão neste aparelho; '
                '${media.length - localMediaCount} precisam ser baixados '
                'temporariamente (${_formatBytes(cloudBytes)} estimados).\n\n'
                'Nos vídeos, são analisados quadros espaçados por cerca de '
                '10 segundos, até 12 por vídeo. A análise é feita no aparelho '
                'e não envia mídia para um serviço de reconhecimento. O app '
                'remove os downloads '
                'temporários do cache ao concluir; se a limpeza falhar, '
                'avisa quais arquivos precisam de atenção. O tamanho real '
                'pode variar. Recomendamos usar Wi-Fi.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: const Text('Agora não'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(dialogContext, true),
                  child: Text(
                    media.length == localMediaCount
                        ? (_pendingScan ? 'Continuar análise' : 'Analisar')
                        : (_pendingScan
                              ? 'Baixar e continuar'
                              : 'Baixar e analisar'),
                  ),
                ),
              ],
            ),
          ) ??
          false;
      if (!confirmed || !mounted) {
        if (mounted) setState(() => _scanning = false);
        return;
      }
      if (media.isEmpty) {
        setState(() {
          _scanning = false;
          _cancelRequested = false;
          _pauseRequested = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Este álbum não contém fotos ou vídeos.'),
          ),
        );
        return;
      }

      final result = await _service.analyze(
        _files,
        scanScope: _scanScope,
        shouldCancel: () => _cancelRequested,
        shouldPause: () => _pauseRequested,
        onStatus: (phase, current, total) {
          if (!mounted) return;
          setState(() {
            _currentPhase = phase;
            _currentItem = current;
            _total = total;
          });
        },
        onProgress: (completed, total) {
          if (!mounted) return;
          setState(() {
            _completed = completed;
            _total = total;
          });
        },
      );
      if (!mounted) return;
      final pendingScan =
          result.paused || await _service.hasPendingScan(_scanScope);
      if (!mounted) return;
      setState(() {
        _groups = result.groups;
        _scanning = false;
        _loadingAlbum = false;
        _cancelRequested = false;
        _pauseRequested = false;
        _pendingScan = pendingScan;
      });
      if (result.paused) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Análise pausada. Você pode continuar depois.'),
          ),
        );
        return;
      }
      if (result.cancelled) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Análise interrompida após a imagem em andamento.'),
          ),
        );
        return;
      }
      final details = <String>[
        '${result.groups.length} grupo(s) de pessoas',
        if (result.failedFiles.isNotEmpty)
          '${result.failedFiles.length} falha(s): '
              '${result.failedFiles.take(2).join('; ')}',
        if (result.unmatchedCount > 0)
          '${result.unmatchedCount} item(ns) sem pessoa identificada',
      ];
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(details.join(' • '))));
    } catch (error) {
      if (!mounted) return;
      final pendingScan = await _service.hasPendingScan(_scanScope);
      if (!mounted) return;
      setState(() {
        _scanning = false;
        _loadingAlbum = false;
        _cancelRequested = false;
        _pauseRequested = false;
        _pendingScan = pendingScan;
        _error = 'Não foi possível analisar as imagens: $error';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Pessoas',
              style: TextStyle(fontWeight: FontWeight.w800),
            ),
            Text(
              widget.folderTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w400),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Analisar rostos',
            onPressed: _scanning ? null : _analyze,
            icon: const Icon(Icons.face_retouching_natural_outlined),
          ),
          PopupMenuButton<String>(
            tooltip: 'Privacidade',
            onSelected: (action) {
              if (action == 'delete') _clearFaceData();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'delete',
                child: Text('Apagar dados de rostos'),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: TCloudTheme.surfaceSoft,
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Padding(
                padding: EdgeInsets.all(12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.lock_outline_rounded, size: 20),
                    SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'O reconhecimento é processado localmente. Ao iniciar, '
                        'o app pede sua confirmação antes de baixar itens da '
                        'nuvem. Revise os grupos antes de compartilhar.',
                        style: TextStyle(fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (_scanning)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Column(
                children: [
                  if (_loadingAlbum)
                    const LinearProgressIndicator()
                  else
                    const LinearProgressIndicator(),
                  const SizedBox(height: 6),
                  Text(
                    _loadingAlbum
                        ? widget.loadLibraryOnOpen
                              ? 'Carregando a biblioteca'
                              : 'Carregando os itens do álbum'
                        : _pauseRequested
                        ? 'A análise será pausada após o item atual'
                        : _cancelRequested
                        ? 'A análise será interrompida após o item atual'
                        : _currentItem == 0
                        ? _currentPhase
                        : '$_currentPhase item $_currentItem de $_total '
                              '· $_completed concluída(s) · '
                              '$_localImageCount já local(is)',
                  ),
                  if (!_loadingAlbum)
                    Wrap(
                      spacing: 8,
                      children: [
                        TextButton(
                          onPressed: () => setState(() {
                            _pauseRequested = true;
                            _cancelRequested = false;
                          }),
                          child: const Text('Pausar'),
                        ),
                        TextButton(
                          onPressed: () => setState(() {
                            _cancelRequested = true;
                            _pauseRequested = false;
                          }),
                          child: const Text('Cancelar'),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _groups.isEmpty
                ? _emptyState()
                : GridView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 220,
                          childAspectRatio: .9,
                          crossAxisSpacing: 10,
                          mainAxisSpacing: 10,
                        ),
                    itemCount: _groups.length,
                    itemBuilder: (context, index) {
                      final group = _groups[index];
                      return _FaceGroupCard(
                        group: group,
                        onTap: () => _openGroup(group),
                      );
                    },
                  ),
          ),
        ],
      ),
      floatingActionButton: _scanning
          ? null
          : FloatingActionButton.extended(
              onPressed: _analyze,
              icon: const Icon(Icons.face_retouching_natural),
              label: const Text('Analisar rostos'),
            ),
    );
  }

  Widget _emptyState() {
    final mediaCount = _images.length + _videos.length;
    final downloaded = _downloadedMediaCount;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.face_retouching_natural_outlined,
              size: 52,
              color: TCloudTheme.textSecondary,
            ),
            const SizedBox(height: 14),
            const Text(
              'Ainda não há grupos de pessoas',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Text(
              mediaCount == 0
                  ? 'Este álbum ainda não contém fotos ou vídeos para analisar.'
                  : '$mediaCount foto(s) e vídeo(s) no álbum. '
                        '$downloaded já está(ão) neste aparelho.',
              textAlign: TextAlign.center,
              style: TextStyle(color: TCloudTheme.textSecondary),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openGroup(FaceGroup group) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            _FacePersonScreen(group: group, groups: _groups, service: _service),
      ),
    );
    if (mounted) await _loadGroups();
  }
}

class _FaceGroupCard extends StatelessWidget {
  const _FaceGroupCard({required this.group, required this.onTap});

  final FaceGroup group;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final firstFile = group.files.isEmpty ? null : group.files.first;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: firstFile == null
                  ? const Icon(Icons.person_outline_rounded, size: 54)
                  : _FaceMediaThumbnail(
                      file: firstFile,
                      fallback: const Icon(
                        Icons.person_outline_rounded,
                        size: 54,
                      ),
                    ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 9, 10, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    group.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  Text(
                    '${group.files.length} item(ns)',
                    style: TextStyle(
                      color: TCloudTheme.textSecondary,
                      fontSize: 12,
                    ),
                  ),
                  if (group.needsReview)
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Text(
                        'Confira este grupo',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.tertiary,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
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

class _FaceMediaThumbnail extends StatelessWidget {
  const _FaceMediaThumbnail({required this.file, required this.fallback});

  final TCloudFile file;
  final Widget fallback;

  @override
  Widget build(BuildContext context) {
    final path = file.isVideo
        ? file.thumbnailLocalPath
        : file.localPath ?? file.thumbnailLocalPath;
    if (path != null && path.isNotEmpty) {
      return Image.file(
        File(path),
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => fallback,
      );
    }
    if (!file.isVideo) return fallback;

    return FutureBuilder<String?>(
      future: ThumbnailCacheService.instance.fullPreviewPath(file),
      builder: (context, snapshot) {
        final previewPath = snapshot.data;
        if (previewPath == null || previewPath.isEmpty) return fallback;
        return Image.file(
          File(previewPath),
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => fallback,
        );
      },
    );
  }
}

class _FacePersonScreen extends StatefulWidget {
  const _FacePersonScreen({
    required this.group,
    required this.groups,
    required this.service,
  });

  final FaceGroup group;
  final List<FaceGroup> groups;
  final FaceGroupingService service;

  @override
  State<_FacePersonScreen> createState() => _FacePersonScreenState();
}

class _FacePersonScreenState extends State<_FacePersonScreen> {
  late FaceGroup _group = widget.group;
  final Set<String> _selectedFiles = <String>{};

  bool get _selectionMode => _selectedFiles.isNotEmpty;

  Future<void> _rename() async {
    final controller = TextEditingController(text: _group.name);
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Nome da pessoa'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 40,
          decoration: const InputDecoration(labelText: 'Nome'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('Salvar'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null) return;
    try {
      await widget.service.renameGroup(_group.id, name);
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Não foi possível renomear: $error')),
      );
    }
  }

  Future<void> _mergeWithAnotherGroup() async {
    final candidates = widget.groups
        .where((group) => group.id != _group.id)
        .toList();
    if (candidates.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Não há outro grupo neste álbum.')),
      );
      return;
    }

    final destination = await showModalBottomSheet<FaceGroup>(
      context: context,
      showDragHandle: true,
      useSafeArea: true,
      builder: (context) => ListView(
        shrinkWrap: true,
        children: [
          const ListTile(
            title: Text('Combinar com'),
            subtitle: Text('As fotos e o nome do outro grupo serão mantidos.'),
          ),
          ...candidates.map(
            (group) => ListTile(
              leading: const Icon(Icons.face_outlined),
              title: Text(group.name),
              subtitle: Text('${group.files.length} fotos'),
              onTap: () => Navigator.pop(context, group),
            ),
          ),
        ],
      ),
    );
    if (destination == null || !mounted) return;

    try {
      await widget.service.mergeGroups(_group.id, destination.id);
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Não foi possível combinar os grupos: $error')),
      );
    }
  }

  Future<void> _moveSelectedToPerson() async {
    final candidates = widget.groups
        .where((group) => group.id != _group.id)
        .toList();
    if (candidates.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Não há outra pessoa neste álbum.')),
      );
      return;
    }

    final destination = await showModalBottomSheet<FaceGroup>(
      context: context,
      showDragHandle: true,
      useSafeArea: true,
      builder: (context) => ListView(
        shrinkWrap: true,
        children: [
          const ListTile(
            title: Text('Mover para outra pessoa'),
            subtitle: Text('Os arquivos originais não serão alterados.'),
          ),
          ...candidates.map(
            (group) => ListTile(
              leading: const Icon(Icons.face_outlined),
              title: Text(group.name),
              subtitle: Text('${group.files.length} itens'),
              onTap: () => Navigator.pop(context, group),
            ),
          ),
        ],
      ),
    );
    if (destination == null || !mounted) return;

    try {
      await widget.service.moveFilesToGroup(
        _group.id,
        destination.id,
        _selectedFiles,
      );
      final groups = await widget.service.groupsFor(_group.files);
      if (!mounted) return;
      final updated = groups.where((group) => group.id == _group.id);
      if (updated.isEmpty) {
        Navigator.pop(context);
        return;
      }
      setState(() {
        _group = updated.first;
        _selectedFiles.clear();
      });
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Não foi possível mover os itens: $error')),
      );
    }
  }

  Future<void> _confirmReview() async {
    try {
      await widget.service.confirmGroupReviewed(_group.id);
      final groups = await widget.service.groupsFor(_group.files);
      if (!mounted) return;
      final updated = groups.where((group) => group.id == _group.id);
      if (updated.isNotEmpty) setState(() => _group = updated.first);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Não foi possível atualizar o grupo: $error')),
      );
    }
  }

  Future<void> _removeSelectedFromGroup() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Separar fotos deste grupo?'),
        content: Text(
          '${_selectedFiles.length} foto(s) deixarão de aparecer em '
          '${_group.name}. Os arquivos originais não serão apagados.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Separar fotos'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      await widget.service.removeFilesFromGroup(_group.id, _selectedFiles);
      final groups = await widget.service.groupsFor(_group.files);
      if (!mounted) return;
      final updated = groups.where((group) => group.id == _group.id);
      if (updated.isEmpty) {
        Navigator.pop(context);
        return;
      }
      setState(() {
        _group = updated.first;
        _selectedFiles.clear();
      });
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Não foi possível separar as fotos: $error')),
      );
    }
  }

  void _toggleSelection(TCloudFile file) {
    setState(() {
      if (!_selectedFiles.add(file.contentIdentity)) {
        _selectedFiles.remove(file.contentIdentity);
      }
    });
  }

  Future<void> _openPhoto(TCloudFile file) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => MediaViewerScreen(file: file, files: _group.files),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: _selectionMode
            ? IconButton(
                tooltip: 'Cancelar seleção',
                onPressed: () => setState(_selectedFiles.clear),
                icon: const Icon(Icons.close_rounded),
              )
            : null,
        title: Text(
          _selectionMode
              ? '${_selectedFiles.length} selecionado(s)'
              : _group.name,
        ),
        actions: [
          if (_selectionMode)
            IconButton(
              tooltip: 'Mover para outra pessoa',
              onPressed: _moveSelectedToPerson,
              icon: const Icon(Icons.drive_file_move_outline),
            ),
          if (!_selectionMode)
            PopupMenuButton<String>(
              tooltip: 'Ações do grupo',
              onSelected: (action) {
                if (action == 'merge') _mergeWithAnotherGroup();
                if (action == 'rename') _rename();
                if (action == 'review') _confirmReview();
              },
              itemBuilder: (_) => [
                if (_group.needsReview)
                  const PopupMenuItem(
                    value: 'review',
                    child: Text('Marcar como revisado'),
                  ),
                PopupMenuItem(
                  value: 'merge',
                  child: Text('Combinar com outra pessoa'),
                ),
                const PopupMenuItem(value: 'rename', child: Text('Renomear')),
              ],
            ),
        ],
      ),
      body: Column(
        children: [
          if (!_selectionMode)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Row(
                children: [
                  Icon(
                    Icons.touch_app_outlined,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      'Toque e segure um item para separar ou mover para '
                      'outra pessoa.',
                    ),
                  ),
                ],
              ),
            ),
          Expanded(
            child: GridView.builder(
              padding: const EdgeInsets.all(8),
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 180,
                crossAxisSpacing: 6,
                mainAxisSpacing: 6,
              ),
              itemCount: _group.files.length,
              itemBuilder: (context, index) {
                final file = _group.files[index];
                final selected = _selectedFiles.contains(file.contentIdentity);
                return Semantics(
                  button: true,
                  selected: selected,
                  label: selected
                      ? 'Item selecionado: ${file.name}'
                      : 'Item: ${file.name}',
                  child: InkWell(
                    onTap: () => _selectionMode
                        ? _toggleSelection(file)
                        : _openPhoto(file),
                    onLongPress: () => _toggleSelection(file),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        _FaceMediaThumbnail(
                          file: file,
                          fallback: const Icon(
                            Icons.image_not_supported_outlined,
                          ),
                        ),
                        if (selected)
                          ColoredBox(
                            color: Theme.of(
                              context,
                            ).colorScheme.primary.withValues(alpha: .28),
                          ),
                        Positioned(
                          top: 6,
                          right: 6,
                          child: DecoratedBox(
                            decoration: const BoxDecoration(
                              color: Colors.black54,
                              shape: BoxShape.circle,
                            ),
                            child: Padding(
                              padding: const EdgeInsets.all(3),
                              child: Icon(
                                selected
                                    ? Icons.check_circle
                                    : Icons.circle_outlined,
                                color: selected
                                    ? Theme.of(context).colorScheme.primary
                                    : Colors.white,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
      bottomNavigationBar: _selectionMode
          ? SafeArea(
              minimum: const EdgeInsets.all(12),
              child: FilledButton.icon(
                onPressed: _removeSelectedFromGroup,
                icon: const Icon(Icons.person_remove_alt_1_outlined),
                label: Text('Separar ${_selectedFiles.length} item(ns)'),
              ),
            )
          : null,
    );
  }
}

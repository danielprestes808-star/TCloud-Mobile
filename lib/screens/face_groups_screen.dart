import 'dart:io';

import 'package:flutter/material.dart';

import '../core/tcloud_theme.dart';
import '../models/tcloud_file.dart';
import '../services/face_grouping_service.dart';
import 'media_viewer_screen.dart';

class FaceGroupsScreen extends StatefulWidget {
  const FaceGroupsScreen({
    super.key,
    required this.folderTitle,
    required this.files,
    required this.loadAllFiles,
  });

  final String folderTitle;
  final List<TCloudFile> files;
  final Future<List<TCloudFile>> Function() loadAllFiles;

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
  int _completed = 0;
  int _total = 0;
  String? _error;

  List<TCloudFile> get _images => _files.where((file) => file.isImage).toList();

  int get _downloadedImageCount => _images
      .where(
        (file) => file.downloaded && file.localPath?.trim().isNotEmpty == true,
      )
      .length;

  @override
  void initState() {
    super.initState();
    _loadGroups();
  }

  Future<void> _loadGroups() async {
    try {
      final groups = await _service.groupsFor(_files);
      if (!mounted) return;
      setState(() {
        _groups = groups;
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

  Future<void> _analyze() async {
    final confirmed =
        await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('Agrupar por rosto?'),
            content: Text(
              'O TCloud vai carregar a lista completa deste álbum e analisar '
              'localmente somente imagens já baixadas. Mídias que estão apenas '
              'na nuvem não serão baixadas.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Cancelar'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('Analisar'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !mounted) return;

    setState(() {
      _scanning = true;
      _loadingAlbum = true;
      _completed = 0;
      _total = 0;
      _error = null;
    });

    try {
      final files = await widget.loadAllFiles();
      if (!mounted) return;
      setState(() {
        _files = files;
        _loadingAlbum = false;
        _total = _downloadedImageCount;
      });
      final result = await _service.analyze(
        _files,
        onProgress: (completed, total) {
          if (!mounted) return;
          setState(() {
            _completed = completed;
            _total = total;
          });
        },
      );
      if (!mounted) return;
      setState(() {
        _groups = result.groups;
        _scanning = false;
        _loadingAlbum = false;
      });
      final details = <String>[
        '${result.groups.length} grupo(s) de pessoas',
        if (result.notAvailableLocallyCount > 0)
          '${result.notAvailableLocallyCount} imagem(ns) não disponíveis no aparelho',
        if (result.unmatchedCount > 0)
          '${result.unmatchedCount} imagem(ns) sem pessoa identificada',
      ];
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(details.join(' • '))));
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _scanning = false;
        _loadingAlbum = false;
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
                        'O reconhecimento é processado localmente. '
                        'Só imagens já baixadas deste álbum são analisadas; '
                        'arquivos na nuvem não são baixados automaticamente. '
                        'Confira os grupos automáticos antes de compartilhar.',
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
                    LinearProgressIndicator(
                      value: _total == 0 ? null : _completed / _total,
                    ),
                  const SizedBox(height: 6),
                  Text(
                    _loadingAlbum
                        ? 'Carregando os itens do álbum'
                        : 'Analisando $_completed de $_total imagens',
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
    final downloaded = _downloadedImageCount;
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
              downloaded == 0
                  ? 'Baixe imagens deste álbum e inicie a análise facial.'
                  : '$downloaded imagem(ns) baixada(s) pronta(s) para análise.',
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
    final path = group.files.isEmpty ? null : group.files.first.localPath;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: path == null
                  ? const Icon(Icons.person_outline_rounded, size: 54)
                  : Image.file(
                      File(path),
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) =>
                          const Icon(Icons.person_outline_rounded, size: 54),
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
                    '${group.files.length} foto(s)',
                    style: TextStyle(
                      color: TCloudTheme.textSecondary,
                      fontSize: 12,
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
              ? '${_selectedFiles.length} selecionada(s)'
              : _group.name,
        ),
        actions: [
          if (!_selectionMode)
            PopupMenuButton<String>(
              tooltip: 'Ações do grupo',
              onSelected: (action) {
                if (action == 'merge') _mergeWithAnotherGroup();
                if (action == 'rename') _rename();
              },
              itemBuilder: (_) => const [
                PopupMenuItem(
                  value: 'merge',
                  child: Text('Combinar com outra pessoa'),
                ),
                PopupMenuItem(value: 'rename', child: Text('Renomear')),
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
                      'Mantenha uma foto pressionada para selecionar e '
                      'separá-la deste grupo.',
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
                final path = file.localPath;
                return Semantics(
                  button: true,
                  selected: selected,
                  label: selected
                      ? 'Foto selecionada: ${file.name}'
                      : 'Foto: ${file.name}',
                  child: InkWell(
                    onTap: () => _selectionMode
                        ? _toggleSelection(file)
                        : _openPhoto(file),
                    onLongPress: () => _toggleSelection(file),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        if (path == null)
                          const Icon(Icons.image_not_supported_outlined)
                        else
                          Image.file(
                            File(path),
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) =>
                                const Icon(Icons.image_not_supported_outlined),
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
                label: Text('Separar ${_selectedFiles.length} foto(s)'),
              ),
            )
          : null,
    );
  }
}

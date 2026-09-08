import 'package:flutter/material.dart';

import '../core/tcloud_theme.dart';
import '../models/tcloud_folder.dart';
import '../services/tcloud_repository.dart';
import 'folder_screen.dart';

class GalleryFoldersScreen extends StatefulWidget {
  const GalleryFoldersScreen({
    super.key,
    required this.loadFolders,
    required this.onFolderOptions,
  });

  final Future<List<TCloudFolder>> Function() loadFolders;
  final Future<void> Function(TCloudFolder folder) onFolderOptions;

  @override
  State<GalleryFoldersScreen> createState() => _GalleryFoldersScreenState();
}

class _GalleryFoldersScreenState extends State<GalleryFoldersScreen> {
  final _repo = TCloudRepository.instance;
  final _search = TextEditingController();
  List<TCloudFolder> _folders = const [];
  bool _loading = true;
  bool _grid = true;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  String _title(TCloudFolder folder) {
    final title = folder.title.trim();
    const prefix = 'Galeria / ';
    return title.toLowerCase().startsWith(prefix.toLowerCase())
        ? title.substring(prefix.length).trim()
        : title;
  }

  Future<void> _refresh() async {
    try {
      final folders = await widget.loadFolders();
      folders.sort(
        (a, b) => _title(a).toLowerCase().compareTo(_title(b).toLowerCase()),
      );
      if (!mounted) return;
      setState(() {
        _folders = folders;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _open(TCloudFolder folder) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => FolderScreen(folder: folder)),
    );
  }

  Future<void> _options(TCloudFolder folder) async {
    await widget.onFolderOptions(folder);
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final query = _query.trim().toLowerCase();
    final visible = _folders.where((folder) {
      return query.isEmpty || _title(folder).toLowerCase().contains(query);
    }).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Galeria', style: TextStyle(fontWeight: FontWeight.w800)),
            Text(
              'Pastas do dispositivo',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w400),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: _grid ? 'Mostrar em lista' : 'Mostrar em grade',
            onPressed: () => setState(() => _grid = !_grid),
            icon: Icon(
              _grid ? Icons.view_list_outlined : Icons.grid_view_outlined,
            ),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
                child: SearchBar(
                  controller: _search,
                  leading: const Icon(Icons.search_rounded),
                  hintText: 'Pesquisar pasta da galeria',
                  trailing: [
                    if (_query.isNotEmpty)
                      IconButton(
                        tooltip: 'Limpar',
                        onPressed: () {
                          _search.clear();
                          setState(() => _query = '');
                        },
                        icon: const Icon(Icons.close_rounded),
                      ),
                  ],
                  onChanged: (value) => setState(() => _query = value),
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 4, 18, 12),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Subpastas',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    Text(
                      '${visible.length}',
                      style: TextStyle(color: TCloudTheme.textSecondary),
                    ),
                  ],
                ),
              ),
            ),
            if (_loading)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: Center(child: CircularProgressIndicator()),
              )
            else if (visible.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(28),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          query.isEmpty
                              ? Icons.photo_library_outlined
                              : Icons.search_off_rounded,
                          size: 52,
                          color: TCloudTheme.textSecondary,
                        ),
                        const SizedBox(height: 14),
                        Text(
                          query.isEmpty
                              ? 'Nenhuma pasta da galeria ainda'
                              : 'Nenhuma pasta encontrada',
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          query.isEmpty
                              ? 'As pastas aparecem aqui durante o backup da galeria.'
                              : 'Tente pesquisar usando outro nome.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: TCloudTheme.textSecondary),
                        ),
                      ],
                    ),
                  ),
                ),
              )
            else if (_grid)
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 28),
                sliver: SliverGrid.builder(
                  itemCount: visible.length,
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 240,
                    childAspectRatio: 1.55,
                    crossAxisSpacing: 10,
                    mainAxisSpacing: 10,
                  ),
                  itemBuilder: (_, index) => _GalleryFolderCard(
                    title: _title(visible[index]),
                    sources: _repo.sourceCountForFolder(visible[index]),
                    onTap: () => _open(visible[index]),
                    onOptions: () => _options(visible[index]),
                  ),
                ),
              )
            else
              SliverList.builder(
                itemCount: visible.length,
                itemBuilder: (_, index) {
                  final folder = visible[index];
                  final sources = _repo.sourceCountForFolder(folder);
                  return ListTile(
                    contentPadding: const EdgeInsets.only(left: 18, right: 6),
                    leading: Icon(
                      Icons.folder_rounded,
                      color: TCloudTheme.primary,
                      size: 32,
                    ),
                    title: Text(_title(folder)),
                    subtitle: Text(
                      sources > 1
                          ? '$sources pastas unificadas'
                          : 'Álbum da galeria',
                    ),
                    trailing: IconButton(
                      tooltip: 'Mais opções',
                      onPressed: () => _options(folder),
                      icon: const Icon(Icons.more_vert_rounded),
                    ),
                    onTap: () => _open(folder),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }
}

class _GalleryFolderCard extends StatelessWidget {
  const _GalleryFolderCard({
    required this.title,
    required this.sources,
    required this.onTap,
    required this.onOptions,
  });

  final String title;
  final int sources;
  final VoidCallback onTap;
  final VoidCallback onOptions;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: onOptions,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 14, 4, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.folder_rounded,
                    color: TCloudTheme.primary,
                    size: 38,
                  ),
                  const Spacer(),
                  IconButton(
                    tooltip: 'Mais opções',
                    onPressed: onOptions,
                    icon: const Icon(Icons.more_vert_rounded),
                  ),
                ],
              ),
              const Spacer(),
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 2),
              Text(
                sources > 1 ? '$sources pastas unificadas' : 'Álbum da galeria',
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
      ),
    );
  }
}

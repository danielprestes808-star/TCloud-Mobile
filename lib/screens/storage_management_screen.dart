import 'dart:io';

import 'package:flutter/material.dart';

import '../core/tcloud_theme.dart';
import '../models/tcloud_file.dart';
import '../services/media_cache_policy.dart';
import '../services/tcloud_repository.dart';
import '../services/thumbnail_cache_service.dart';

class StorageManagementScreen extends StatefulWidget {
  const StorageManagementScreen({super.key});

  @override
  State<StorageManagementScreen> createState() =>
      _StorageManagementScreenState();
}

class _StorageManagementScreenState extends State<StorageManagementScreen> {
  final _repo = TCloudRepository.instance;
  final _thumbs = ThumbnailCacheService.instance;
  final _mediaPolicy = MediaCachePolicy.instance;

  bool _loading = true;
  bool _clearingCache = false;
  bool _clearingOffline = false;
  bool _optimizing = false;
  String? _storageError;

  int _thumbnailBytes = 0;
  int _thumbnailCount = 0;
  List<TCloudFile> _offlineFiles = <TCloudFile>[];
  int _offlineBytes = 0;

  @override
  void initState() {
    super.initState();
    _loadStorageStats();
  }

  Future<void> _loadStorageStats() async {
    setState(() => _loading = true);
    try {
      final thumbBytes = await _thumbs.cachedPreviewBytes();
      final thumbCount = await _thumbs.cachedPreviewCount();
      final offline = await _repo.loadOffline();

      var offlineBytes = 0;
      for (final f in offline) {
        if (f.localPath != null && f.localPath!.isNotEmpty) {
          try {
            final file = File(f.localPath!);
            if (await file.exists()) {
              offlineBytes += await file.length();
            }
          } catch (_) {
            offlineBytes += f.size;
          }
        } else {
          offlineBytes += f.size;
        }
      }

      if (!mounted) return;
      setState(() {
        _thumbnailBytes = thumbBytes;
        _thumbnailCount = thumbCount;
        _offlineFiles = offline;
        _offlineBytes = offlineBytes;
        _loading = false;
        _storageError = null;
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _loading = false;
          _storageError = error.toString();
        });
      }
    }
  }

  String _formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    const suffixes = ['B', 'KB', 'MB', 'GB', 'TB'];
    var i = 0;
    double count = bytes.toDouble();
    while (count >= 1024 && i < suffixes.length - 1) {
      count /= 1024;
      i++;
    }
    return '${count.toStringAsFixed(count >= 10 ? 1 : 2)} ${suffixes[i]}';
  }

  Future<void> _clearCache() async {
    if (_clearingCache) return;
    setState(() => _clearingCache = true);

    try {
      final beforeBytes = _thumbnailBytes;
      await _thumbs.clearPreviewCache();
      await _mediaPolicy.optimize(force: true);
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();

      await _loadStorageStats();

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Cache liberado: ${_formatBytes(beforeBytes)} foram recuperados.',
          ),
          backgroundColor: TCloudTheme.success,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Erro ao limpar cache: $e'),
          backgroundColor: Colors.redAccent,
        ),
      );
    } finally {
      if (mounted) setState(() => _clearingCache = false);
    }
  }

  Future<void> _optimizeDatabase() async {
    if (_optimizing) return;
    setState(() => _optimizing = true);

    try {
      await _mediaPolicy.optimize(force: true);
      await _loadStorageStats();

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text(
            'Armazenamento do Telegram/TDLib otimizado com sucesso.',
          ),
          backgroundColor: TCloudTheme.success,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Erro na otimização: $e'),
          backgroundColor: Colors.redAccent,
        ),
      );
    } finally {
      if (mounted) setState(() => _optimizing = false);
    }
  }

  Future<void> _removeOfflineFile(TCloudFile file) async {
    try {
      if (file.localPath != null && file.localPath!.isNotEmpty) {
        final localFile = File(file.localPath!);
        if (await localFile.exists()) await localFile.delete();
      }
      await _repo.removeOffline(file);
      await _loadStorageStats();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${file.name} removido do armazenamento offline.'),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Falha ao remover arquivo: $e')));
    }
  }

  Future<void> _clearAllOffline() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remover todos os arquivos offline?'),
        content: const Text(
          'Os arquivos locais baixados serão excluídos do aparelho para liberar espaço. Eles continuarão seguros na nuvem TCloud/Telegram.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            child: const Text('Excluir cópias locais'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    if (_clearingOffline) return;
    setState(() => _clearingOffline = true);
    var removed = 0;
    final failures = <String>[];
    for (final file in List<TCloudFile>.from(_offlineFiles)) {
      try {
        if (file.localPath != null && file.localPath!.isNotEmpty) {
          final f = File(file.localPath!);
          if (await f.exists()) await f.delete();
        }
        await _repo.removeOffline(file);
        removed++;
      } catch (error) {
        failures.add('${file.name}: $error');
      }
    }

    await _loadStorageStats();

    if (!mounted) return;
    setState(() => _clearingOffline = false);
    if (failures.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('$removed arquivo(s) removido(s) do aparelho.'),
          backgroundColor: TCloudTheme.success,
        ),
      );
      return;
    }

    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Alguns arquivos não foram removidos'),
        content: SingleChildScrollView(
          child: Text(
            '$removed removido(s); ${failures.length} falharam. '
            'Os itens com falha permanecem na lista offline.\n\n'
            '${failures.join('\n')}',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Fechar'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final totalUsed = _thumbnailBytes + _offlineBytes;

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Armazenamento e Cache',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Atualizar estatísticas',
            onPressed: _loading ? null : _loadStorageStats,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
              children: [
                if (_storageError != null)
                  Card(
                    color: Theme.of(context).colorScheme.errorContainer,
                    child: ListTile(
                      leading: Icon(
                        Icons.error_outline,
                        color: Theme.of(context).colorScheme.onErrorContainer,
                      ),
                      title: Text(
                        'Não foi possível carregar todos os dados.',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onErrorContainer,
                        ),
                      ),
                      subtitle: Text(
                        _storageError!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onErrorContainer,
                        ),
                      ),
                      trailing: IconButton(
                        tooltip: 'Tentar novamente',
                        onPressed: _loadStorageStats,
                        icon: const Icon(Icons.refresh_rounded),
                      ),
                    ),
                  ),
                // Card de Resumo de Uso
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: TCloudTheme.surface,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: TCloudTheme.border),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: TCloudTheme.primary.withValues(
                                alpha: 0.15,
                              ),
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: Icon(
                              Icons.pie_chart_rounded,
                              color: TCloudTheme.primary,
                              size: 28,
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Espaço em uso pelo TCloud',
                                  style: TextStyle(
                                    color: TCloudTheme.textSecondary,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  _formatBytes(totalUsed),
                                  style: const TextStyle(
                                    fontSize: 26,
                                    fontWeight: FontWeight.w900,
                                    letterSpacing: -0.5,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 18),
                      // Barra de progresso segmentada
                      ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: SizedBox(
                          height: 8,
                          child: totalUsed == 0
                              ? Container(color: TCloudTheme.surfaceSoft)
                              : Row(
                                  children: [
                                    if (_offlineBytes > 0)
                                      Expanded(
                                        flex: _offlineBytes,
                                        child: Container(
                                          color: TCloudTheme.primary,
                                        ),
                                      ),
                                    if (_thumbnailBytes > 0)
                                      Expanded(
                                        flex: _thumbnailBytes,
                                        child: Container(
                                          color: Colors.amberAccent,
                                        ),
                                      ),
                                  ],
                                ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      // Legenda
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          _LegendItem(
                            color: TCloudTheme.primary,
                            title: 'Arquivos offline',
                            value: _formatBytes(_offlineBytes),
                          ),
                          _LegendItem(
                            color: Colors.amberAccent,
                            title: 'Miniaturas e cache',
                            value: _formatBytes(_thumbnailBytes),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),

                // Seção de Ações Rápidas
                const Text(
                  'AÇÕES DE LIMPEZA',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.1,
                    color: Colors.grey,
                  ),
                ),
                const SizedBox(height: 8),

                Container(
                  decoration: BoxDecoration(
                    color: TCloudTheme.surface,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: TCloudTheme.border),
                  ),
                  child: Column(
                    children: [
                      ListTile(
                        leading: Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: Colors.amber.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Icon(
                            Icons.cleaning_services_rounded,
                            color: Colors.amber,
                          ),
                        ),
                        title: const Text(
                          'Limpar cache de miniaturas',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                        subtitle: Text(
                          '$_thumbnailCount prévias salvas (${_formatBytes(_thumbnailBytes)})',
                        ),
                        trailing: _clearingCache
                            ? const SizedBox.square(
                                dimension: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : FilledButton.tonal(
                                onPressed: _clearCache,
                                child: const Text('Limpar'),
                              ),
                      ),
                      const Divider(height: 1),
                      ListTile(
                        leading: Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: TCloudTheme.primary.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Icon(
                            Icons.auto_awesome_rounded,
                            color: TCloudTheme.primary,
                          ),
                        ),
                        title: const Text(
                          'Otimizar armazenamento local',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                        subtitle: const Text(
                          'Remove temporários antigos do motor de download TDLib',
                        ),
                        trailing: _optimizing
                            ? const SizedBox.square(
                                dimension: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : OutlinedButton(
                                onPressed: _optimizeDatabase,
                                child: const Text('Otimizar'),
                              ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),

                // Seção de Arquivos Offline
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'ARQUIVOS SALVOS NO DISPOSITIVO',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.1,
                        color: Colors.grey,
                      ),
                    ),
                    if (_offlineFiles.isNotEmpty)
                      TextButton(
                        onPressed: _clearingOffline ? null : _clearAllOffline,
                        child: Text(
                          _clearingOffline ? 'Removendo...' : 'Remover todos',
                          style: const TextStyle(
                            color: Colors.redAccent,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 8),

                if (_offlineFiles.isEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      vertical: 36,
                      horizontal: 20,
                    ),
                    decoration: BoxDecoration(
                      color: TCloudTheme.surface,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: TCloudTheme.border),
                    ),
                    child: Column(
                      children: [
                        Icon(
                          Icons.cloud_done_outlined,
                          size: 44,
                          color: TCloudTheme.textSecondary,
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          'Nenhum arquivo offline no momento',
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 15,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Arquivos marcados como offline estarão disponíveis mesmo sem conexão de rede.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 13,
                            color: TCloudTheme.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  )
                else
                  Container(
                    decoration: BoxDecoration(
                      color: TCloudTheme.surface,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: TCloudTheme.border),
                    ),
                    child: ListView.separated(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: _offlineFiles.length,
                      separatorBuilder: (context, index) =>
                          const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final file = _offlineFiles[index];
                        return ListTile(
                          leading: Icon(
                            file.isVideo
                                ? Icons.videocam_rounded
                                : file.isImage
                                ? Icons.image_rounded
                                : (file.kind == 'audio'
                                      ? Icons.audiotrack_rounded
                                      : Icons.insert_drive_file_rounded),
                            color: TCloudTheme.primary,
                          ),
                          title: Text(
                            file.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          subtitle: Text(
                            '${_formatBytes(file.size)} • ${file.kind.toUpperCase()}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: TCloudTheme.textSecondary,
                            ),
                          ),
                          trailing: IconButton(
                            icon: const Icon(
                              Icons.delete_outline_rounded,
                              color: Colors.redAccent,
                            ),
                            tooltip: 'Remover cópia local',
                            onPressed: () => _removeOfflineFile(file),
                          ),
                        );
                      },
                    ),
                  ),
              ],
            ),
    );
  }
}

class _LegendItem extends StatelessWidget {
  const _LegendItem({
    required this.color,
    required this.title,
    required this.value,
  });

  final Color color;
  final String title;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 8),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: TextStyle(fontSize: 11, color: TCloudTheme.textSecondary),
            ),
            Text(
              value,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
            ),
          ],
        ),
      ],
    );
  }
}

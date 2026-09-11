import 'dart:async';

import 'package:flutter/material.dart';

import '../core/tcloud_theme.dart';
import '../services/gallery_sync_service.dart';

class SyncQueueScreen extends StatefulWidget {
  const SyncQueueScreen({super.key});

  @override
  State<SyncQueueScreen> createState() => _SyncQueueScreenState();
}

class _SyncQueueScreenState extends State<SyncQueueScreen> {
  final _sync = GallerySyncService.instance;
  Timer? _timer;
  Map<String, dynamic> _snapshot = const <String, dynamic>{};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final next = await _sync.syncActivitySnapshot();
      if (!mounted) return;
      setState(() {
        _snapshot = next;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  int _asInt(dynamic value) {
    if (value is int) return value;
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  @override
  Widget build(BuildContext context) {
    final total = _asInt(_snapshot['total']);
    final uploaded = _asInt(_snapshot['uploaded']);
    final failed = _asInt(_snapshot['failed']);
    final pending = _asInt(_snapshot['pendingNative']);
    final running = _snapshot['running'] == true;
    final stalled = _snapshot['stalled'] == true;
    final filesPerMinute =
        (_snapshot['filesPerMinute'] as num?)?.toDouble() ?? 0;
    final etaSeconds = _asInt(_snapshot['etaSeconds']);

    final done = uploaded + failed;
    final progress = total > 0 ? (done / total).clamp(0.0, 1.0) : null;

    final rawItems = (_snapshot['items'] as List?) ?? const <dynamic>[];
    final items = rawItems.whereType<Map>().map((raw) {
      return raw.map((key, value) => MapEntry(key.toString(), value));
    }).toList();

    return Scaffold(
      appBar: AppBar(title: const Text('Sincronizacao')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _refresh,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 28),
                children: [
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: TCloudTheme.surface,
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: TCloudTheme.border),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          stalled
                              ? 'Sincronização demorando mais que o normal'
                              : running
                              ? 'Sincronizando agora'
                              : pending > 0
                              ? 'Arquivos aguardando'
                              : 'Tudo em dia',
                          style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 14),
                        LinearProgressIndicator(value: progress),
                        const SizedBox(height: 10),
                        Text(
                          total > 0
                              ? '$uploaded de $total enviados'
                              : '$pending arquivo(s) na fila de segundo plano',
                          style: TextStyle(color: TCloudTheme.textSecondary),
                        ),
                        if (failed > 0)
                          Text(
                            '$failed com falha; nova tentativa sera feita.',
                            style: TextStyle(color: TCloudTheme.textSecondary),
                          ),
                        if (running && filesPerMinute > 0) ...[
                          const SizedBox(height: 4),
                          Text(
                            '${filesPerMinute.toStringAsFixed(1)} arquivo(s)/min'
                            '${etaSeconds > 0 ? ' · cerca de ${(etaSeconds / 60).ceil()} min restantes' : ''}',
                            style: TextStyle(color: TCloudTheme.textSecondary),
                          ),
                        ],
                        if (stalled) ...[
                          const SizedBox(height: 10),
                          const Text(
                            'O item atual será preservado na fila e retomado automaticamente sem recomeçar os concluídos.',
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 18),
                  Text(
                    'ARQUIVOS',
                    style: TextStyle(
                      color: TCloudTheme.textSecondary,
                      fontWeight: FontWeight.w800,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (items.isEmpty)
                    const ListTile(
                      leading: Icon(Icons.cloud_done_outlined),
                      title: Text('Nenhum arquivo aguardando'),
                    )
                  else
                    ...items.map((item) {
                      final name = item['name']?.toString() ?? 'Arquivo';
                      final album = item['album']?.toString() ?? '';
                      final state = item['state']?.toString() ?? 'na fila';

                      return Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: ListTile(
                          leading: Icon(
                            state == 'concluido'
                                ? Icons.check_circle_outline
                                : state == 'erro'
                                ? Icons.error_outline
                                : state == 'enviando'
                                ? Icons.cloud_upload_outlined
                                : Icons.schedule_outlined,
                          ),
                          title: Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            album.isEmpty ? state : '$album · $state',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: state == 'enviando'
                              ? const SizedBox(
                                  width: 22,
                                  height: 22,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : null,
                        ),
                      );
                    }),
                ],
              ),
            ),
    );
  }
}

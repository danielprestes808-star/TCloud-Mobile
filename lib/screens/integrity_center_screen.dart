import 'dart:io';

import 'package:flutter/material.dart';

import '../core/tcloud_theme.dart';
import '../models/tcloud_file.dart';
import '../models/tcloud_folder.dart';
import '../services/tcloud_repository.dart';

class IntegrityCenterScreen extends StatefulWidget {
  const IntegrityCenterScreen({
    super.key,
    required this.files,
    required this.folders,
  });

  final List<TCloudFile> files;
  final List<TCloudFolder> folders;

  @override
  State<IntegrityCenterScreen> createState() => _IntegrityCenterScreenState();
}

class _IntegrityCenterScreenState extends State<IntegrityCenterScreen> {
  final _repo = TCloudRepository.instance;
  bool _running = false;
  int _checked = 0;
  int _repaired = 0;
  int _unavailable = 0;
  int _duplicateReferences = 0;
  String? _message;

  @override
  void initState() {
    super.initState();
    _inspectLocal();
  }

  void _inspectLocal() {
    final identities = <String, int>{};
    var unavailable = 0;
    for (final file in widget.files) {
      identities.update(
        file.contentIdentity,
        (value) => value + 1,
        ifAbsent: () => 1,
      );
      final local = file.localPath?.trim() ?? '';
      if (file.messageId <= 0 ||
          file.fileId <= 0 ||
          (file.downloaded && (local.isEmpty || !File(local).existsSync()))) {
        unavailable++;
      }
    }
    if (!mounted) return;
    setState(() {
      _checked = widget.files.length;
      _unavailable = unavailable;
      _duplicateReferences = identities.values
          .where((count) => count > 1)
          .length;
    });
  }

  Future<void> _repair() async {
    if (_running) return;
    setState(() {
      _running = true;
      _message = null;
      _repaired = 0;
    });

    var repaired = 0;
    var unavailable = 0;
    try {
      await _repo.discoverFolders();
      final candidates = widget.files
          .where((file) {
            final local = file.localPath?.trim() ?? '';
            return file.messageId <= 0 ||
                file.fileId <= 0 ||
                (file.downloaded &&
                    (local.isEmpty || !File(local).existsSync()));
          })
          .take(80);

      for (final file in candidates) {
        try {
          final refreshed = await _repo.refreshCurrentMedia(file);
          if (refreshed.messageId > 0 && refreshed.fileId > 0) {
            repaired++;
          } else {
            unavailable++;
          }
        } catch (_) {
          unavailable++;
        }
      }
      if (!mounted) return;
      setState(() {
        _repaired = repaired;
        _unavailable = unavailable;
        _message = unavailable == 0
            ? 'Verificação concluída. A biblioteca está consistente.'
            : '$unavailable arquivo(s) continuam indisponíveis e serão tentados novamente quando o Telegram atualizar os dados.';
      });
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Integridade',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
        children: [
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: TCloudTheme.surface,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: TCloudTheme.border),
            ),
            child: Column(
              children: [
                Icon(
                  _unavailable == 0
                      ? Icons.verified_outlined
                      : Icons.health_and_safety_outlined,
                  size: 48,
                  color: _unavailable == 0
                      ? TCloudTheme.success
                      : TCloudTheme.primary,
                ),
                const SizedBox(height: 10),
                Text(
                  _unavailable == 0
                      ? 'Biblioteca saudável'
                      : 'Itens precisam de verificação',
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'O TCloud confere IDs, referências duplicadas, arquivos locais e pastas unificadas.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: TCloudTheme.textSecondary),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          _Metric(
            icon: Icons.insert_drive_file_outlined,
            title: 'Arquivos verificados',
            value: '$_checked',
          ),
          _Metric(
            icon: Icons.folder_copy_outlined,
            title: 'Pastas lógicas',
            value: '${widget.folders.length}',
          ),
          _Metric(
            icon: Icons.link_off_rounded,
            title: 'Referências indisponíveis',
            value: '$_unavailable',
          ),
          _Metric(
            icon: Icons.content_copy_outlined,
            title: 'Conteúdos repetidos unificados',
            value: '$_duplicateReferences',
          ),
          if (_repaired > 0)
            _Metric(
              icon: Icons.build_circle_outlined,
              title: 'Reparados nesta execução',
              value: '$_repaired',
            ),
          if (_message != null) ...[
            const SizedBox(height: 12),
            Text(_message!, textAlign: TextAlign.center),
          ],
          const SizedBox(height: 22),
          FilledButton.icon(
            onPressed: _running ? null : _repair,
            icon: _running
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.auto_fix_high_rounded),
            label: Text(_running ? 'Verificando...' : 'Verificar e reparar'),
          ),
        ],
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.icon, required this.title, required this.value});
  final IconData icon;
  final String title;
  final String value;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: TCloudTheme.primary),
      title: Text(title),
      trailing: Text(
        value,
        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/app_update_service.dart';

class UpdateScreen extends StatefulWidget {
  const UpdateScreen({super.key});

  @override
  State<UpdateScreen> createState() => _UpdateScreenState();
}

class _UpdateScreenState extends State<UpdateScreen> {
  final _updates = TCloudAppUpdateService.instance;

  TCloudAppInfo? _app;
  TCloudUpdateInfo? _update;
  String? _downloadedPath;
  String? _error;

  bool _checking = true;
  bool _downloading = false;
  double _progress = 0;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    if (mounted) {
      setState(() {
        _checking = true;
        _error = null;
      });
    }

    try {
      final app = await _updates.currentAppInfo();
      final update = await _updates.check();

      if (!mounted) return;

      setState(() {
        _app = app;
        _update = update;
        _checking = false;
      });
    } catch (error) {
      if (!mounted) return;

      setState(() {
        _checking = false;
        _error = _friendlyError(error);
      });
    }
  }

  String _friendlyError(Object error) {
    if (error is PlatformException) {
      return error.message ?? error.code;
    }

    return error.toString().replaceFirst(
      RegExp(r'^[A-Za-z]+Exception:\s*'),
      '',
    );
  }

  Future<void> _download() async {
    final update = _update;

    if (update == null || _downloading) return;

    setState(() {
      _downloading = true;
      _progress = 0;
      _error = null;
    });

    try {
      final path = await _updates.download(
        update,
        onProgress: (progress) {
          if (!mounted) return;

          setState(() {
            _progress = progress;
          });
        },
      );

      if (!mounted) return;

      setState(() {
        _downloadedPath = path;
        _downloading = false;
        _progress = 1;
      });

      await _install();
    } catch (error) {
      if (!mounted) return;

      setState(() {
        _downloading = false;
        _error = _friendlyError(error);
      });
    }
  }

  Future<void> _install() async {
    final path = _downloadedPath;

    if (path == null || path.isEmpty) return;

    try {
      final allowed = await _updates.canInstallPackages();

      if (!allowed) {
        if (!mounted) return;

        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Permitir atualizacoes do TCloud'),
            content: const Text(
              'O Android precisa autorizar o TCloud a '
              'abrir o instalador de atualizacoes. '
              'Ative "Permitir desta fonte" e volte ao app.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Cancelar'),
              ),
              FilledButton(
                onPressed: () async {
                  Navigator.of(context).pop();
                  await _updates.openInstallPermission();
                },
                child: const Text('Abrir configuracao'),
              ),
            ],
          ),
        );

        return;
      }

      await _updates.install(path);
    } catch (error) {
      if (!mounted) return;

      setState(() {
        _error = _friendlyError(error);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = _app;
    final update = _update;

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Atualizacoes',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
      body: RefreshIndicator(
        onRefresh: _check,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Row(
                  children: [
                    const CircleAvatar(child: Icon(Icons.system_update_alt)),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'TCloud Mobile',
                            style: TextStyle(fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            app == null
                                ? 'Lendo versao instalada...'
                                : 'Versao instalada: '
                                      '${app.version} '
                                      '(${app.versionCode})',
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            if (_checking)
              const Padding(
                padding: EdgeInsets.all(28),
                child: Column(
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 14),
                    Text('Verificando atualizacoes...'),
                  ],
                ),
              )
            else if (_error != null)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    children: [
                      const Icon(Icons.error_outline, size: 38),
                      const SizedBox(height: 10),
                      Text(_error!, textAlign: TextAlign.center),
                      const SizedBox(height: 14),
                      FilledButton.icon(
                        onPressed: _check,
                        icon: const Icon(Icons.refresh),
                        label: const Text('Tentar novamente'),
                      ),
                    ],
                  ),
                ),
              )
            else if (update == null)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(22),
                  child: Column(
                    children: [
                      const Icon(Icons.check_circle_outline, size: 44),
                      const SizedBox(height: 12),
                      const Text(
                        'Voce esta atualizado',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 17,
                        ),
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        'Nenhuma versao mais nova foi publicada.',
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 14),
                      OutlinedButton.icon(
                        onPressed: _check,
                        icon: const Icon(Icons.refresh),
                        label: const Text('Verificar novamente'),
                      ),
                    ],
                  ),
                ),
              )
            else
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.new_releases_outlined, size: 30),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              'Nova versao ${update.version}',
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                                fontSize: 18,
                              ),
                            ),
                          ),
                        ],
                      ),
                      if (update.notes.isNotEmpty) ...[
                        const SizedBox(height: 14),
                        Text(update.notes),
                      ],
                      const SizedBox(height: 18),
                      if (_downloading) ...[
                        LinearProgressIndicator(
                          value: _progress > 0 ? _progress : null,
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'O progresso tambem aparece na barra de notificacoes.',
                          style: TextStyle(fontSize: 12),
                        ),

                        const SizedBox(height: 8),
                        Text(
                          _progress > 0
                              ? 'Baixando '
                                    '${(_progress * 100).round()}%'
                              : 'Iniciando download...',
                          textAlign: TextAlign.center,
                        ),
                      ] else if (_downloadedPath != null)
                        FilledButton.icon(
                          onPressed: _install,
                          icon: const Icon(Icons.install_mobile_outlined),
                          label: const Text('Instalar atualizacao'),
                        )
                      else
                        FilledButton.icon(
                          onPressed: _download,
                          icon: const Icon(Icons.download_outlined),
                          label: const Text('Atualizar agora'),
                        ),
                      const SizedBox(height: 8),
                      const Text(
                        'O APK e verificado por SHA-256 '
                        'antes de abrir o instalador.',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

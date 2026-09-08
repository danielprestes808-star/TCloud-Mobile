import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'tcloud_device_auth.dart';

enum TCloudSharedSyncState {
  online,
  offline,
  syncing,
  uploading,
  downloading,
  attention,
  paused,
}

class TCloudFoundation5Capabilities {
  const TCloudFoundation5Capabilities({
    required this.foundation,
    required this.apiVersion,
    required this.coreVersion,
    required this.forumManagement,
    required this.folderManagement,
    required this.telegramDelta,
    required this.credentialBridge,
  });

  final String foundation;
  final String apiVersion;
  final String coreVersion;
  final bool forumManagement;
  final bool folderManagement;
  final bool telegramDelta;
  final bool credentialBridge;

  factory TCloudFoundation5Capabilities.fromJson(Map<String, dynamic> json) {
    return TCloudFoundation5Capabilities(
      foundation: '${json['foundation'] ?? ''}',
      apiVersion: '${json['apiVersion'] ?? 'v1'}',
      coreVersion: '${json['coreVersion'] ?? ''}',
      forumManagement: json['forumManagement'] == true,
      folderManagement: json['folderManagement'] == true,
      telegramDelta: json['telegramDelta'] == true,
      credentialBridge: json['credentialBridge'] == true,
    );
  }
}

class TCloudFoundation5State {
  const TCloudFoundation5State({
    required this.enabled,
    required this.connected,
    required this.checkedAt,
    required this.capabilities,
    required this.error,
  });

  final bool enabled;
  final bool connected;
  final DateTime? checkedAt;
  final TCloudFoundation5Capabilities? capabilities;
  final String? error;

  TCloudFoundation5State copyWith({
    bool? enabled,
    bool? connected,
    DateTime? checkedAt,
    TCloudFoundation5Capabilities? capabilities,
    String? error,
  }) {
    return TCloudFoundation5State(
      enabled: enabled ?? this.enabled,
      connected: connected ?? this.connected,
      checkedAt: checkedAt ?? this.checkedAt,
      capabilities: capabilities ?? this.capabilities,
      error: error,
    );
  }
}

class TCloudFoundation5Bridge extends ChangeNotifier
    with WidgetsBindingObserver {
  static const String globalIdentityCoreUrl = String.fromEnvironment(
    'TCLOUD_CORE_URL',
    defaultValue: 'https://tcloud-core.onrender.com',
  );

  TCloudFoundation5Bridge._();

  static final TCloudFoundation5Bridge instance = TCloudFoundation5Bridge._();

  static const String coreUrl = String.fromEnvironment(
    'TCLOUD_CORE_URL',
    defaultValue: 'https://tcloud-core.onrender.com',
  );

  static const Duration foregroundRefresh = Duration(seconds: 15);

  static const Duration backgroundRefresh = Duration(seconds: 45);

  Timer? _timer;
  bool _started = false;
  bool _requesting = false;

  TCloudFoundation5State _state = const TCloudFoundation5State(
    enabled: false,
    connected: false,
    checkedAt: null,
    capabilities: null,
    error: null,
  );

  TCloudFoundation5State get state => _state;

  bool get enabled => coreUrl.trim().isNotEmpty;

  Future<void> start() async {
    if (_started) return;

    _started = true;
    WidgetsBinding.instance.addObserver(this);

    _state = _state.copyWith(enabled: enabled, connected: false, error: null);
    notifyListeners();

    if (!enabled) {
      debugPrint(
        'TCloud Foundation 5 bridge: endpoint opcional nao configurado; TDLib nativo permanece principal.',
      );
      return;
    }

    await refresh();
    _schedule();
  }

  Future<void> refresh() async {
    if (!enabled || _requesting) return;

    _requesting = true;

    try {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 4);

      try {
        final request = await client.getUrl(
          Uri.parse('$coreUrl/api/v1/platform/capabilities'),
        );

        request.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
        await TCloudDeviceAuth.instance.authorize(request);

        final response = await request.close().timeout(
          const Duration(seconds: 5),
        );

        final body = await response.transform(utf8.decoder).join();

        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw HttpException('Core HTTP ${response.statusCode}');
        }

        final json = jsonDecode(body);
        if (json is! Map<String, dynamic>) {
          throw const FormatException('Capabilities invalidas.');
        }

        final capabilities = TCloudFoundation5Capabilities.fromJson(json);

        if (capabilities.foundation != '5.0') {
          throw StateError(
            'Foundation inesperada: '
            '${capabilities.foundation}',
          );
        }

        _state = TCloudFoundation5State(
          enabled: true,
          connected: true,
          checkedAt: DateTime.now(),
          capabilities: capabilities,
          error: null,
        );
      } finally {
        client.close(force: true);
      }
    } catch (error) {
      _state = TCloudFoundation5State(
        enabled: true,
        connected: false,
        checkedAt: DateTime.now(),
        capabilities: _state.capabilities,
        error: '$error',
      );
    } finally {
      _requesting = false;
      notifyListeners();
    }
  }

  void mutationCompleted() {
    if (!enabled) return;
    unawaited(refresh());
  }

  void _schedule() {
    if (!enabled) return;

    _timer?.cancel();

    final lifecycle = WidgetsBinding.instance.lifecycleState;

    final delay = lifecycle == AppLifecycleState.resumed
        ? foregroundRefresh
        : backgroundRefresh;

    _timer = Timer(delay, () async {
      await refresh();
      _schedule();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!enabled) return;

    if (state == AppLifecycleState.resumed) {
      unawaited(refresh());
    }

    _schedule();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    super.dispose();
  }
}

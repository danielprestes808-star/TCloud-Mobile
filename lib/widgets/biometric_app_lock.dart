import 'dart:async';

import 'package:flutter/material.dart';

import '../services/biometric_lock_service.dart';

class BiometricAppLock extends StatefulWidget {
  const BiometricAppLock({required this.child, super.key});

  final Widget child;

  @override
  State<BiometricAppLock> createState() => _BiometricAppLockState();
}

class _BiometricAppLockState extends State<BiometricAppLock>
    with WidgetsBindingObserver {
  bool _checking = true;
  bool _locked = false;
  bool _authenticating = false;
  DateTime? _backgroundedAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_initialize());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _initialize() async {
    final enabled = await BiometricLockService.instance.isEnabled();
    if (!mounted) return;
    setState(() {
      _checking = false;
      _locked = enabled;
    });
    if (enabled) await _unlock();
  }

  Future<void> _unlock() async {
    if (_authenticating || !_locked) return;
    setState(() => _authenticating = true);
    final authenticated = await BiometricLockService.instance.authenticate();
    if (!mounted) return;
    setState(() {
      _authenticating = false;
      if (authenticated) _locked = false;
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused && !_authenticating) {
      _backgroundedAt = DateTime.now();
      return;
    }
    if (state != AppLifecycleState.resumed || _authenticating) return;
    final backgroundedAt = _backgroundedAt;
    _backgroundedAt = null;
    if (backgroundedAt == null) {
      return;
    }
    unawaited(() async {
      final service = BiometricLockService.instance;
      if (!await service.isEnabled() || !mounted) return;
      final timeout = await service.timeoutSeconds();
      if (DateTime.now().difference(backgroundedAt) <
          Duration(seconds: timeout)) {
        return;
      }
      if (!mounted) return;
      setState(() => _locked = true);
      await _unlock();
    }());
  }

  @override
  Widget build(BuildContext context) {
    if (_checking) {
      return const ColoredBox(
        color: Color(0xFF0B0D12),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (!_locked) return widget.child;
    return ColoredBox(
      color: const Color(0xFF0B0D12),
      child: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.fingerprint_rounded,
                  color: Colors.white,
                  size: 72,
                ),
                const SizedBox(height: 20),
                const Text(
                  'TCloud bloqueado',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Use sua biometria para acessar seus arquivos.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Color(0xFFB9C0CC)),
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: _authenticating ? null : _unlock,
                  icon: _authenticating
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.lock_open_rounded),
                  label: const Text('Desbloquear'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

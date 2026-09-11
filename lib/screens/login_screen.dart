import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/tcloud_theme.dart';
import '../telegram/tdlib_service.dart';
import '../telegram/telegram_config.dart';
import '../services/account_service.dart';
import '../services/tcloud_device_auth.dart';
import 'preview_home_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final TdlibService _tdlib = TdlibService.instance;

  final TextEditingController _phoneController = TextEditingController(
    text: '+55 ',
  );
  final TextEditingController _codeController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _usernameController = TextEditingController();

  StreamSubscription<TdlibEvent>? _subscription;

  TdlibAuthorizationStage _stage = TdlibAuthorizationStage.initializing;

  bool _busy = true;
  bool _passwordVisible = false;
  bool _openedHome = false;
  int _lastCodeLength = 0;
  bool _autoCodeQueued = false;
  bool? _profileReady;

  String? _error;

  @override
  void initState() {
    super.initState();

    _subscription = _tdlib.events.listen(
      _handleTdlibEvent,
      onError: (Object error) {
        if (!mounted) return;

        setState(() {
          _busy = false;
          _error = error.toString();
        });
      },
    );

    _prepareProfile();
  }

  Future<void> _prepareProfile() async {
    var account = await AccountService.instance.activeAccount();
    if (!account.profileComplete) {
      final remote = await TCloudDeviceAuth.instance.profile();
      final remoteName = remote?['displayName']?.toString() ?? '';
      final remoteUsername = remote?['username']?.toString() ?? '';
      if (remote?['profileComplete'] == true) {
        try {
          account = await AccountService.instance.saveProfile(
            remoteName,
            remoteUsername,
          );
        } catch (_) {}
      }
    }
    if (!mounted) return;
    _nameController.text = account.displayName ?? '';
    _usernameController.text = account.username ?? '';
    if (account.profileComplete) {
      setState(() {
        _profileReady = true;
        _busy = true;
      });
      unawaited(_syncProfileWithCore(account));
      await _initialize();
    } else {
      setState(() {
        _profileReady = false;
        _busy = false;
      });
    }
  }

  Future<void> _saveProfile() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final profile = await AccountService.instance.saveProfile(
        _nameController.text,
        _usernameController.text,
      );
      if (!mounted) return;
      setState(() {
        _profileReady = true;
      });
      unawaited(_syncProfileWithCore(profile));
      await _initialize();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = error.toString().replaceFirst('Bad state: ', '');
      });
    }
  }

  Future<void> _syncProfileWithCore(TCloudAccount profile) async {
    Object? lastFailure;
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        await TCloudDeviceAuth.instance.register(
          displayName: profile.displayName!,
          username: profile.username!,
        );
        return;
      } catch (failure) {
        lastFailure = failure;
        await Future<void>.delayed(Duration(seconds: 2 << attempt));
      }
    }
    if (!mounted || lastFailure == null) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Seu perfil foi salvo neste aparelho. A conexão com a nuvem será tentada novamente.',
        ),
      ),
    );
  }

  Future<void> _initialize() async {
    if (!TelegramConfig.isConfigured) {
      if (!mounted) return;

      setState(() {
        _busy = false;
        _error =
            'As credenciais do Telegram ainda não foram fornecidas ao APK.';
      });

      return;
    }

    try {
      await _tdlib.initialize();

      // Algumas versões/dispositivos Android podem entregar o primeiro
      // evento do TDLib antes de o listener Flutter estar completamente
      // pronto. Consulte o estado por alguns segundos como fallback.
      for (var attempt = 0; attempt < 20; attempt++) {
        if (!mounted || _openedHome) return;

        await Future<void>.delayed(const Duration(milliseconds: 500));

        final nativeState = await _tdlib.getState();

        if (nativeState == 'ready') {
          _openHome();
          return;
        }

        final resolved = switch (nativeState) {
          'phone' => TdlibAuthorizationStage.phone,
          'code' => TdlibAuthorizationStage.code,
          'password' => TdlibAuthorizationStage.password,
          'email_address' => TdlibAuthorizationStage.emailAddress,
          'email_code' => TdlibAuthorizationStage.emailCode,
          'registration' => TdlibAuthorizationStage.registration,
          'other_device' => TdlibAuthorizationStage.otherDevice,
          'logging_out' => TdlibAuthorizationStage.loggingOut,
          'closing' => TdlibAuthorizationStage.closing,
          'closed' => TdlibAuthorizationStage.closed,
          _ => null,
        };

        if (resolved != null) {
          if (!mounted) return;

          setState(() {
            _stage = resolved;
            _busy = false;
            _error = null;
          });

          return;
        }
      }

      if (!mounted) return;

      setState(() {
        _busy = false;
        _error =
            'O Telegram demorou para iniciar. Feche o TCloud e tente novamente.';
      });
    } on PlatformException catch (error) {
      if (!mounted) return;

      setState(() {
        _busy = false;
        _error = error.message ?? error.code;
      });
    } catch (error) {
      if (!mounted) return;

      setState(() {
        _busy = false;
        _error = error.toString();
      });
    }
  }

  void _handleTdlibEvent(TdlibEvent event) {
    if (!mounted) return;

    if (event.isError) {
      setState(() {
        _busy = false;
        _error = _friendlyError(event.message);
      });

      return;
    }

    final stage = event.stage;

    if (stage == null) return;

    if (stage == TdlibAuthorizationStage.ready) {
      _openHome();
      return;
    }

    // O EventChannel pode emitir o estado inicial antes de o TDLib
    // terminar de carregar. Não deixe "uninitialized" ou o estado
    // genérico "authorization" apagar a tela de carregamento.
    if (stage == TdlibAuthorizationStage.uninitialized ||
        stage == TdlibAuthorizationStage.authorization) {
      return;
    }

    setState(() {
      _stage = stage;
      _busy = stage == TdlibAuthorizationStage.initializing;
      _error = null;
    });
  }

  String _friendlyError(String? value) {
    final text = value?.trim() ?? '';

    if (text.contains('PHONE_NUMBER_INVALID')) {
      return 'O número de telefone informado não é válido.';
    }

    if (text.contains('PHONE_CODE_INVALID')) {
      return 'O código informado está incorreto.';
    }

    if (text.contains('PHONE_CODE_EXPIRED')) {
      return 'O código expirou. Solicite um novo código.';
    }

    if (text.contains('PASSWORD_HASH_INVALID')) {
      return 'A senha de verificação em duas etapas está incorreta.';
    }

    if (text.contains('FLOOD_WAIT')) {
      return 'Muitas tentativas. Aguarde um pouco e tente novamente.';
    }

    if (text.isEmpty) {
      return 'Não foi possível continuar agora.';
    }

    return text;
  }

  String _normalizeCode(String value) {
    return value.replaceAll(RegExp(r'[^0-9]'), '');
  }

  void _onCodeChanged(String value) {
    final code = _normalizeCode(value);
    final previousLength = _lastCodeLength;
    _lastCodeLength = code.length;

    if (_stage != TdlibAuthorizationStage.code ||
        _busy ||
        _autoCodeQueued ||
        code.length < 4) {
      return;
    }

    final arrivedAtOnce =
        previousLength == 0 || code.length - previousLength >= 2;

    if (!arrivedAtOnce) return;

    _autoCodeQueued = true;
    Future<void>.delayed(const Duration(milliseconds: 120), () {
      if (!mounted) return;
      _autoCodeQueued = false;
      if (_stage != TdlibAuthorizationStage.code || _busy) return;

      final current = _normalizeCode(_codeController.text);
      if (current.length < 4) return;

      TextInput.finishAutofillContext(shouldSave: false);
      _submit();
    });
  }

  Future<void> _pasteCode() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted) return;

    final text = data?.text ?? '';
    final match = RegExp(r'\b\d{4,10}\b').firstMatch(text);

    if (match == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Nenhum codigo do Telegram foi encontrado na area de transferencia.',
          ),
        ),
      );
      return;
    }

    final code = match.group(0)!;
    _codeController.value = TextEditingValue(
      text: code,
      selection: TextSelection.collapsed(offset: code.length),
    );
    _lastCodeLength = code.length;

    TextInput.finishAutofillContext(shouldSave: false);
    await _submit();
  }

  Future<void> _submit() async {
    if (_busy) return;

    FocusScope.of(context).unfocus();

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      switch (_stage) {
        case TdlibAuthorizationStage.phone:
          final phone = _phoneController.text.trim();

          if (phone.length < 8) {
            throw const FormatException('Digite um número de telefone válido.');
          }

          await _tdlib.submitPhone(phone);
          await AccountService.instance.rememberPhone(phone);
          break;

        case TdlibAuthorizationStage.code:
          final code = _codeController.text.trim();

          if (code.isEmpty) {
            throw const FormatException(
              'Digite o código recebido no Telegram.',
            );
          }

          await _tdlib.submitCode(code);
          break;

        case TdlibAuthorizationStage.password:
          final password = _passwordController.text;

          if (password.isEmpty) {
            throw const FormatException(
              'Digite sua senha de verificação em duas etapas.',
            );
          }

          await _tdlib.submitPassword(password);
          break;

        default:
          setState(() {
            _busy = false;
          });
      }
    } on FormatException catch (error) {
      if (!mounted) return;

      setState(() {
        _busy = false;
        _error = error.message;
      });
    } on PlatformException catch (error) {
      if (!mounted) return;

      setState(() {
        _busy = false;
        _error = _friendlyError(error.message);
      });
    } catch (error) {
      if (!mounted) return;

      setState(() {
        _busy = false;
        _error = _friendlyError(error.toString());
      });
    }
  }

  void _openHome() {
    if (_openedHome || !mounted) return;

    _openedHome = true;

    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(builder: (_) => const PreviewHomeScreen()),
    );
  }

  String get _title {
    switch (_stage) {
      case TdlibAuthorizationStage.code:
        return 'Digite o código';

      case TdlibAuthorizationStage.password:
        return 'Verificação em duas etapas';

      case TdlibAuthorizationStage.initializing:
        return 'Conectando';

      default:
        return 'Entrar';
    }
  }

  String get _description {
    switch (_stage) {
      case TdlibAuthorizationStage.code:
        return 'Enviamos um código para sua conta do Telegram.';

      case TdlibAuthorizationStage.password:
        return 'Sua conta possui uma senha adicional de segurança.';

      case TdlibAuthorizationStage.emailAddress:
      case TdlibAuthorizationStage.emailCode:
        return 'Sua conta exige uma verificação adicional por e-mail.';

      case TdlibAuthorizationStage.registration:
        return 'Esta conta ainda precisa concluir o cadastro no Telegram.';

      case TdlibAuthorizationStage.otherDevice:
        return 'Confirme esta entrada em outro dispositivo conectado ao Telegram.';

      case TdlibAuthorizationStage.initializing:
        return 'Preparando sua sessão segura...';

      default:
        return 'Use o mesmo número da sua conta do Telegram.';
    }
  }

  String get _buttonLabel {
    switch (_stage) {
      case TdlibAuthorizationStage.code:
        return 'Confirmar código';

      case TdlibAuthorizationStage.password:
        return 'Entrar';

      default:
        return 'Continuar';
    }
  }

  bool get _canSubmit =>
      _stage == TdlibAuthorizationStage.phone ||
      _stage == TdlibAuthorizationStage.code ||
      _stage == TdlibAuthorizationStage.password;

  Widget _buildInput() {
    switch (_stage) {
      case TdlibAuthorizationStage.code:
        return AutofillGroup(
          child: TextField(
            controller: _codeController,
            autofocus: true,
            keyboardType: TextInputType.number,
            textInputAction: TextInputAction.done,
            autofillHints: const [AutofillHints.oneTimeCode],
            inputFormatters: <TextInputFormatter>[
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(10),
            ],
            onChanged: _onCodeChanged,
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(
              labelText: 'Codigo do Telegram',
              hintText: '12345',
              prefixIcon: const Icon(Icons.password_outlined),
              helperText:
                  'Se o Android preencher o codigo, o TCloud confirma sozinho.',
              suffixIcon: IconButton(
                onPressed: _busy ? null : _pasteCode,
                tooltip: 'Colar codigo',
                icon: const Icon(Icons.content_paste_outlined),
              ),
            ),
          ),
        );
      case TdlibAuthorizationStage.password:
        return TextField(
          controller: _passwordController,
          autofocus: true,
          obscureText: !_passwordVisible,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _submit(),
          decoration: InputDecoration(
            labelText: 'Senha',
            prefixIcon: const Icon(Icons.lock_outline),
            suffixIcon: IconButton(
              onPressed: () {
                setState(() {
                  _passwordVisible = !_passwordVisible;
                });
              },
              icon: Icon(
                _passwordVisible
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined,
              ),
            ),
          ),
        );

      case TdlibAuthorizationStage.phone:
        return TextField(
          controller: _phoneController,
          keyboardType: TextInputType.phone,
          textInputAction: TextInputAction.done,
          autofillHints: const [AutofillHints.telephoneNumber],
          onSubmitted: (_) => _submit(),
          decoration: const InputDecoration(
            labelText: 'Número de telefone',
            hintText: '+55 92 99999-9999',
            prefixIcon: Icon(Icons.phone_outlined),
          ),
        );

      default:
        return const SizedBox.shrink();
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _phoneController.dispose();
    _codeController.dispose();
    _passwordController.dispose();
    _nameController.dispose();
    _usernameController.dispose();

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_profileReady == false) {
      return Scaffold(
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 42, 24, 28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Icon(Icons.cloud_outlined, size: 58),
                const SizedBox(height: 28),
                Text(
                  'Crie seu perfil',
                  style: Theme.of(context).textTheme.headlineMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                const Text(
                  'Ele identifica você no TCloud e nos compartilhamentos.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 28),
                TextField(
                  controller: _nameController,
                  textCapitalization: TextCapitalization.words,
                  autofillHints: const [AutofillHints.name],
                  decoration: const InputDecoration(
                    labelText: 'Seu nome',
                    prefixIcon: Icon(Icons.person_outline),
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: _usernameController,
                  autocorrect: false,
                  enableSuggestions: false,
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[a-zA-Z0-9_]')),
                    LengthLimitingTextInputFormatter(32),
                  ],
                  decoration: const InputDecoration(
                    labelText: 'Nome de usuário',
                    prefixText: '@',
                    prefixIcon: Icon(Icons.alternate_email),
                    helperText: 'De 3 a 32 letras, números ou _.',
                  ),
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 14),
                    child: Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                const SizedBox(height: 22),
                FilledButton.icon(
                  onPressed: _busy ? null : _saveProfile,
                  icon: _busy
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.arrow_forward),
                  label: const Text('Continuar com o Telegram'),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 42, 24, 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    color: TCloudTheme.primary.withValues(alpha: .12),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: TCloudTheme.primary.withValues(alpha: .28),
                    ),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.asset('assets/brand/tcloud-logo.png'),
                  ),
                ),
              ),

              const SizedBox(height: 20),

              Text(
                'TCloud',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: TCloudTheme.textPrimary,
                  fontWeight: FontWeight.w700,
                  fontSize: 30,
                  letterSpacing: -.7,
                ),
              ),

              const SizedBox(height: 7),

              Text(
                'Seus arquivos, sempre com você.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: TCloudTheme.textSecondary,
                  fontSize: 14,
                ),
              ),

              const SizedBox(height: 42),

              Text(
                _title,
                style: TextStyle(
                  color: TCloudTheme.textPrimary,
                  fontWeight: FontWeight.w600,
                  fontSize: 20,
                ),
              ),

              const SizedBox(height: 7),

              Text(
                _description,
                style: TextStyle(color: TCloudTheme.textSecondary, height: 1.4),
              ),

              const SizedBox(height: 22),

              if (_canSubmit) _buildInput(),

              if (_error != null) ...[
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.red.withValues(alpha: .08),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: Colors.red.withValues(alpha: .18),
                    ),
                  ),
                  child: Text(
                    _error!,
                    style: const TextStyle(fontSize: 12, height: 1.35),
                  ),
                ),
              ],

              const SizedBox(height: 16),

              if (_canSubmit)
                SizedBox(
                  height: 50,
                  child: FilledButton(
                    onPressed: _busy ? null : _submit,
                    style: FilledButton.styleFrom(
                      backgroundColor: TCloudTheme.primary,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: _busy
                        ? const SizedBox(
                            width: 21,
                            height: 21,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(
                            _buttonLabel,
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                  ),
                )
              else if (_busy)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 20),
                  child: Center(child: CircularProgressIndicator()),
                ),

              const SizedBox(height: 34),

              Text(
                'TCloud Mobile • Android',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: TCloudTheme.textSecondary,
                  fontSize: 11,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

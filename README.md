# TCloud Mobile

Aplicativo Android em Flutter que acessa os arquivos do TCloud diretamente pelo Telegram/TDLib.

## Desenvolvimento

```powershell
flutter pub get
flutter analyze
flutter test
flutter run
```

## Como os arquivos são encontrados

- Fóruns do TCloud e todos os seus tópicos são descobertos por paginação.
- Pastas lógicas podem reunir mais de uma origem Telegram.
- Cada origem mantém seu próprio cursor, evitando repetição ou perda de páginas antigas.
- O primeiro carregamento válido é armazenado em cache; falhas transitórias não apagam arquivos já descobertos.

Versão atual: **1.1.38+119**.

Para gerar um APK que atualize tanto as instalacoes debug antigas quanto as
releases oficiais, execute primeiro `flutter build apk --release` e depois
`powershell -ExecutionPolicy Bypass -File scripts/sign-mobile-rotation.ps1`.
O APK compativel sera criado como `app-release-compatible.apk`.

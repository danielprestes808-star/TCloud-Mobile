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

Versão atual: **1.1.41+122**.

A galeria separa imagens e vídeos e oferece agrupamento facial local por álbum.
Os grupos faciais podem ser revisados, combinados e corrigidos sem apagar as
fotos originais. A fila de backup permite atualizar o estado e tentar novamente.
Antes de analisar um álbum, o app informa quantas imagens remotas serão
baixadas temporariamente e estima o volume de dados. A análise roda no aparelho,
com progresso e opção de interromper após a imagem atual; o cache temporário é
limpo ao concluir cada imagem, com aviso caso algum arquivo não possa ser
removido.

Para gerar um APK que atualize tanto as instalacoes debug antigas quanto as
releases oficiais, execute primeiro `flutter build apk --release` e depois
`powershell -ExecutionPolicy Bypass -File scripts/sign-mobile-rotation.ps1`.
O APK compativel sera criado como `app-release-compatible.apk`.

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

Versão atual: **1.1.45+126**.

A galeria oferece agrupamento facial local por álbum ou biblioteca. A análise
inclui fotos e amostras de vídeos (um quadro a cada cerca de 10 segundos, até 12
por vídeo), com confirmação da quantidade e do tráfego estimado antes de baixar
mídia remota. Grupos podem ser revisados, renomeados, combinados e corrigidos
sem apagar os originais. A análise pode ser pausada e retomada; dados faciais e
grupos também podem ser removidos do aparelho. A navegação e a exibição das
pastas foram simplificadas para destacar os destinos e ações mais usados.
Na tela de pastas, a busca funciona igualmente nos modos Lista e Galeria,
ações secundárias ficam agrupadas em um menu e a seleção em lote mantém visíveis
as operações mais comuns.

A navegação principal separa **Fotos**, organizadas por data, de **Arquivos**,
com pastas, filtros e opções de visualização. Pessoas, transferências e ajustes
continuam disponíveis na barra inferior; arquivos offline e pastas do telefone
ou computador ficam acessíveis pelas opções de Arquivos.
Fotos carrega todas as páginas do histórico do Telegram em todas as pastas,
incluindo vídeos, e informa quando alguma pasta não pôde ser atualizada.

Para gerar um APK que atualize tanto as instalacoes debug antigas quanto as
releases oficiais, execute primeiro `flutter build apk --release` e depois
`powershell -ExecutionPolicy Bypass -File scripts/sign-mobile-rotation.ps1`.
O APK compativel sera criado como `app-release-compatible.apk`.

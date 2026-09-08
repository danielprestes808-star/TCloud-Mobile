class TCloudFile {
  const TCloudFile({
    this.coreFileId,
    required this.messageId,
    required this.chatId,
    required this.messageThreadId,
    required this.fileId,
    required this.name,
    required this.size,
    required this.kind,
    this.createdAt = 0,
    this.mimeType,
    this.localPath,
    this.downloaded = false,
    this.thumbnailFileId = 0,
    this.thumbnailLocalPath,
    this.minithumbnailBase64,
    this.durationSeconds = 0,
    this.remoteId,
    this.remoteUniqueId,
  });

  final String? coreFileId;
  final int messageId;
  final int chatId;
  final int messageThreadId;
  final int fileId;
  final String name;
  final int size;
  final String kind;
  final int createdAt;
  final String? mimeType;
  final String? localPath;
  final bool downloaded;
  final int thumbnailFileId;
  final String? thumbnailLocalPath;
  final String? minithumbnailBase64;
  final int durationSeconds;
  final String? remoteId;
  final String? remoteUniqueId;

  String get globalIdentity {
    final canonical = coreFileId?.trim() ?? '';
    if (canonical.isNotEmpty) {
      return 'core:$canonical';
    }
    return 'telegram:$chatId:$messageThreadId:$messageId';
  }

  String get stableIdentity => '$chatId:$messageThreadId:$messageId';

  /// Identidade do conteudo no Telegram. Mensagens diferentes podem apontar
  /// para o mesmo arquivo remoto (por exemplo, apos uma pasta ser recriada).
  String get contentIdentity {
    final unique = remoteUniqueId?.trim() ?? '';
    return unique.isNotEmpty ? 'telegram-file:$unique' : stableIdentity;
  }

  String get syncIdentity => '$stableIdentity:$fileId:$thumbnailFileId';

  bool get isImage => kind == 'imagem';
  bool get isVideo => kind == 'video';
  bool get isMedia => isImage || isVideo || kind == 'animacao';

  TCloudFile copyWith({
    String? coreFileId,
    int? messageId,
    int? chatId,
    int? messageThreadId,
    int? fileId,
    String? name,
    int? size,
    String? kind,
    int? createdAt,
    String? mimeType,
    String? localPath,
    bool? downloaded,
    int? thumbnailFileId,
    String? thumbnailLocalPath,
    String? minithumbnailBase64,
    int? durationSeconds,
    String? remoteId,
    String? remoteUniqueId,
  }) {
    return TCloudFile(
      coreFileId: coreFileId ?? this.coreFileId,
      messageId: messageId ?? this.messageId,
      chatId: chatId ?? this.chatId,
      messageThreadId: messageThreadId ?? this.messageThreadId,
      fileId: fileId ?? this.fileId,
      name: name ?? this.name,
      size: size ?? this.size,
      kind: kind ?? this.kind,
      createdAt: createdAt ?? this.createdAt,
      mimeType: mimeType ?? this.mimeType,
      localPath: localPath ?? this.localPath,
      downloaded: downloaded ?? this.downloaded,
      thumbnailFileId: thumbnailFileId ?? this.thumbnailFileId,
      thumbnailLocalPath: thumbnailLocalPath ?? this.thumbnailLocalPath,
      minithumbnailBase64: minithumbnailBase64 ?? this.minithumbnailBase64,
      durationSeconds: durationSeconds ?? this.durationSeconds,
      remoteId: remoteId ?? this.remoteId,
      remoteUniqueId: remoteUniqueId ?? this.remoteUniqueId,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'coreFileId': coreFileId,
    'messageId': messageId,
    'chatId': chatId,
    'messageThreadId': messageThreadId,
    'fileId': fileId,
    'name': name,
    'size': size,
    'kind': kind,
    'createdAt': createdAt,
    'mimeType': mimeType,
    'localPath': localPath,
    'downloaded': downloaded,
    'thumbnailFileId': thumbnailFileId,
    'thumbnailLocalPath': thumbnailLocalPath,
    'minithumbnailBase64': minithumbnailBase64,
    'durationSeconds': durationSeconds,
    'remoteId': remoteId,
    'remoteUniqueId': remoteUniqueId,
  };

  factory TCloudFile.fromJson(Map<String, dynamic> map) {
    int asInt(dynamic value) {
      if (value is int) return value;
      if (value is num) return value.toInt();
      return int.tryParse(value?.toString() ?? '') ?? 0;
    }

    return TCloudFile(
      coreFileId: (map['coreFileId'] ?? map['core_file_id'])?.toString(),
      messageId: asInt(map['messageId']),
      chatId: asInt(map['chatId']),
      messageThreadId: asInt(map['messageThreadId']),
      fileId: asInt(map['fileId']),
      name: map['name']?.toString() ?? 'arquivo',
      size: asInt(map['size']),
      kind: map['kind']?.toString() ?? 'arquivo',
      createdAt: asInt(map['createdAt']),
      mimeType: map['mimeType']?.toString(),
      localPath: map['localPath']?.toString(),
      downloaded: map['downloaded'] == true,
      thumbnailFileId: asInt(map['thumbnailFileId']),
      thumbnailLocalPath: map['thumbnailLocalPath']?.toString(),
      minithumbnailBase64: map['minithumbnailBase64']?.toString(),
      durationSeconds: asInt(map['durationSeconds']),
      remoteId: map['remoteId']?.toString(),
      remoteUniqueId: map['remoteUniqueId']?.toString(),
    );
  }
}

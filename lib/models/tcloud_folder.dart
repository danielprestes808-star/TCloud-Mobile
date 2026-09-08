class TCloudFolder {
  const TCloudFolder({
    required this.chatId,
    required this.title,
    this.forumTitle = '',
    this.forumTopicId = 0,
    this.messageThreadId = 0,
    this.historyMessageId = 0,
    this.isGeneral = false,
  });

  final int chatId;
  final String title;
  final String forumTitle;
  final int forumTopicId;
  final int messageThreadId;
  final int historyMessageId;
  final bool isGeneral;

  bool get isTopic =>
      forumTopicId != 0 || messageThreadId != 0 || historyMessageId != 0;

  // A identidade da pasta nao pode depender da ultima mensagem: esse valor
  // muda a cada upload e fazia o cache apontar para outra pasta logica.
  String get cacheKey => '$chatId:$forumTopicId:$messageThreadId';

  Map<String, dynamic> toJson() => <String, dynamic>{
    'chatId': chatId,
    'title': title,
    'forumTitle': forumTitle,
    'forumTopicId': forumTopicId,
    'messageThreadId': messageThreadId,
    'historyMessageId': historyMessageId,
    'isGeneral': isGeneral,
  };

  factory TCloudFolder.fromJson(Map<String, dynamic> map) {
    int asInt(dynamic value) {
      if (value is int) return value;
      if (value is num) return value.toInt();
      return int.tryParse(value?.toString() ?? '') ?? 0;
    }

    return TCloudFolder(
      chatId: asInt(map['chatId']),
      title: map['title']?.toString() ?? 'TCloud',
      forumTitle: map['forumTitle']?.toString() ?? '',
      forumTopicId: asInt(map['forumTopicId']),
      messageThreadId: asInt(map['messageThreadId']),
      historyMessageId: asInt(map['historyMessageId']),
      isGeneral: map['isGeneral'] == true,
    );
  }
}

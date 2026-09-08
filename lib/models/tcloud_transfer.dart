enum TCloudTransferStatus { waiting, running, completed, failed }

class TCloudTransfer {
  TCloudTransfer({
    required this.name,
    required this.direction,
    this.status = TCloudTransferStatus.waiting,
    this.error,
  });

  final String name;
  final String direction;

  TCloudTransferStatus status;
  String? error;
}

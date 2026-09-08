import 'package:flutter/foundation.dart';

import '../models/tcloud_transfer.dart';

class TransferCenter extends ChangeNotifier {
  TransferCenter._();

  static final instance = TransferCenter._();

  final List<TCloudTransfer> transfers = <TCloudTransfer>[];

  int get runningCount => transfers
      .where((item) => item.status == TCloudTransferStatus.running)
      .length;

  int get failedCount => transfers
      .where((item) => item.status == TCloudTransferStatus.failed)
      .length;

  void add(TCloudTransfer transfer) {
    transfers.insert(0, transfer);
    if (transfers.length > 100) {
      transfers.removeRange(100, transfers.length);
    }
    notifyListeners();
  }

  void changed() => notifyListeners();

  void clearCompleted() {
    transfers.removeWhere(
      (item) =>
          item.status == TCloudTransferStatus.completed ||
          item.status == TCloudTransferStatus.failed,
    );
    notifyListeners();
  }
}

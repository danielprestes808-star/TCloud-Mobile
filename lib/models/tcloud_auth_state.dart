enum TCloudAuthStage { phone, code, password, ready }

class TCloudAuthState {
  const TCloudAuthState({
    this.stage = TCloudAuthStage.phone,
    this.busy = false,
    this.error,
  });

  final TCloudAuthStage stage;
  final bool busy;
  final String? error;

  TCloudAuthState copyWith({
    TCloudAuthStage? stage,
    bool? busy,
    String? error,
  }) {
    return TCloudAuthState(
      stage: stage ?? this.stage,
      busy: busy ?? this.busy,
      error: error,
    );
  }
}

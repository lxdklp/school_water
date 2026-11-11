import '../core/models.dart';
import '../core/network.dart';
import '../core/storage.dart';
import '../core/signing_config.dart';
import '../features/drinking/drinking_api.dart';
import '../features/bathing/bathing_api.dart';
import 'water_controller.dart';

class AppDependencies {
  final AppMode mode;
  final KeyValueStore store;
  late final SessionJournal journal;
  late final DrinkingApi drinkingApi;
  late final BathingApi bathingApi;
  late final WaterController drinking, bathing;
  AppDependencies({
    this.mode = AppMode.manualLive,
    KeyValueStore? store,
    Transport? transport,
    String drinkingSecret = SigningConfig.drinkingSecret,
    String bathingKey = SigningConfig.bathingKey,
    BathStatusDecoder bathDecoder = const UnknownBathStatusDecoder(),
  }) : store = store ?? const SecureStore() {
    journal = SessionJournal(this.store, mode);
    final client = transport ?? LiveTransport(mode);
    drinkingApi = DrinkingApi(client, signingSecret: drinkingSecret);
    bathingApi = BathingApi(
      client,
      decoder: bathDecoder,
      signingKey: bathingKey,
    );
    drinking = WaterController(
      platform: WaterPlatform.drinking,
      journal: journal,
      drinking: drinkingApi,
      bathing: bathingApi,
      mode: mode,
    );
    bathing = WaterController(
      platform: WaterPlatform.bathing,
      journal: journal,
      drinking: drinkingApi,
      bathing: bathingApi,
      mode: mode,
    );
  }
  Future<void> initialize() async {
    await Future.wait([drinking.initialize(), bathing.initialize()]);
  }

  void dispose() {
    drinking.dispose();
    bathing.dispose();
  }
}

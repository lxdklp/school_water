import 'package:water/app/app_dependencies.dart';
import 'package:water/app/water_controller.dart';
import 'package:water/core/models.dart';
import 'package:water/core/storage.dart';
import 'package:water/features/drinking/drinking_api.dart';
import 'package:water/features/bathing/bathing_api.dart';

import 'fake_transport.dart';
import 'memory_store.dart';
import 'signing_fixtures.dart';

/// Only test entrypoints import this composition root. It never creates a live client.
class TestDependencies extends AppDependencies {
  final FakeTransport? fake;
  TestDependencies._(KeyValueStore store, FakeTransport fake)
    : fake = fake,
      super(
        mode: AppMode.mock,
        store: store,
        transport: fake,
        drinkingSecret: fixtureDrinkingSecret,
        bathingKey: fixtureBathingKey,
        bathDecoder: const DemoBathStatusDecoder(),
      );
  factory TestDependencies({KeyValueStore? store, FakeTransport? fake}) =>
      TestDependencies._(store ?? MemoryStore(), fake ?? FakeTransport());
}

extension FixtureLogin on WaterController {
  Future<void> demoLogin() => authenticate(
    () async => Account(
      scope: isBath ? 'student:demo-student' : 'demo-drinking',
      token: 'demo-token',
      origin: isBath ? BathingApi.origin : DrinkingApi.origin,
      studentId: isBath ? 'demo-student' : null,
      cookies: isBath ? 'tokenInfo=demo-token' : null,
    ),
  );
}

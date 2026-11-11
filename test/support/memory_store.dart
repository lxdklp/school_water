import 'package:water/core/storage.dart';
import 'package:water/core/models.dart';

class MemoryStore implements KeyValueStore {
  final Map<String, String> data = {};
  bool failWrites = false;
  @override
  Future<String?> read(String key) async => data[key];
  @override
  Future<void> write(String key, String value) async {
    if (failWrites) throw const ApiFailure('存储不可用', kind: FailureKind.storage);
    data[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    if (failWrites) throw const ApiFailure('存储不可用', kind: FailureKind.storage);
    data.remove(key);
  }
}

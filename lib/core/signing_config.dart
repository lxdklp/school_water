import 'models.dart';

class SigningConfig {
  static const drinkingSecret = String.fromEnvironment('DRINKING_APP_SECRET');
  static const bathingKey = String.fromEnvironment('LXT_SIGN_KEY');

  static String require(String value) {
    if (value.trim().isEmpty) {
      throw const ApiFailure('缺少签名配置, 请使用本地配置文件重新构建');
    }
    return value;
  }
}

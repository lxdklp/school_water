import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

const pinkSeed = Color(0xFFD65A8A);
ThemeData waterTheme(
  Brightness brightness, {
  ColorScheme? lightDynamic,
  ColorScheme? darkDynamic,
  TargetPlatform? platform,
}) {
  final useDynamic =
      (platform ?? defaultTargetPlatform) == TargetPlatform.android &&
      lightDynamic != null &&
      darkDynamic != null;
  final scheme = useDynamic
      ? (brightness == Brightness.light ? lightDynamic : darkDynamic)
      : ColorScheme.fromSeed(seedColor: pinkSeed, brightness: brightness);
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    brightness: brightness,
    scaffoldBackgroundColor: scheme.surface,
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      foregroundColor: scheme.onSurface,
      centerTitle: false,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(48, 48),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
      ),
    ),
    inputDecorationTheme: const InputDecorationTheme(
      border: OutlineInputBorder(),
    ),
  );
}

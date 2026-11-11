import 'dart:async';

import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'app_dependencies.dart';
import 'app_theme.dart';
import 'app_shell.dart';
import '../core/models.dart';

class WaterApp extends StatefulWidget {
  final AppDependencies dependencies;
  final bool initialize;
  const WaterApp({
    super.key,
    required this.dependencies,
    this.initialize = true,
  });
  @override
  State<WaterApp> createState() => _WaterAppState();
}

class _WaterAppState extends State<WaterApp> with WidgetsBindingObserver {
  final dynamicKey = GlobalKey<DynamicColorBuilderState>();
  Timer? _poll;
  bool foreground = true, _pollRunning = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.dependencies.drinking.addListener(_schedule);
    if (widget.initialize) unawaited(widget.dependencies.initialize());
  }

  void _schedule() {
    _poll?.cancel();
    if (_pollRunning) return;
    final c = widget.dependencies.drinking;
    if (!foreground ||
        c.busy ||
        c.readBusy ||
        !([Stage.awaitingWork, Stage.working].contains(c.session?.stage) ||
            (c.session?.stage == Stage.completionUnconfirmed &&
                c.autoCreateAllowed)) ||
        c.account == null) {
      return;
    }
    _poll = Timer(const Duration(seconds: 2), () async {
      if (!mounted || !foreground) return;
      if (DateTime.now().difference(c.session!.intentAt) >
          const Duration(minutes: 5)) {
        // Read-only deadline. No completion, stop or new command is implied.
        c.stopPollingAtDeadline();
        return;
      }
      _pollRunning = true;
      try {
        await c.refreshSession(silent: true);
      } finally {
        _pollRunning = false;
        if (mounted) _schedule();
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    for (final c in [
      widget.dependencies.drinking,
      widget.dependencies.bathing,
    ]) {
      c.setForeground(foreground);
    }
    if (foreground) {
      unawaited(dynamicKey.currentState?.initPlatformState());
      for (final c in [
        widget.dependencies.drinking,
        widget.dependencies.bathing,
      ]) {
        if (c.canQuery) {
          unawaited(
            c.refreshSession(silent: true).whenComplete(() {
              if (mounted) _schedule();
            }),
          );
        }
      }
    }
    _schedule();
  }

  @override
  void dispose() {
    _poll?.cancel();
    widget.dependencies.drinking.removeListener(_schedule);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => DynamicColorBuilder(
    key: dynamicKey,
    builder: (light, dark) {
      // dynamic_color 2.x exposes material_ui ColorScheme. Map its roles to the
      // Flutter SDK Material components without replacing the app design system.
      final schemes = [light, dark]
          .map(
            (s) => s == null
                ? null
                : ColorScheme(
                    brightness: s.brightness,
                    primary: s.primary,
                    onPrimary: s.onPrimary,
                    primaryContainer: s.primaryContainer,
                    onPrimaryContainer: s.onPrimaryContainer,
                    secondary: s.secondary,
                    onSecondary: s.onSecondary,
                    secondaryContainer: s.secondaryContainer,
                    onSecondaryContainer: s.onSecondaryContainer,
                    tertiary: s.tertiary,
                    onTertiary: s.onTertiary,
                    tertiaryContainer: s.tertiaryContainer,
                    onTertiaryContainer: s.onTertiaryContainer,
                    error: s.error,
                    onError: s.onError,
                    errorContainer: s.errorContainer,
                    onErrorContainer: s.onErrorContainer,
                    surface: s.surface,
                    onSurface: s.onSurface,
                    onSurfaceVariant: s.onSurfaceVariant,
                    surfaceContainerLowest: s.surfaceContainerLowest,
                    surfaceContainerLow: s.surfaceContainerLow,
                    surfaceContainer: s.surfaceContainer,
                    surfaceContainerHigh: s.surfaceContainerHigh,
                    surfaceContainerHighest: s.surfaceContainerHighest,
                    surfaceDim: s.surfaceDim,
                    surfaceBright: s.surfaceBright,
                    outline: s.outline,
                    outlineVariant: s.outlineVariant,
                    inverseSurface: s.inverseSurface,
                    onInverseSurface: s.onInverseSurface,
                    inversePrimary: s.inversePrimary,
                    shadow: s.shadow,
                    scrim: s.scrim,
                    surfaceTint: s.surfaceTint,
                  ),
          )
          .toList();
      return MaterialApp(
        title: '校园用水',
        debugShowCheckedModeBanner: false,
        locale: const Locale('zh', 'CN'),
        supportedLocales: const [Locale('zh', 'CN')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        theme: waterTheme(
          Brightness.light,
          lightDynamic: schemes[0],
          darkDynamic: schemes[1],
        ),
        darkTheme: waterTheme(
          Brightness.dark,
          lightDynamic: schemes[0],
          darkDynamic: schemes[1],
        ),
        themeMode: ThemeMode.system,
        home: AppShell(dependencies: widget.dependencies),
      );
    },
  );
}

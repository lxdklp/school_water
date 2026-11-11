import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app/app.dart';
import 'app/app_dependencies.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks([
      'LightLife protocol adaptation',
    ], await rootBundle.loadString('assets/licenses/lightlife.txt'));
  });
  final dependencies = AppDependencies();
  runApp(WaterApp(dependencies: dependencies));
}

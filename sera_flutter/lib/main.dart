import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app.dart';
import 'application/auth_shell.dart';

import 'package:flutter/foundation.dart';

import 'application/sera_controller.dart';
import 'data/repositories.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark,
      systemNavigationBarColor: Color(0xFFFFFFFF),
      systemNavigationBarIconBrightness: Brightness.dark,
    ),
  );
  const apiBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'same-origin',
  );
  final resolvedApi = apiBaseUrl == 'same-origin'
      ? (kIsWeb ? Uri.base.origin : 'http://127.0.0.1:8787')
      : apiBaseUrl;
  const demoDate = String.fromEnvironment('DEMO_DATE');
  if (resolvedApi.isNotEmpty) {
    runApp(
      SeraRoot(apiBaseUrl: resolvedApi, demoDate: DateTime.tryParse(demoDate)),
    );
    return;
  }
  final controller = SeraController(
    repository: createWorkspaceRepository(apiBaseUrl: resolvedApi),
    today: DateTime.tryParse(demoDate),
  );
  runApp(SeraApp(controller: controller));
}

import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:grow_logix/Log_In.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (Platform.isWindows) {
    // 1. Initialize Window Manager
    await windowManager.ensureInitialized();

    // 2. Configure Launch at Startup
    PackageInfo packageInfo = await PackageInfo.fromPlatform();
    launchAtStartup.setup(
      appName: packageInfo.appName.isNotEmpty ? packageInfo.appName : 'Grow Logix Employee',
      appPath: Platform.resolvedExecutable,
    );
    await launchAtStartup.enable();

    // 3. Read First Launch Flag
    final prefs = await SharedPreferences.getInstance();
    final isFirstLaunch = prefs.getBool('is_first_launch') ?? true;

    // 4. Set Window Options
    WindowOptions windowOptions = WindowOptions(
      size: const Size(800, 600),
      center: true,
      skipTaskbar: !isFirstLaunch, // Show in taskbar on first launch, hide on auto-open/subsequent runs
      titleBarStyle: TitleBarStyle.normal,
    );

    windowManager.waitUntilReadyToShow(windowOptions, () async {
      if (isFirstLaunch) {
        await windowManager.setSkipTaskbar(false);
        await windowManager.show();
        await windowManager.focus();
      } else {
        await windowManager.setSkipTaskbar(true);
        await windowManager.hide(); // Run silently on auto-start / background runs
      }
    });
  }

  runApp(
    const ProviderScope(
      child: MyApp(),
    ),
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: LogIn(),
    );
  }
}
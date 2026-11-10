import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';

import 'desk_controller.dart';
import 'desk_page.dart';
import 'desk_theme.dart';
import 'desktop_stream_server.dart';
import 'live_preview.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  if (desktop) {
    await windowManager.ensureInitialized();
    await windowManager.setPreventClose(true);
  }
  const process = MethodChannel('rtmp_live_desk/process');
  final server = DesktopStreamServer(
    attachWindowsJob: Platform.isWindows
        ? (pid) => process.invokeMethod<void>('attach', pid)
        : null,
  );
  final controller = DeskController(server, LivePreview());
  runApp(DeskApp(controller: controller));
  if (desktop) {
    unawaited(
      windowManager.waitUntilReadyToShow(
        const WindowOptions(
          size: Size(1180, 752),
          minimumSize: Size(690, 570),
          center: true,
          title: 'RTMP Live Desk',
          backgroundColor: deskCanvas,
        ),
        () async {
          await windowManager.show();
          await windowManager.focus();
        },
      ),
    );
  }
}

class DeskApp extends StatelessWidget {
  const DeskApp({super.key, required this.controller});
  final DeskController controller;

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(
      seedColor: deskAccent,
      brightness: Brightness.light,
      surface: Colors.white,
    ).copyWith(primary: deskInk, outlineVariant: deskLine);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'RTMP Live Desk',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: scheme,
        scaffoldBackgroundColor: deskCanvas,
        dividerColor: deskLine,
        inputDecorationTheme: InputDecorationTheme(
          isDense: true,
          filled: true,
          fillColor: const Color(0xfff8f9f7),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: deskLine),
          ),
        ),
      ),
      home: DeskPage(controller: controller),
    );
  }
}

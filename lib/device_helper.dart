import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:device_info_plus/device_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

class DeviceHelper {
  static const String _deviceIdKey = 'app_device_uuid_v1';
  static final DeviceInfoPlugin _deviceInfo = DeviceInfoPlugin();
  static const Uuid _uuid = Uuid();

  static Future<String> getDeviceId() async {
    // 1. Web Implementation (Browser)
    if (kIsWeb) {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      String? webDeviceId = prefs.getString(_deviceIdKey);

      if (webDeviceId != null && webDeviceId.isNotEmpty) {
        return webDeviceId;
      }

      // Generate a persistent, deterministic browser fingerprint UUID
      try {
        final WebBrowserInfo info = await _deviceInfo.webBrowserInfo;
        final String fingerprint =
            '${info.vendor}_${info.userAgent}_${info.hardwareConcurrency}_${info.platform}';

        // Deterministic UUID based on browser hardware fingerprint
        webDeviceId = 'WEB-${_uuid.v5(Uuid.NAMESPACE_URL, fingerprint)}';
      } catch (_) {
        // Fallback to standard persistent UUID v4 if web info fails
        webDeviceId = 'WEB-${_uuid.v4()}';
      }

      await prefs.setString(_deviceIdKey, webDeviceId);
      return webDeviceId;
    }

    // 2. Native Desktop Implementations
    try {
      if (Platform.isWindows) {
        WindowsDeviceInfo windowsInfo = await _deviceInfo.windowsInfo;
        return windowsInfo.deviceId; // Hardware Device ID
      } else if (Platform.isMacOS) {
        MacOsDeviceInfo macInfo = await _deviceInfo.macOsInfo;
        return macInfo.systemGUID ?? 'unknown_mac';
      } else if (Platform.isLinux) {
        LinuxDeviceInfo linuxInfo = await _deviceInfo.linuxInfo;
        return linuxInfo.machineId ?? 'unknown_linux';
      } else if (Platform.isAndroid) {
        AndroidDeviceInfo androidInfo = await _deviceInfo.androidInfo;
        return androidInfo.id;
      } else if (Platform.isIOS) {
        IosDeviceInfo iosInfo = await _deviceInfo.iosInfo;
        return iosInfo.identifierForVendor ?? 'unknown_ios';
      }
    } catch (e) {
      // Fallback native key
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      String? fallbackId = prefs.getString(_deviceIdKey);
      if (fallbackId == null || fallbackId.isEmpty) {
        fallbackId = _uuid.v4();
        await prefs.setString(_deviceIdKey, fallbackId);
      }
      return fallbackId;
    }

    return 'unknown_device';
  }
}
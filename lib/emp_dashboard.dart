import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:window_manager/window_manager.dart' as wm;
import 'package:ffi/ffi.dart' as ffi_pkg;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:win32/win32.dart' as win32;

import 'Log_In.dart';

// ==================== FFI SIGNATURES ====================
typedef _CreateCompatibleDC_C = IntPtr Function(IntPtr hdc);
typedef _CreateCompatibleDC_Dart = int Function(int hdc);

typedef _CreateCompatibleBitmap_C = IntPtr Function(IntPtr hdc, Int32 width, Int32 height);
typedef _CreateCompatibleBitmap_Dart = int Function(int hdc, int width, int height);

typedef _SelectObject_C = IntPtr Function(IntPtr hdc, IntPtr h);
typedef _SelectObject_Dart = int Function(int hdc, int h);

typedef _BitBlt_C = Int32 Function(
    IntPtr hdcDest, Int32 xDest, Int32 yDest, Int32 width, Int32 height,
    IntPtr hdcSrc, Int32 xSrc, Int32 ySrc, Uint32 rop);
typedef _BitBlt_Dart = int Function(
    int hdcDest, int xDest, int yDest, int width, int height,
    int hdcSrc, int xSrc, int ySrc, int rop);

typedef _DeleteDC_C = Int32 Function(IntPtr hdc);
typedef _DeleteDC_Dart = int Function(int hdc);

typedef _DeleteObject_C = Int32 Function(IntPtr ho);
typedef _DeleteObject_Dart = int Function(int ho);

typedef _GetDC_C = IntPtr Function(IntPtr hWnd);
typedef _GetDC_Dart = int Function(int hWnd);

typedef _ReleaseDC_C = Int32 Function(IntPtr hWnd, IntPtr hDC);
typedef _ReleaseDC_Dart = int Function(int hWnd, int hDC);

typedef _GetSystemMetrics_C = Int32 Function(Int32 nIndex);
typedef _GetSystemMetrics_Dart = int Function(int nIndex);

typedef _GetDIBits_C = Int32 Function(
    IntPtr hdc, IntPtr hbm, Uint32 start, Uint32 cLines,
    Pointer<Uint8> lpvBits, Pointer<win32.BITMAPINFO> lpbmi, Uint32 usage);
typedef _GetDIBits_Dart = int Function(
    int hdc, int hbm, int start, int cLines,
    Pointer<Uint8> lpvBits, Pointer<win32.BITMAPINFO> lpbmi, int usage);

class EmpDashboard extends StatefulWidget {
  const EmpDashboard({super.key});

  @override
  State<EmpDashboard> createState() => _EmpDashboardState();
}

class _EmpDashboardState extends State<EmpDashboard>
    with WidgetsBindingObserver, wm.WindowListener {
  static const String baseUrl = 'https://goldenrod-raven-866091.hostingersite.com';
  static const String liveStreamUrl = '$baseUrl/live_stream.php';

  static const int _captureIntervalMs = 5000;
  static const String _permSetupKey = 'screen_perm_setup_done_v6';

  bool _isLive = false;
  Timer? _heartbeatTimer;
  DateTime? _sessionStartTime;
  Duration _activeDuration = Duration.zero;
  Duration _offlineDuration = const Duration(minutes: 12, seconds: 45);

  Timer? _timer;
  Timer? _liveRequestTimer;
  Timer? _frameUploadTimer;
  Timer? _activeWindowTimer;

  String _employeeName = 'Loading...';
  String _employeeId = '---';
  String _role = 'Employee';
  String _email = '';
  int? _userId;
  bool _isFetchingEmployee = true;

  int _successfulUploads = 0;
  int _failedUploads = 0;
  bool _isUploading = false;
  String _activeWindowTitle = 'Unknown';
  String _captureMethod = 'initializing';
  String _lastCaptureError = '';

  String? _pcType = 'office';
  String? _pcNumber = 'PC-01';

  // ===== FFI state =====
  DynamicLibrary? _gdi32;
  DynamicLibrary? _user32;

  _CreateCompatibleDC_Dart? _createCompatibleDC;
  _CreateCompatibleBitmap_Dart? _createCompatibleBitmap;
  _SelectObject_Dart? _selectObject;
  _BitBlt_Dart? _bitBlt;
  _DeleteDC_Dart? _deleteDC;
  _DeleteObject_Dart? _deleteObject;
  _GetDC_Dart? _getDC;
  _ReleaseDC_Dart? _releaseDC;
  _GetSystemMetrics_Dart? _getSystemMetrics;
  _GetDIBits_Dart? _getDIBits;

  bool _ffiReady = false;
  String _ffiErrorReason = '';

  final GlobalKey _repaintKey = GlobalKey();
  final FocusNode _rootFocusNode = FocusNode(
    skipTraversal: true,
    canRequestFocus: false,
  );

  int _frameCounter = 0;

  @override
  void initState() {
    super.initState();
    _initFfi();

    wm.windowManager.addListener(this);
    _setupWindowBehavior();
    WidgetsBinding.instance.addObserver(this);

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
        try {
          await wm.windowManager.ensureInitialized();
        } catch (e) {
          debugPrint('window_manager init skipped: $e');
        }
      }
    });

    _loadInitialUserData();
    _startLiveRequestPolling();
    _startHeartbeat();
    _activeWindowTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted && _isLive) _updateActiveWindowTitle();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkAndRequestPermissionsIfNeeded();
    });
  }

  @override
  void dispose() {
    wm.windowManager.removeListener(this);
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _heartbeatTimer?.cancel();
    _liveRequestTimer?.cancel();
    _frameUploadTimer?.cancel();
    _activeWindowTimer?.cancel();
    _rootFocusNode.dispose();
    super.dispose();
  }

  Future<void> _setupWindowBehavior() async {
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      await wm.windowManager.setPreventClose(true);
    }
  }

  @override
  void onWindowClose() async {
    bool isPreventClose = await wm.windowManager.isPreventClose();
    if (isPreventClose) {
      wm.windowManager.hide();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    switch (state) {
      case AppLifecycleState.resumed:
        _sendHeartbeat();
        break;
      case AppLifecycleState.paused:
        break;
      case AppLifecycleState.detached:
        _sendShutdown();
        break;
      case AppLifecycleState.inactive:
        break;
      case AppLifecycleState.hidden:
        break;
    }
  }

  // ==================== HEARTBEAT ====================
  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _sendHeartbeat();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 10), (timer) {
      if (mounted) _sendHeartbeat();
    });
  }

  Future<void> _sendHeartbeat() async {
    if (_employeeId.isEmpty || _employeeId == '---') return;
    try {
      await http.post(
        Uri.parse('$liveStreamUrl?action=heartbeat'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({'emp_id': _employeeId}),
      ).timeout(const Duration(seconds: 5));
    } catch (e) {
      debugPrint('Heartbeat error: $e');
    }
  }

  Future<void> _sendShutdown() async {
    if (_employeeId.isEmpty || _employeeId == '---') return;
    try {
      await http.post(
        Uri.parse('$liveStreamUrl?action=app_shutdown'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({'emp_id': _employeeId}),
      ).timeout(const Duration(seconds: 3));
    } catch (e) {
      debugPrint('Shutdown notify error: $e');
    }
  }

  // ==================== INIT FFI (SAFE) ====================
  void _initFfi() {
    if (!Platform.isWindows) {
      _captureMethod = 'flutter-only';
      _ffiErrorReason = 'Not running on Windows';
      debugPrint('⚠️ FFI skipped: platform is ${Platform.operatingSystem}');
      return;
    }

    try {
      _gdi32 = DynamicLibrary.open('gdi32.dll');
      _user32 = DynamicLibrary.open('user32.dll');

      _createCompatibleDC = _gdi32!
          .lookupFunction<_CreateCompatibleDC_C, _CreateCompatibleDC_Dart>(
          'CreateCompatibleDC');
      _createCompatibleBitmap = _gdi32!.lookupFunction<
          _CreateCompatibleBitmap_C,
          _CreateCompatibleBitmap_Dart>('CreateCompatibleBitmap');
      _selectObject = _gdi32!
          .lookupFunction<_SelectObject_C, _SelectObject_Dart>('SelectObject');
      _bitBlt = _gdi32!.lookupFunction<_BitBlt_C, _BitBlt_Dart>('BitBlt');
      _deleteDC =
          _gdi32!.lookupFunction<_DeleteDC_C, _DeleteDC_Dart>('DeleteDC');
      _deleteObject = _gdi32!
          .lookupFunction<_DeleteObject_C, _DeleteObject_Dart>('DeleteObject');
      _getDIBits =
          _gdi32!.lookupFunction<_GetDIBits_C, _GetDIBits_Dart>('GetDIBits');

      _getDC = _user32!.lookupFunction<_GetDC_C, _GetDC_Dart>('GetDC');
      _releaseDC =
          _user32!.lookupFunction<_ReleaseDC_C, _ReleaseDC_Dart>('ReleaseDC');
      _getSystemMetrics = _user32!
          .lookupFunction<_GetSystemMetrics_C, _GetSystemMetrics_Dart>(
          'GetSystemMetrics');

      _ffiReady = true;
      _captureMethod = 'ffi-win32';
      _ffiErrorReason = '';
      debugPrint('✅ FFI loaded: gdi32.dll + user32.dll');
    } catch (e) {
      _ffiReady = false;
      _captureMethod = 'flutter-fallback';
      _ffiErrorReason = 'FFI load failed: $e';
      debugPrint('❌ FFI load failed: $e');
    }
  }

  // ==================== ONE-TIME PERMISSION ====================
  Future<void> _checkAndRequestPermissionsIfNeeded() async {
    final prefs = await SharedPreferences.getInstance();
    final alreadyDone = prefs.getBool(_permSetupKey) ?? false;
    if (alreadyDone) return;
    if (!mounted) return;

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF16213E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.amber.withOpacity(0.15),
              ),
              child: const Icon(Icons.security, color: Colors.amber, size: 24),
            ),
            const SizedBox(width: 12),
            const Expanded(
              child: Text('One-Time Setup',
                  style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 18)),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Grow Logix needs permission to capture your screen. This is a ONE-TIME setup.',
              style: TextStyle(color: Colors.white70, fontSize: 13),
            ),
            const SizedBox(height: 16),
            _permBullet('Native Win32 FFI screen capture'),
            _permBullet('Continuous recording every 5 seconds'),
            _permBullet('Store frames for manager review'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await prefs.setBool(_permSetupKey, true);
            },
            child: const Text('Skip', style: TextStyle(color: Colors.white60)),
          ),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFE94560),
              shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            onPressed: () async {
              Navigator.pop(ctx);
              await _runPermissionSetup();
            },
            icon: const Icon(Icons.check, color: Colors.white, size: 20),
            label: const Text('Grant Permission',
                style: TextStyle(
                    color: Colors.white, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  Widget _permBullet(String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          const Icon(Icons.check_circle, color: Colors.greenAccent, size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text,
                style: TextStyle(
                    color: Colors.white.withOpacity(0.85), fontSize: 12)),
          ),
        ],
      ),
    );
  }

  Future<void> _runPermissionSetup() async {
    // ... your existing permission logic ...

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_permSetupKey, true);
    await prefs.setBool('is_first_launch', false); // ⭐ Mark first launch complete

    // Update window manager behavior for future hides
    if (Platform.isWindows) {
      await wm.windowManager.setSkipTaskbar(true);
    }

    // ... rest of your code ...
  }

  Future<void> _autoVerifyPcType(String pcType) async {
    try {
      final response = await http.post(
        Uri.parse('$liveStreamUrl?action=verify_pc_type'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({'emp_id': _employeeId, 'pc_type': pcType}),
      );
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data['status'] == 'success') {
          if (mounted) {
            setState(() {
              _pcType = pcType;
              _pcNumber = data['pc_number'] ??
                  (pcType == 'office' ? 'PC-01' : 'Personal PC');
            });
          }
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('pc_type', pcType);
          await prefs.setString('pc_number', _pcNumber ?? '');
        }
      }
    } catch (e) {
      debugPrint('Auto verify PC type error: $e');
    }
  }

  // ==================== HELPERS ====================
  void _updateActiveWindowTitle() {
    if (!Platform.isWindows) return;
    if (!_ffiReady) return;
    try {
      final hwnd = win32.GetForegroundWindow();
      if (hwnd == 0) return;
      final length = win32.GetWindowTextLength(hwnd);
      if (length == 0) return;

      final buffer = ffi_pkg.calloc<Uint16>(length + 1).cast<ffi_pkg.Utf16>();
      try {
        win32.GetWindowText(hwnd, buffer, length + 1);
        final title = buffer.toDartString();
        if (mounted && title != _activeWindowTitle) {
          setState(() => _activeWindowTitle = title);
        }
      } finally {
        ffi_pkg.calloc.free(buffer);
      }
    } catch (e) {
      debugPrint('Foreground window error: $e');
    }
  }

  Future<void> _loadInitialUserData() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _userId = prefs.getInt('user_id');
        _employeeName = prefs.getString('user_name') ?? 'Employee';
        _employeeId = prefs.getString('emp_id') ?? 'GS-E-00';
        _role = prefs.getString('user_role') ?? 'Employee';
        _email = prefs.getString('user_email') ?? '';
        _pcType = prefs.getString('pc_type') ?? 'office';
        _pcNumber = prefs.getString('pc_number') ?? 'PC-01';
      });
    }
    await _fetchEmployeeDetailsFromBackend();
  }

  Future<void> _fetchEmployeeDetailsFromBackend() async {
    try {
      final fetchUri = Uri.parse(
          '$baseUrl/manage_employee.php?emp_id=$_employeeId&user_id=${_userId ?? ''}');
      final response = await http.get(fetchUri,
          headers: {'Content-Type': 'application/json'});
      if (response.statusCode == 200) {
        final resData = jsonDecode(response.body);
        if (resData['status'] == 'success' && resData['data'] != null) {
          final currentUser = resData['data'];
          if (mounted) {
            setState(() {
              _employeeName = currentUser['name'] ?? _employeeName;
              _employeeId = currentUser['emp_id'] ?? _employeeId;
              _role = currentUser['role'] ?? _role;
              _email = currentUser['email'] ?? _email;
              _isFetchingEmployee = false;
            });
          }
        }
      }
    } catch (e) {
      debugPrint('Error fetching employee data: $e');
    } finally {
      if (mounted) setState(() => _isFetchingEmployee = false);
    }
  }

  // ==================== POLLING ====================
  void _startLiveRequestPolling() {
    _liveRequestTimer?.cancel();
    _liveRequestTimer = Timer.periodic(const Duration(seconds: 2), (timer) {
      if (!mounted) return;
      if (!_isLive) {
        _checkForLiveRequest();
      } else {
        _checkIfManagerStopped();
      }
    });
  }

  Future<void> _checkForLiveRequest() async {
    if (_employeeId.isEmpty || _employeeId == '---') return;
    try {
      final response = await http.get(
        Uri.parse('$liveStreamUrl?action=check_live_request&emp_id=$_employeeId'),
        headers: {'Accept': 'application/json'},
      );
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final status = data['status'] ?? 'idle';
        if (status == 'requested' && !_isLive) {
          debugPrint('🎬 Manager requested — AUTO-STARTING');
          _startLive();
        }
      }
    } catch (e) {
      debugPrint('Error checking live request: $e');
    }
  }

  Future<void> _checkIfManagerStopped() async {
    if (!_isLive || _employeeId.isEmpty) return;
    try {
      final response = await http.get(
        Uri.parse('$liveStreamUrl?action=check_live_request&emp_id=$_employeeId'),
        headers: {'Accept': 'application/json'},
      );
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final status = data['status'] ?? 'idle';
        if (status == 'idle' && _isLive) {
          debugPrint('🛑 Manager stopped — AUTO-STOPPING');
          _stopLiveByManager();
        }
      }
    } catch (e) {
      debugPrint('Error checking manager stop: $e');
    }
  }

  // ==================== LIVE STREAMING ====================
  void _startLive() {
    if (_isLive) return;
    setState(() {
      _isLive = true;
      _sessionStartTime = DateTime.now();
      _activeDuration = Duration.zero;
      _successfulUploads = 0;
      _failedUploads = 0;
      _isUploading = false;
      _lastCaptureError = '';
      _frameCounter = 0;
    });

    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted && _isLive) {
        setState(() {
          _activeDuration = DateTime.now().difference(_sessionStartTime!);
        });
      }
    });

    _startCaptureLoop();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
              '🔴 Continuous recording started — captures every 5 seconds'),
          backgroundColor: Colors.green,
          duration: Duration(seconds: 3),
        ),
      );
    }
  }

  void _stopLiveByManager() {
    if (!_isLive) return;
    _timer?.cancel();
    _frameUploadTimer?.cancel();
    _frameUploadTimer = null;

    setState(() {
      _isLive = false;
      _offlineDuration = _offlineDuration + _activeDuration;
    });

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
              'Manager stopped. $_successfulUploads frames captured, $_failedUploads failed.'),
          backgroundColor: const Color(0xFFE94560),
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  void _startCaptureLoop() {
    _frameUploadTimer?.cancel();
    _frameUploadTimer = null;

    debugPrint(
        '🎬 STARTING CAPTURE LOOP (interval: ${_captureIntervalMs}ms, method: $_captureMethod)');
    _captureAndUpload();

    _frameUploadTimer = Timer.periodic(
      const Duration(milliseconds: _captureIntervalMs),
          (timer) async {
        if (!mounted || !_isLive) {
          timer.cancel();
          return;
        }
        if (_isUploading) return;
        await _captureAndUpload();
      },
    );
  }

  Future<void> _captureAndUpload() async {
    if (!_isLive) return;
    if (_isUploading) return;

    _isUploading = true;
    _frameCounter++;
    final captureNum = _successfulUploads + 1;

    try {
      _updateActiveWindowTitle();

      String? frameData = await _captureWindowsDesktopFFI();

      if (frameData == null || frameData.isEmpty) {
        debugPrint('⚠️ FFI failed, using Flutter fallback');
        _captureMethod = 'flutter-fallback';
        frameData = await _captureFlutterWidget();
      }

      if (frameData == null || frameData.isEmpty) {
        _lastCaptureError = 'All capture methods failed';
        _failedUploads++;
        debugPrint('❌ No frame data captured');
        return;
      }

      final response = await http.post(
        Uri.parse('$liveStreamUrl?action=upload_screen_frame'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'emp_id': _employeeId,
          'image_base64': frameData,
          'save_history': true,
          'window_title': _activeWindowTitle,
          'pc_type': _pcType ?? 'office',
          'pc_number': _pcNumber ?? 'PC-01',
          'is_live_frame': true,
          'frame_counter': _frameCounter,
        }),
      ).timeout(const Duration(seconds: 60));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data['status'] == 'success') {
          _successfulUploads++;
          _lastCaptureError = '';
          debugPrint('✅ Frame #$captureNum uploaded');
          if (mounted) setState(() {});
        } else {
          _failedUploads++;
          _lastCaptureError = data['message'] ?? 'Server rejected';
          debugPrint('❌ Server rejected frame: ${data['message']}');
        }
      } else {
        _failedUploads++;
        _lastCaptureError = 'HTTP ${response.statusCode}';
        debugPrint('❌ HTTP ${response.statusCode}');
      }
    } catch (e) {
      _failedUploads++;
      _lastCaptureError = '$e';
      debugPrint('❌ Capture/upload error: $e');
    } finally {
      _isUploading = false;
    }
  }

  // ==================== PURE FFI WIN32 CAPTURE ====================
  Future<String?> _captureWindowsDesktopFFI() async {
    if (!Platform.isWindows) {
      _lastCaptureError = 'Not on Windows';
      return null;
    }
    if (!_ffiReady ||
        _getDC == null ||
        _getSystemMetrics == null ||
        _createCompatibleDC == null ||
        _createCompatibleBitmap == null ||
        _selectObject == null ||
        _bitBlt == null ||
        _getDIBits == null ||
        _deleteDC == null ||
        _deleteObject == null ||
        _releaseDC == null) {
      _lastCaptureError = _ffiErrorReason.isNotEmpty
          ? _ffiErrorReason
          : 'FFI functions not bound';
      return null;
    }

    Pointer<win32.BITMAPINFO>? bmi;
    Pointer<Uint8>? pixelData;
    int hdcScreen = 0;
    int hdcMem = 0;
    int hBitmap = 0;
    int hOld = 0;

    try {
      const SM_CXSCREEN = 0;
      const SM_CYSCREEN = 1;
      final width = _getSystemMetrics!(SM_CXSCREEN);
      final height = _getSystemMetrics!(SM_CYSCREEN);

      if (width <= 0 || height <= 0) {
        _lastCaptureError = 'Invalid screen size: ${width}x$height';
        return null;
      }

      hdcScreen = _getDC!(0);
      if (hdcScreen == 0) {
        _lastCaptureError = 'GetDC returned NULL';
        return null;
      }

      hdcMem = _createCompatibleDC!(hdcScreen);
      if (hdcMem == 0) {
        _lastCaptureError = 'CreateCompatibleDC failed';
        return null;
      }

      hBitmap = _createCompatibleBitmap!(hdcScreen, width, height);
      if (hBitmap == 0) {
        _lastCaptureError = 'CreateCompatibleBitmap failed';
        return null;
      }

      hOld = _selectObject!(hdcMem, hBitmap);

      const SRCCOPY = 0x00CC0020;
      final bitBltResult =
      _bitBlt!(hdcMem, 0, 0, width, height, hdcScreen, 0, 0, SRCCOPY);
      if (bitBltResult == 0) {
        _lastCaptureError = 'BitBlt failed';
        return null;
      }

      final bufSize = width * height * 4;
      pixelData = ffi_pkg.calloc<Uint8>(bufSize);

      bmi = ffi_pkg.calloc<win32.BITMAPINFO>();
      bmi.ref.bmiHeader.biSize = 40;
      bmi.ref.bmiHeader.biWidth = width;
      bmi.ref.bmiHeader.biHeight = -height;
      bmi.ref.bmiHeader.biPlanes = 1;
      bmi.ref.bmiHeader.biBitCount = 32;
      bmi.ref.bmiHeader.biCompression = 0;
      bmi.ref.bmiHeader.biSizeImage = bufSize;
      bmi.ref.bmiHeader.biXPelsPerMeter = 0;
      bmi.ref.bmiHeader.biYPelsPerMeter = 0;
      bmi.ref.bmiHeader.biClrUsed = 0;
      bmi.ref.bmiHeader.biClrImportant = 0;

      const DIB_RGB_COLORS = 0;
      final getDIBitsResult = _getDIBits!(
          hdcMem, hBitmap, 0, height, pixelData, bmi, DIB_RGB_COLORS);

      if (getDIBitsResult == 0) {
        _lastCaptureError = 'GetDIBits failed';
        return null;
      }

      final pixels = pixelData.asTypedList(bufSize);
      for (int i = 0; i < bufSize; i += 4) {
        final b = pixels[i];
        final g = pixels[i + 1];
        final r = pixels[i + 2];
        pixels[i] = r;
        pixels[i + 1] = g;
        pixels[i + 2] = b;
        pixels[i + 3] = 255;
      }

      final imageB64 = await _encodeRawRgbaToPng(pixels, width, height);
      _captureMethod = 'ffi-win32';
      _lastCaptureError = '';
      return imageB64;
    } catch (e, stack) {
      _lastCaptureError = 'FFI: $e';
      debugPrint('FFI capture error: $e\n$stack');
      return null;
    } finally {
      try {
        if (hOld != 0 && hdcMem != 0) _selectObject?.call(hdcMem, hOld);
        if (hBitmap != 0) _deleteObject?.call(hBitmap);
        if (hdcMem != 0) _deleteDC?.call(hdcMem);
        if (hdcScreen != 0) _releaseDC?.call(0, hdcScreen);
      } catch (_) {}
      if (pixelData != null) ffi_pkg.calloc.free(pixelData);
      if (bmi != null) ffi_pkg.calloc.free(bmi);
    }
  }

  Future<String> _encodeRawRgbaToPng(
      Uint8List rgba, int width, int height) async {
    final completer = Completer<ui.Image>();

    ui.decodeImageFromPixels(
      rgba,
      width,
      height,
      ui.PixelFormat.rgba8888,
          (ui.Image image) {
        if (!completer.isCompleted) completer.complete(image);
      },
    );

    final image = await completer.future;
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();

    if (byteData == null) {
      throw Exception('PNG encoding failed');
    }
    return base64Encode(byteData.buffer.asUint8List());
  }

  Future<String?> _captureFlutterWidget() async {
    try {
      final RenderRepaintBoundary? boundary =
      _repaintKey.currentContext?.findRenderObject()
      as RenderRepaintBoundary?;
      if (boundary == null) return _generateFallbackPngBase64();
      await Future.delayed(const Duration(milliseconds: 20));
      final ui.Image image = await boundary.toImage(pixelRatio: 0.5);
      final ByteData? byteData =
      await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) return _generateFallbackPngBase64();
      return base64Encode(byteData.buffer.asUint8List());
    } catch (e) {
      return _generateFallbackPngBase64();
    }
  }

  String _generateFallbackPngBase64() {
    return "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=";
  }

  String _formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);
    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  Future<void> _logout() async {
    if (_isLive) {
      try {
        await http.post(
          Uri.parse('$liveStreamUrl?action=stop_live_stream'),
          headers: {'Content-Type': 'application/json'},
          body: json.encode({'emp_id': _employeeId, 'keep_history': true}),
        );
      } catch (_) {}
    }

    await _sendShutdown();
    _heartbeatTimer?.cancel();

    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();

    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (context) => const LogIn()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final isTablet = size.width > 600;

    return Focus(
      focusNode: _rootFocusNode,
      autofocus: false,
      descendantsAreFocusable: false,
      descendantsAreTraversable: false,
      child: Scaffold(
        body: Stack(
          children: [
            RepaintBoundary(
              key: _repaintKey,
              child: Container(
                width: double.infinity,
                height: double.infinity,
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Color(0xFF1A1A2E),
                      Color(0xFF16213E),
                      Color(0xFF0F3460)
                    ],
                    stops: [0.0, 0.5, 1.0],
                  ),
                ),
                child: SafeArea(
                  child: Column(
                    children: [
                      _buildAppBar(),
                      Expanded(
                        child: Center(
                          child: SingleChildScrollView(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 16.0, vertical: 16.0),
                            child: ConstrainedBox(
                              constraints: BoxConstraints(
                                  maxWidth: isTablet ? 600 : double.infinity),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  _buildProfileCard(),
                                  const SizedBox(height: 24),
                                  _buildScreenPreview(),
                                  const SizedBox(height: 24),
                                  _buildSessionStats(),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (_isLive) _buildYellowHighlightOverlay(),
          ],
        ),
      ),
    );
  }

  Widget _buildYellowHighlightOverlay() {
    return IgnorePointer(
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(color: Colors.yellow.withOpacity(0.8), width: 3),
          boxShadow: [
            BoxShadow(
                color: Colors.yellow.withOpacity(0.3),
                blurRadius: 20,
                spreadRadius: 2),
          ],
        ),
      ),
    );
  }

  Widget _buildAppBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: const LinearGradient(
                  colors: [Color(0xFFE94560), Color(0xFF903749)]),
              boxShadow: [
                BoxShadow(
                    color: const Color(0xFFE94560).withOpacity(0.4),
                    blurRadius: 12,
                    spreadRadius: 1),
              ],
            ),
            child:
            const Icon(Icons.person_outline, color: Colors.white, size: 24),
          ),
          const SizedBox(width: 16),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Employee Dashboard',
                    style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                        letterSpacing: 0.5)),
                SizedBox(height: 2),
                Text('Continuous recording active',
                    style: TextStyle(fontSize: 13, color: Colors.white54)),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              color: _isLive
                  ? Colors.greenAccent.withOpacity(0.15)
                  : Colors.white.withOpacity(0.08),
              border: Border.all(
                color: _isLive
                    ? Colors.greenAccent.withOpacity(0.5)
                    : Colors.white.withOpacity(0.15),
                width: 1,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _isLive ? Colors.greenAccent : Colors.white38),
                ),
                const SizedBox(width: 6),
                Text(
                  _isLive ? 'RECORDING' : 'IDLE',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1,
                    color: _isLive ? Colors.greenAccent : Colors.white54,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          InkWell(
            onTap: _logout,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                color: const Color(0xFFE94560).withOpacity(0.15),
                border: Border.all(
                    color: const Color(0xFFE94560).withOpacity(0.4),
                    width: 1),
              ),
              child: const Icon(Icons.logout_outlined,
                  size: 20, color: Color(0xFFE94560)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildProfileCard() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.08),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withOpacity(0.1), width: 1),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withOpacity(0.2),
              blurRadius: 10,
              offset: const Offset(0, 4)),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 60,
            height: 60,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: const LinearGradient(
                  colors: [Color(0xFFE94560), Color(0xFF903749)]),
              boxShadow: [
                BoxShadow(
                    color: const Color(0xFFE94560).withOpacity(0.3),
                    blurRadius: 12,
                    spreadRadius: 1),
              ],
            ),
            child: Center(
              child: Text(
                _employeeName.isNotEmpty
                    ? _employeeName[0].toUpperCase()
                    : '?',
                style: const TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.bold,
                    color: Colors.white),
              ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_employeeName,
                    style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Colors.white)),
                const SizedBox(height: 4),
                Text(_role,
                    style: const TextStyle(
                        fontSize: 13,
                        color: Color(0xFFE94560),
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Icon(Icons.badge_outlined,
                        size: 14, color: Colors.white.withOpacity(0.5)),
                    const SizedBox(width: 6),
                    Text(_employeeId,
                        style: TextStyle(
                            fontSize: 12,
                            color: Colors.white.withOpacity(0.7),
                            fontWeight: FontWeight.w500)),
                    if (_pcNumber != null) ...[
                      const SizedBox(width: 12),
                      Icon(
                        _pcType == 'office'
                            ? Icons.computer
                            : Icons.laptop_mac,
                        size: 14,
                        color: _pcType == 'office'
                            ? Colors.greenAccent
                            : Colors.lightBlueAccent,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        _pcNumber!,
                        style: TextStyle(
                          fontSize: 12,
                          color: _pcType == 'office'
                              ? Colors.greenAccent
                              : Colors.lightBlueAccent,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildScreenPreview() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: _isLive
              ? [
            const Color(0xFF0F3460).withOpacity(0.8),
            const Color(0xFF1A1A2E).withOpacity(0.9)
          ]
              : [
            Colors.black.withOpacity(0.5),
            const Color(0xFF0F3460).withOpacity(0.3)
          ],
        ),
        border: Border.all(
          color: _isLive
              ? Colors.yellow.withOpacity(0.6)
              : Colors.white.withOpacity(0.1),
          width: 2,
        ),
        boxShadow: _isLive
            ? [
          BoxShadow(
              color: Colors.yellow.withOpacity(0.2),
              blurRadius: 20,
              spreadRadius: 2)
        ]
            : [
          BoxShadow(
              color: Colors.black.withOpacity(0.3),
              blurRadius: 10,
              offset: const Offset(0, 4))
        ],
      ),
      child: Stack(
        children: [
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 70,
                height: 70,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _isLive
                      ? Colors.yellow.withOpacity(0.15)
                      : Colors.white.withOpacity(0.05),
                  border: Border.all(
                    color: _isLive
                        ? Colors.yellow.withOpacity(0.6)
                        : Colors.white.withOpacity(0.15),
                    width: 2,
                  ),
                ),
                child: Icon(
                  _isLive
                      ? Icons.desktop_windows
                      : Icons.desktop_access_disabled,
                  size: 36,
                  color:
                  _isLive ? Colors.yellow : Colors.white.withOpacity(0.4),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                _isLive
                    ? 'Continuous Recording Active'
                    : 'Waiting for Manager...',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: _isLive ? Colors.white : Colors.white.withOpacity(0.6),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                _isLive
                    ? 'Frames: $_successfulUploads  •  Failed: $_failedUploads  •  Every ${(_captureIntervalMs / 1000).toInt()}s  •  $_captureMethod'
                    : 'Recording starts AUTOMATICALLY when manager requests',
                textAlign: TextAlign.center,
                style:
                TextStyle(fontSize: 13, color: Colors.white.withOpacity(0.5)),
              ),
              if (_isLive && _lastCaptureError.isNotEmpty) ...[
                const SizedBox(height: 8),
                Container(
                  padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.red.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(8),
                    border:
                    Border.all(color: Colors.red.withOpacity(0.5), width: 1.5),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.error_outline,
                          color: Colors.redAccent, size: 14),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          _lastCaptureError,
                          style: const TextStyle(
                              color: Colors.redAccent,
                              fontSize: 10,
                              fontWeight: FontWeight.bold),
                          overflow: TextOverflow.ellipsis,
                          maxLines: 2,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              if (_isLive && _activeWindowTitle != 'Unknown') ...[
                const SizedBox(height: 8),
                Container(
                  padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.yellow.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                        color: Colors.yellow.withOpacity(0.5), width: 1.5),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.border_color,
                          color: Colors.yellow, size: 14),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          'Active: $_activeWindowTitle',
                          style: const TextStyle(
                              color: Colors.yellow,
                              fontSize: 11,
                              fontWeight: FontWeight.bold),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
          if (_isLive)
            Positioned(
              top: 0,
              left: 0,
              child: Container(
                padding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.redAccent.withOpacity(0.9),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.circle, color: Colors.white, size: 8),
                    SizedBox(width: 6),
                    Text('RECORDING',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 1)),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSessionStats() {
    return Row(
      children: [
        Expanded(
          child: _buildStatCard(
            icon: Icons.timer_outlined,
            label: 'Active Time',
            value: _formatDuration(_activeDuration),
            color: Colors.greenAccent,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _buildStatCard(
            icon: Icons.timer_off_outlined,
            label: 'Offline Time',
            value: _formatDuration(_offlineDuration),
            color: const Color(0xFFE94560),
          ),
        ),
      ],
    );
  }

  Widget _buildStatCard({
    required IconData icon,
    required String label,
    required String value,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withOpacity(0.3), width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                    shape: BoxShape.circle, color: color.withOpacity(0.15)),
                child: Icon(icon, size: 16, color: color),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(label,
                    style: TextStyle(
                        fontSize: 12,
                        color: Colors.white.withOpacity(0.6),
                        fontWeight: FontWeight.w500)),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(value,
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: color,
                fontFeatures: const [FontFeature.tabularFigures()],
              )),
        ],
      ),
    );
  }
}
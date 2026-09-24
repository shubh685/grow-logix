import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:win32/win32.dart';

import 'Log_In.dart';

class EmpDashboard extends StatefulWidget {
  const EmpDashboard({super.key});

  @override
  State<EmpDashboard> createState() => _EmpDashboardState();
}

class _EmpDashboardState extends State<EmpDashboard> {
  static const String baseUrl = 'http://192.168.1.42/grow_logix';
  static const String liveStreamUrl = '$baseUrl/live_stream.php';

  // ==================== SETTINGS ====================
  static const int _captureIntervalMs = 60000; // ⭐ EVERY 1 MINUTE (60000ms)
  static const int _jpegQuality = 55;
  static const int _maxWidth = 1366;
  static const String _permSetupKey = 'screen_perm_setup_done_v1';

  bool _isLive = false;
  DateTime? _sessionStartTime;
  DateTime? _sessionEndTime;
  Duration _activeDuration = Duration.zero;
  Duration _offlineDuration = Duration.zero;
  Timer? _timer;
  Timer? _liveRequestTimer;
  Timer? _frameUploadTimer;
  Timer? _activeWindowTimer;

  String _employeeName = 'Loading...';
  String _employeeId = '---';
  String _role = 'Employee';
  String _email = '';
  int? _userId;
  String _deviceId = 'Loading...';
  bool _isFetchingEmployee = true;

  String _liveRequestStatus = 'idle';
  bool _showLiveRequestDialog = false;
  int _framesUploaded = 0;
  int _successfulUploads = 0;
  bool _isUploading = false;
  String _activeWindowTitle = 'Unknown';
  String _captureMethod = 'none';
  int _consecutiveFailures = 0;

  // PC Type verification
  String? _pcType;
  String? _pcNumber;
  bool _showPcVerificationDialog = false;

  final GlobalKey _repaintKey = GlobalKey();
  int? _cachedForegroundHwnd;
  String? _cachedPsScriptPath;
  String _lastCaptureError = '';

  @override
  void initState() {
    super.initState();
    _offlineDuration = const Duration(minutes: 12, seconds: 45);
    _loadInitialUserData();
    _startLiveRequestPolling();

    _activeWindowTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted && _isLive) _updateActiveWindowTitle();
    });

    // ⭐ Check permission ONCE on app startup
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkAndRequestPermissionsIfNeeded();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _liveRequestTimer?.cancel();
    _frameUploadTimer?.cancel();
    _activeWindowTimer?.cancel();

    if (_cachedPsScriptPath != null) {
      try {
        File(_cachedPsScriptPath!).deleteSync();
      } catch (_) {}
    }
    super.dispose();
  }

  // ==================== ONE-TIME PERMISSION SETUP ====================
  Future<void> _checkAndRequestPermissionsIfNeeded() async {
    final prefs = await SharedPreferences.getInstance();
    final alreadyDone = prefs.getBool(_permSetupKey) ?? false;

    if (alreadyDone) {
      debugPrint('✅ Permission setup already completed — skipping');
      return;
    }

    if (!mounted) return;

    // ⭐ Show one-time setup dialog
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
              'Grow Logix needs permission to capture your screen for monitoring. This is a ONE-TIME setup.',
              style: TextStyle(color: Colors.white70, fontSize: 13),
            ),
            const SizedBox(height: 16),
            _permBullet('Screen capture access'),
            _permBullet('Run PowerShell for native capture'),
            _permBullet('Access temp folder for images'),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.blue.withOpacity(0.1),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.blue.withOpacity(0.3)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.info_outline, color: Colors.blueAccent, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'You will NOT be asked again. Manager controls when recording starts/stops.',
                      style: TextStyle(
                          color: Colors.white.withOpacity(0.8), fontSize: 11),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              // Mark as done even if declined (to avoid nagging)
              await prefs.setBool(_permSetupKey, true);
            },
            child: const Text('Skip', style: TextStyle(color: Colors.white60)),
          ),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFE94560),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
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
    bool allOk = true;
    final List<String> results = [];

    try {
      // 1. Request storage permission (may not apply on Windows but safe)
      if (Platform.isAndroid || Platform.isIOS) {
        final storageStatus = await Permission.storage.request();
        final photosStatus = await Permission.photos.request();
        results.add('Storage: ${storageStatus.isGranted}');
        results.add('Photos: ${photosStatus.isGranted}');
      } else {
        results.add('Storage: Platform-managed (Windows)');
      }

      // 2. Test PowerShell access
      try {
        final psResult = await Process.run(
          'powershell.exe',
          ['-Command', 'Write-Output "OK"'],
          runInShell: false,
        ).timeout(const Duration(seconds: 10));

        if (psResult.exitCode == 0 &&
            psResult.stdout.toString().contains('OK')) {
          results.add('PowerShell: ✅ OK');
        } else {
          results.add('PowerShell: ❌ Failed');
          allOk = false;
        }
      } catch (e) {
        results.add('PowerShell: ❌ $e');
        allOk = false;
      }

      // 3. Test temp folder write
      try {
        final tempDir = await getTemporaryDirectory();
        final testFile = File('${tempDir.path}\\perm_test.txt');
        await testFile.writeAsString('test');
        await testFile.delete();
        results.add('Temp folder: ✅ OK');
      } catch (e) {
        results.add('Temp folder: ❌ $e');
        allOk = false;
      }

      // 4. Test basic screen capture
      try {
        final captureTest = await _captureWindowsDesktopWin32();
        if (captureTest != null && captureTest.isNotEmpty) {
          results.add('Screen capture: ✅ OK');
        } else {
          results.add('Screen capture: ❌ Failed');
          allOk = false;
        }
      } catch (e) {
        results.add('Screen capture: ❌ $e');
        allOk = false;
      }

      // Save completion flag
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_permSetupKey, true);

      // Show result
      if (mounted) {
        await showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: const Color(0xFF16213E),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20)),
            title: Row(
              children: [
                Icon(
                  allOk ? Icons.check_circle : Icons.warning_amber,
                  color: allOk ? Colors.greenAccent : Colors.amber,
                  size: 24,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    allOk ? 'Setup Complete' : 'Setup Completed with Warnings',
                    style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 16),
                  ),
                ),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: results
                  .map((r) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Text(r,
                    style: const TextStyle(
                        color: Colors.white70, fontSize: 12)),
              ))
                  .toList(),
            ),
            actions: [
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFE94560),
                ),
                onPressed: () => Navigator.pop(ctx),
                child: const Text('OK',
                    style: TextStyle(color: Colors.white)),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      debugPrint('Permission setup error: $e');
    }
  }

  // ==================== EXISTING HELPERS ====================
  void _updateActiveWindowTitle() {
    if (!Platform.isWindows) return;
    try {
      final hwnd = GetForegroundWindow();
      if (hwnd == 0) return;

      final length = GetWindowTextLength(hwnd);
      if (length == 0) return;

      final buffer = wsalloc(length + 1);
      GetWindowText(hwnd, buffer, length + 1);
      final title = buffer.toDartString();
      free(buffer);

      _cachedForegroundHwnd = hwnd;

      if (mounted && title != _activeWindowTitle) {
        setState(() => _activeWindowTitle = title);
      }
    } catch (e) {
      debugPrint('Foreground window error: $e');
    }
  }

  Future<void> _loadInitialUserData() async {
    final prefs = await SharedPreferences.getInstance();

    setState(() {
      _userId = prefs.getInt('user_id');
      _employeeName = prefs.getString('user_name') ?? 'Employee';
      _employeeId = prefs.getString('emp_id') ?? 'GS-E-00';
      _role = prefs.getString('user_role') ?? 'Employee';
      _email = prefs.getString('user_email') ?? '';
      _deviceId = prefs.getString('device_id') ?? 'Loading...';
      _pcType = prefs.getString('pc_type');
      _pcNumber = prefs.getString('pc_number');
    });

    await _fetchEmployeeDetailsFromBackend();
  }

  Future<void> _fetchEmployeeDetailsFromBackend() async {
    try {
      final Uri fetchUri = Uri.parse(
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

        if (status == 'requested' &&
            !_showLiveRequestDialog &&
            !_showPcVerificationDialog &&
            mounted) {
          _liveRequestStatus = status;
          _showLiveRequestDialog = true;
          _showIncomingLiveRequestDialog();
        } else if (status == 'idle' && _liveRequestStatus != 'idle') {
          setState(() => _liveRequestStatus = 'idle');
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
          debugPrint('Manager stopped the stream — auto-stopping');
          _stopLiveByManager();
        }
      }
    } catch (e) {
      debugPrint('Error checking manager stop: $e');
    }
  }

  // ==================== PC VERIFICATION ====================
  void _showPcVerificationQuestion() {
    if (!mounted) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF16213E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.blueAccent.withOpacity(0.15),
              ),
              child: const Icon(Icons.computer, color: Colors.blueAccent, size: 24),
            ),
            const SizedBox(width: 12),
            const Expanded(
              child: Text('PC Type Verification',
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
            const Text('Are you using an Office PC or Personal PC?',
                style: TextStyle(color: Colors.white70, fontSize: 14)),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.05),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white.withOpacity(0.1)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.info_outline, color: Colors.amber, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'This helps us assign the correct PC number for monitoring.',
                      style: TextStyle(
                          color: Colors.white.withOpacity(0.7), fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton.icon(
            onPressed: () {
              Navigator.pop(context);
              _showPcVerificationDialog = false;
              _verifyPcType('personal');
            },
            icon: const Icon(Icons.laptop_mac,
                color: Colors.lightBlueAccent, size: 20),
            label: const Text('Personal PC',
                style: TextStyle(color: Colors.lightBlueAccent)),
          ),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFE94560),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
            onPressed: () {
              Navigator.pop(context);
              _showPcVerificationDialog = false;
              _verifyPcType('office');
            },
            icon: const Icon(Icons.computer, color: Colors.white, size: 20),
            label: const Text('Office PC',
                style: TextStyle(
                    color: Colors.white, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  Future<void> _verifyPcType(String pcType) async {
    try {
      final response = await http.post(
        Uri.parse('$liveStreamUrl?action=verify_pc_type'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'emp_id': _employeeId,
          'pc_type': pcType,
        }),
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data['status'] == 'success') {
          setState(() {
            _pcType = pcType;
            _pcNumber = data['pc_number'] ??
                (pcType == 'office' ? 'PC-01' : 'Personal PC');
          });

          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('pc_type', pcType);
          await prefs.setString('pc_number', _pcNumber ?? '');

          if (mounted && _liveRequestStatus == 'requested') {
            _showIncomingLiveRequestDialog();
          }
        }
      }
    } catch (e) {
      debugPrint('Error verifying PC type: $e');
      setState(() {
        _pcType = pcType;
        _pcNumber = pcType == 'office' ? 'PC-01' : 'Personal PC';
      });
    }
  }

  void _showIncomingLiveRequestDialog() {
    if (!mounted) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF16213E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.greenAccent.withOpacity(0.15),
              ),
              child: const Icon(Icons.videocam,
                  color: Colors.greenAccent, size: 24),
            ),
            const SizedBox(width: 12),
            const Expanded(
              child: Text('Live Screen Request',
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
            const Text('Your manager wants to view your FULL DESKTOP screen.',
                style: TextStyle(color: Colors.white70, fontSize: 14)),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.05),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white.withOpacity(0.1)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.info_outline,
                          color: Colors.amber, size: 18),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Screen will be captured EVERY 1 MINUTE and saved. Manager controls start/stop.',
                          style: TextStyle(
                              color: Colors.white.withOpacity(0.7),
                              fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Icon(
                        _pcType == 'office'
                            ? Icons.computer
                            : Icons.laptop_mac,
                        color: _pcType == 'office'
                            ? Colors.greenAccent
                            : Colors.lightBlueAccent,
                        size: 16,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'Device: ${_pcNumber ?? "Unknown"}',
                        style: TextStyle(
                          color: _pcType == 'office'
                              ? Colors.greenAccent
                              : Colors.lightBlueAccent,
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              _showLiveRequestDialog = false;
              setState(() => _liveRequestStatus = 'idle');
              await _declineLiveRequest();
            },
            child:
            const Text('Decline', style: TextStyle(color: Colors.white60)),
          ),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFE94560),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
            onPressed: () {
              Navigator.pop(context);
              _showLiveRequestDialog = false;
              _acceptLiveRequest();
            },
            icon: const Icon(Icons.play_arrow, color: Colors.white, size: 20),
            label: const Text('Accept & Go Live',
                style: TextStyle(
                    color: Colors.white, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  Future<void> _declineLiveRequest() async {
    try {
      await http.post(
        Uri.parse('$liveStreamUrl?action=stop_live_stream'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({'emp_id': _employeeId}),
      );
      _liveRequestStatus = 'idle';
    } catch (e) {
      debugPrint('Error declining live request: $e');
    }
  }

  void _acceptLiveRequest() {
    if (_pcType == null) {
      _showPcVerificationDialog = true;
      _showPcVerificationQuestion();
    } else {
      _startLive();
    }
  }

  // ==================== LIVE STREAMING (Employee — AUTO START ONLY) ====================
  void _startLive() {
    if (_isLive) return;

    setState(() {
      _isLive = true;
      _sessionStartTime = DateTime.now();
      _sessionEndTime = null;
      _activeDuration = Duration.zero;
      _liveRequestStatus = 'streaming';
      _framesUploaded = 0;
      _successfulUploads = 0;
      _isUploading = false;
      _consecutiveFailures = 0;
      _lastCaptureError = '';
    });

    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted && _isLive) {
        setState(() {
          _activeDuration = DateTime.now().difference(_sessionStartTime!);
        });
      }
    });

    _startRealTimeCaptureLoop();

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('🔴 Screen recording started — captures every 1 minute'),
        backgroundColor: Colors.green,
        duration: Duration(seconds: 3),
      ),
    );
  }

  /// ⭐ Called ONLY when manager stops (from polling)
  void _stopLiveByManager() {
    if (!_isLive) return;

    _timer?.cancel();
    _frameUploadTimer?.cancel();

    setState(() {
      _isLive = false;
      _sessionEndTime = DateTime.now();
      _offlineDuration = _offlineDuration + _activeDuration;
      _liveRequestStatus = 'idle';
    });

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
              'Manager stopped the stream. $_successfulUploads frames saved.'),
          backgroundColor: const Color(0xFFE94560),
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  // ==================== EVERY-MINUTE CAPTURE LOOP ====================
  void _startRealTimeCaptureLoop() {
    _frameUploadTimer?.cancel();

    // ⭐ Immediate first capture
    _captureAndUpload();

    // ⭐ Then EVERY 1 MINUTE
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
    if (!_isLive || _isUploading) return;
    _isUploading = true;

    try {
      _updateActiveWindowTitle();

      final String? frameData = await _captureFullDesktop();

      if (frameData == null || frameData.isEmpty) {
        _consecutiveFailures++;
        debugPrint(
            'Screen capture empty (failures: $_consecutiveFailures) — $_lastCaptureError');
        return;
      }

      _consecutiveFailures = 0;

      // ⭐ ALWAYS save to history (every 1 min capture = 1 history frame)
      final response = await http
          .post(
        Uri.parse('$liveStreamUrl?action=upload_screen_frame'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'emp_id': _employeeId,
          'image_base64': frameData,
          'save_history': true, // ALWAYS save (every-minute frames)
          'window_title': _activeWindowTitle,
          'pc_type': _pcType ?? 'personal',
          'pc_number': _pcNumber ?? 'Personal PC',
          'is_live_frame': true,
        }),
      )
          .timeout(const Duration(seconds: 20));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data['status'] == 'success') {
          _successfulUploads++;
          _framesUploaded++;
          if (mounted) setState(() {});
        }
      }
    } catch (e) {
      _consecutiveFailures++;
      debugPrint('Capture/upload error (#$_consecutiveFailures): $e');
    } finally {
      _isUploading = false;
    }
  }

  Future<String?> _captureFullDesktop() async {
    if (Platform.isWindows) {
      final nativeResult = await _captureWindowsDesktopWin32();
      if (nativeResult != null && nativeResult.isNotEmpty) {
        return nativeResult;
      }
      debugPrint('⚠️ Native capture FAILED: $_lastCaptureError');
    }

    if (Platform.isMacOS) return await _captureMacDesktop();
    if (Platform.isLinux) return await _captureLinuxDesktop();

    _captureMethod = 'flutter-fallback';
    return await _captureFlutterWidget();
  }

  Future<String?> _captureWindowsDesktopWin32() async {
    try {
      final tempDir = await getTemporaryDirectory();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final tempPath = '${tempDir.path}\\screen_$timestamp.jpg';
      final scriptPath = '${tempDir.path}\\capture_$timestamp.ps1';
      final tempPathEscaped = tempPath.replaceAll('\\', '\\\\');

      final psScript = '''
\$ErrorActionPreference = "Stop"
try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class NativeWin32 {
    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
    [DllImport("user32.dll")]
    public static extern int GetWindowTextLength(IntPtr hWnd);
    [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    public static extern int GetWindowText(IntPtr hWnd, System.Text.StringBuilder lpString, int nMaxCount);
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }
}
"@

    \$screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    \$screenWidth = \$screen.Width
    \$screenHeight = \$screen.Height

    \$targetWidth = $_maxWidth
    \$scale = 1.0
    if (\$screenWidth -gt \$targetWidth) {
        \$scale = \$targetWidth / \$screenWidth
    }
    \$newWidth = [int](\$screenWidth * \$scale)
    \$newHeight = [int](\$screenHeight * \$scale)

    \$bitmap = New-Object System.Drawing.Bitmap \$screenWidth, \$screenHeight
    \$graphics = [System.Drawing.Graphics]::FromImage(\$bitmap)
    \$graphics.CopyFromScreen(\$screen.X, \$screen.Y, 0, 0, \$bitmap.Size)

    \$hwnd = [NativeWin32]::GetForegroundWindow()

    if (\$hwnd -ne [IntPtr]::Zero) {
        \$rect = New-Object NativeWin32+RECT
        [NativeWin32]::GetWindowRect(\$hwnd, [ref]\$rect) | Out-Null

        \$windowWidth = \$rect.Right - \$rect.Left
        \$windowHeight = \$rect.Bottom - \$rect.Top

        \$pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::Yellow), 5
        \$graphics.DrawRectangle(\$pen, \$rect.Left, \$rect.Top, \$windowWidth, \$windowHeight)

        \$cs = 25
        \$cpen = New-Object System.Drawing.Pen ([System.Drawing.Color]::Yellow), 8
        \$graphics.DrawLine(\$cpen, \$rect.Left, \$rect.Top, \$rect.Left + \$cs, \$rect.Top)
        \$graphics.DrawLine(\$cpen, \$rect.Left, \$rect.Top, \$rect.Left, \$rect.Top + \$cs)
        \$graphics.DrawLine(\$cpen, \$rect.Right - \$cs, \$rect.Top, \$rect.Right, \$rect.Top)
        \$graphics.DrawLine(\$cpen, \$rect.Right, \$rect.Top, \$rect.Right, \$rect.Top + \$cs)
        \$graphics.DrawLine(\$cpen, \$rect.Left, \$rect.Bottom - \$cs, \$rect.Left, \$rect.Bottom)
        \$graphics.DrawLine(\$cpen, \$rect.Left, \$rect.Bottom, \$rect.Left + \$cs, \$rect.Bottom)
        \$graphics.DrawLine(\$cpen, \$rect.Right - \$cs, \$rect.Bottom, \$rect.Right, \$rect.Bottom)
        \$graphics.DrawLine(\$cpen, \$rect.Right, \$rect.Bottom - \$cs, \$rect.Right, \$rect.Bottom)

        \$titleLength = [NativeWin32]::GetWindowTextLength(\$hwnd)
        \$title = ""
        if (\$titleLength -gt 0) {
            \$sb = New-Object System.Text.StringBuilder (\$titleLength + 1)
            [NativeWin32]::GetWindowText(\$hwnd, \$sb, \$sb.Capacity) | Out-Null
            \$title = \$sb.ToString()
        }

        if (\$title.Length -gt 0) {
            \$tfont = New-Object System.Drawing.Font("Arial", 12, [System.Drawing.FontStyle]::Bold)
            \$tbg = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(220, 0, 0, 0))
            \$tfg = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::Yellow)
            if (\$title.Length -gt 70) { \$title = \$title.Substring(0, 67) + "..." }
            \$tsize = \$graphics.MeasureString(\$title, \$tfont)
            \$tx = [Math]::Max(0, \$rect.Left)
            \$ty = [Math]::Max(0, \$rect.Top - 35)
            \$graphics.FillRectangle(\$tbg, \$tx, \$ty, \$tsize.Width + 20, \$tsize.Height + 10)
            \$graphics.DrawString(\$title, \$tfont, \$tfg, \$tx + 10, \$ty + 5)
        }
        
        \$pen.Dispose()
        \$cpen.Dispose()
    }

    \$rfont = New-Object System.Drawing.Font("Arial", 16, [System.Drawing.FontStyle]::Bold)
    \$rbg = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(230, 220, 38, 38))
    \$rfg = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::White)
    \$rtext = "● RECORDING"
    \$rsize = \$graphics.MeasureString(\$rtext, \$rfont)
    \$rx = \$screenWidth - \$rsize.Width - 40
    \$ry = 20
    \$graphics.FillRectangle(\$rbg, \$rx, \$ry, \$rsize.Width + 20, \$rsize.Height + 10)
    \$graphics.DrawString(\$rtext, \$rfont, \$rfg, \$rx + 10, \$ry + 5)

    \$tifont = New-Object System.Drawing.Font("Arial", 12, [System.Drawing.FontStyle]::Bold)
    \$tibg = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(220, 0, 0, 0))
    \$tifg = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::White)
    \$titext = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    \$tisize = \$graphics.MeasureString(\$titext, \$tifont)
    \$graphics.FillRectangle(\$tibg, 20, \$screenHeight - \$tisize.Height - 30, \$tisize.Width + 20, \$tisize.Height + 10)
    \$graphics.DrawString(\$titext, \$tifont, \$tifg, 30, \$screenHeight - \$tisize.Height - 25)

    if (\$scale -lt 1.0) {
        \$smallBitmap = New-Object System.Drawing.Bitmap \$newWidth, \$newHeight
        \$smallGraphics = [System.Drawing.Graphics]::FromImage(\$smallBitmap)
        \$smallGraphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        \$smallGraphics.DrawImage(\$bitmap, 0, 0, \$newWidth, \$newHeight)
        
        \$jpegCodec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { \$_.MimeType -eq "image/jpeg" }
        \$encoderParams = New-Object System.Drawing.Imaging.EncoderParameters(1)
        \$encoderParams.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter([System.Drawing.Imaging.Encoder]::Quality, [long]$_jpegQuality)
        \$smallBitmap.Save("$tempPathEscaped", \$jpegCodec, \$encoderParams)
        
        \$smallGraphics.Dispose()
        \$smallBitmap.Dispose()
    } else {
        \$jpegCodec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { \$_.MimeType -eq "image/jpeg" }
        \$encoderParams = New-Object System.Drawing.Imaging.EncoderParameters(1)
        \$encoderParams.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter([System.Drawing.Imaging.Encoder]::Quality, [long]$_jpegQuality)
        \$bitmap.Save("$tempPathEscaped", \$jpegCodec, \$encoderParams)
    }

    \$graphics.Dispose()
    \$bitmap.Dispose()

    Write-Output "SUCCESS"
} catch {
    Write-Error \$_.Exception.Message
    exit 1
}
''';

      final scriptFile = File(scriptPath);
      await scriptFile.writeAsString(psScript);

      final result = await Process.run(
        'powershell.exe',
        [
          '-ExecutionPolicy',
          'Bypass',
          '-NoProfile',
          '-NonInteractive',
          '-WindowStyle',
          'Hidden',
          '-File',
          scriptPath,
        ],
        runInShell: false,
      ).timeout(const Duration(seconds: 20));

      try {
        await scriptFile.delete();
      } catch (_) {}

      if (result.exitCode == 0) {
        final file = File(tempPath);
        if (await file.exists()) {
          final bytes = await file.readAsBytes();
          try {
            await file.delete();
          } catch (_) {}

          if (bytes.isNotEmpty) {
            _captureMethod = 'win32-jpeg-native';
            _lastCaptureError = '';
            return base64Encode(bytes);
          } else {
            _lastCaptureError = 'File was empty';
          }
        } else {
          _lastCaptureError = 'File not created';
        }
      } else {
        _lastCaptureError = 'PS exit ${result.exitCode}: ${result.stderr}';
      }
    } catch (e) {
      _lastCaptureError = 'Exception: $e';
      debugPrint('Windows capture error: $e');
    }
    return null;
  }

  Future<String?> _captureMacDesktop() async {
    try {
      final tempDir = await getTemporaryDirectory();
      final tempPath =
          '${tempDir.path}/screen_${DateTime.now().millisecondsSinceEpoch}.jpg';

      final result = await Process.run(
          'screencapture', ['-x', '-t', 'jpg', tempPath]);
      if (result.exitCode == 0) {
        final file = File(tempPath);
        if (await file.exists()) {
          final bytes = await file.readAsBytes();
          try {
            await file.delete();
          } catch (_) {}
          _captureMethod = 'mac-native';
          return base64Encode(bytes);
        }
      }
    } catch (e) {
      debugPrint('macOS capture error: $e');
    }
    return null;
  }

  Future<String?> _captureLinuxDesktop() async {
    try {
      final result = await Process.run(
          'import', ['-window', 'root', '-quality', '55', 'jpg:-']);
      if (result.exitCode == 0) {
        _captureMethod = 'linux-native';
        return base64Encode(result.stdout as List<int>);
      }
    } catch (e) {
      debugPrint('Linux capture error: $e');
    }
    return null;
  }

  Future<String?> _captureFlutterWidget() async {
    try {
      final RenderRepaintBoundary? boundary =
      _repaintKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;

      if (boundary == null) return _generateFallbackPngBase64();

      await Future.delayed(const Duration(milliseconds: 20));
      final ui.Image image = await boundary.toImage(pixelRatio: 0.5);
      final ByteData? byteData =
      await image.toByteData(format: ui.ImageByteFormat.png);

      if (byteData == null) return _generateFallbackPngBase64();

      return base64Encode(byteData.buffer.asUint8List());
    } catch (e) {
      debugPrint('Flutter capture error: $e');
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
    // If live, notify server but don't wait (manager-side will detect idle)
    if (_isLive) {
      try {
        await http.post(
          Uri.parse('$liveStreamUrl?action=stop_live_stream'),
          headers: {'Content-Type': 'application/json'},
          body: json.encode({'emp_id': _employeeId, 'keep_history': true}),
        );
      } catch (_) {}
    }

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

    return Scaffold(
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
                Text('Screen recording (manager-controlled)',
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
          if (_isFetchingEmployee)
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: Color(0xFFE94560)),
            ),
        ],
      ),
    );
  }

  // ⭐ NO START/STOP BUTTON — only status display
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
                    ? 'Screen Recording Active'
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
                    ? 'Frames captured: $_successfulUploads  •  Every 1 minute  •  $_captureMethod'
                    : 'Manager will start recording remotely when needed',
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
                    border: Border.all(
                        color: Colors.red.withOpacity(0.5), width: 1.5),
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
              const SizedBox(height: 20),
              // ⭐ NO BUTTON — info only
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 14),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  color: Colors.white.withOpacity(0.05),
                  border: Border.all(color: Colors.white.withOpacity(0.1)),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.info_outline,
                      color: Colors.white.withOpacity(0.5),
                      size: 20,
                    ),
                    const SizedBox(width: 10),
                    Text(
                      'Manager controls recording',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: Colors.white.withOpacity(0.6),
                        letterSpacing: 0.5,
                      ),
                    ),
                  ],
                ),
              ),
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
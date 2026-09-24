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

  bool _isLive = false;
  DateTime? _sessionStartTime;
  DateTime? _sessionEndTime;
  Duration _activeDuration = Duration.zero;
  Duration _offlineDuration = Duration.zero;
  Timer? _timer;
  Timer? _liveRequestTimer;
  Timer? _frameUploadTimer;

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
  bool _isUploading = false;
  String _activeWindowTitle = 'Unknown';
  String _captureMethod = 'native';

  // Fallback RepaintBoundary key
  final GlobalKey _repaintKey = GlobalKey();

  // Windows cached handles
  int? _cachedForegroundHwnd;

  @override
  void initState() {
    super.initState();
    _offlineDuration = const Duration(minutes: 12, seconds: 45);
    _loadInitialUserData();
    _startLiveRequestPolling();

    // Poll active window title every 2 seconds
    Timer.periodic(const Duration(seconds: 2), (timer) {
      if (mounted && _isLive) _updateActiveWindowTitle();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _liveRequestTimer?.cancel();
    _frameUploadTimer?.cancel();
    super.dispose();
  }

  /// Detect current foreground window title (Windows-native)
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

  // ==================== LIVE REQUEST POLLING ====================
  void _startLiveRequestPolling() {
    _liveRequestTimer?.cancel();
    _liveRequestTimer = Timer.periodic(const Duration(seconds: 3), (timer) {
      if (mounted && !_isLive) _checkForLiveRequest();
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

        if (status == 'requested' && !_showLiveRequestDialog && mounted) {
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
              child: const Icon(Icons.videocam, color: Colors.greenAccent, size: 24),
            ),
            const SizedBox(width: 12),
            const Expanded(
              child: Text('Live Screen Request',
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18)),
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
              child: Row(
                children: [
                  const Icon(Icons.info_outline, color: Colors.amber, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Your FULL DESKTOP will be captured every 1 minute. Active window will be highlighted with a YELLOW BORDER.',
                      style: TextStyle(color: Colors.white.withOpacity(0.7), fontSize: 12),
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
              Navigator.pop(context);
              _showLiveRequestDialog = false;
              setState(() => _liveRequestStatus = 'idle');
              await _declineLiveRequest();
            },
            child: const Text('Decline', style: TextStyle(color: Colors.white60)),
          ),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFE94560),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            onPressed: () {
              Navigator.pop(context);
              _showLiveRequestDialog = false;
              _acceptLiveRequest();
            },
            icon: const Icon(Icons.play_arrow, color: Colors.white, size: 20),
            label: const Text('Accept & Go Live',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
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

  void _acceptLiveRequest() => _startLive(fromRequest: true);

  // ==================== LIVE STREAMING ====================
  void _startLive({bool fromRequest = false}) {
    setState(() {
      _isLive = true;
      _sessionStartTime = DateTime.now();
      _sessionEndTime = null;
      _activeDuration = Duration.zero;
      _liveRequestStatus = fromRequest ? 'streaming' : _liveRequestStatus;
      _framesUploaded = 0;
      _isUploading = false;
    });

    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted && _isLive) {
        setState(() {
          _activeDuration = DateTime.now().difference(_sessionStartTime!);
        });
      }
    });

    // Capture first frame after 500ms
    Future.delayed(const Duration(milliseconds: 500), () {
      if (mounted && _isLive) _startFrameUploading();
    });

    if (fromRequest) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('🔴 Full desktop sharing started — yellow border highlights active window'),
          backgroundColor: Colors.green,
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  void _stopLive() {
    _timer?.cancel();
    _frameUploadTimer?.cancel();

    setState(() {
      _isLive = false;
      _sessionEndTime = DateTime.now();
      _offlineDuration = _offlineDuration + _activeDuration;
      _liveRequestStatus = 'idle';
    });

    _notifyStopStream();

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Session ended. Active: ${_formatDuration(_activeDuration)}'),
        backgroundColor: const Color(0xFFE94560),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _notifyStopStream() async {
    try {
      await http.post(
        Uri.parse('$liveStreamUrl?action=stop_live_stream'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({'emp_id': _employeeId, 'keep_history': true}),
      );
    } catch (e) {
      debugPrint('Error notifying stop stream: $e');
    }
  }

  // ==================== FRAME UPLOADING ====================
  void _startFrameUploading() {
    _frameUploadTimer?.cancel();
    _uploadScreenFrame();

    _frameUploadTimer = Timer.periodic(const Duration(seconds: 60), (timer) {
      if (mounted && _isLive) {
        _uploadScreenFrame();
      } else {
        timer.cancel();
      }
    });
  }

  Future<void> _uploadScreenFrame() async {
    if (!_isLive || _isUploading) return;
    _isUploading = true;

    try {
      // Update window title before capture
      _updateActiveWindowTitle();

      final String? frameData = await _captureFullDesktop();

      if (frameData == null || frameData.isEmpty) {
        debugPrint('Screen capture returned empty');
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
        }),
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data['status'] == 'success') {
          _framesUploaded++;
          debugPrint('✅ Frame #$_framesUploaded uploaded (${frameData.length} chars)');
          if (mounted) setState(() {});
        } else {
          debugPrint('❌ Frame upload failed: ${data['message']}');
        }
      }
    } catch (e) {
      debugPrint('Error uploading frame: $e');
    } finally {
      _isUploading = false;
    }
  }

  /// Captures full desktop with yellow highlight around active window
  Future<String?> _captureFullDesktop() async {
    try {
      if (Platform.isWindows) {
        return await _captureWindowsDesktop();
      } else if (Platform.isMacOS) {
        return await _captureMacDesktop();
      } else if (Platform.isLinux) {
        return await _captureLinuxDesktop();
      }
    } catch (e) {
      debugPrint('Native capture failed: $e');
    }

    // Fallback: Flutter widget capture
    _captureMethod = 'flutter';
    return await _captureFlutterWidget();
  }

  /// Windows: PowerShell + System.Drawing to capture full screen WITH yellow highlight
  Future<String?> _captureWindowsDesktop() async {
    try {
      final tempDir = await getTemporaryDirectory();
      final tempPath = '${tempDir.path}\\screen_${DateTime.now().millisecondsSinceEpoch}.png';
      final tempPathEscaped = tempPath.replaceAll('\\', '\\\\');

      // PowerShell script that captures full screen + draws yellow border on active window
      final psScript = '''
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Get screen bounds
\$screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds

# Create bitmap of full screen
\$bitmap = New-Object System.Drawing.Bitmap \$screen.Width, \$screen.Height
\$graphics = [System.Drawing.Graphics]::FromImage(\$bitmap)
\$graphics.CopyFromScreen(\$screen.X, \$screen.Y, 0, 0, \$bitmap.Size)

# --- Draw YELLOW BORDER around active window ---
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Win32 {
    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }
}
"@

\$hwnd = [Win32]::GetForegroundWindow()
\$rect = New-Object Win32+RECT
[Win32]::GetWindowRect(\$hwnd, [ref]\$rect) | Out-Null

# Draw 4px yellow border around active window
\$pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::Yellow), 4
\$graphics.DrawRectangle(\$pen, \$rect.Left, \$rect.Top, (\$rect.Right - \$rect.Left), (\$rect.Bottom - \$rect.Top))

# --- Draw "RECORDING" label at top ---
\$yellowBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::Yellow)
\$graphics.FillRectangle(\$yellowBrush, 10, 10, 160, 30)
\$font = New-Object System.Drawing.Font("Arial", 14, [System.Drawing.FontStyle]::Bold)
\$blackBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::Black)
\$graphics.DrawString("● RECORDING", \$font, \$blackBrush, 15, 13)

# Save
\$bitmap.Save("$tempPathEscaped", [System.Drawing.Imaging.ImageFormat]::Png)

# Cleanup
\$graphics.Dispose()
\$bitmap.Dispose()
\$pen.Dispose()
''';

      // Write script to temp file to avoid escaping issues
      final scriptPath = '${tempDir.path}\\capture_script.ps1';
      final scriptFile = File(scriptPath);
      await scriptFile.writeAsString(psScript);

      // Run PowerShell with Bypass execution policy
      final result = await Process.run(
        'powershell',
        ['-ExecutionPolicy', 'Bypass', '-NoProfile', '-File', scriptPath],
      );

      if (result.exitCode == 0) {
        final file = File(tempPath);
        if (await file.exists()) {
          final bytes = await file.readAsBytes();
          try {
            await file.delete();
            await scriptFile.delete();
          } catch (_) {}
          _captureMethod = 'windows-native';
          return base64Encode(bytes);
        }
      } else {
        debugPrint('PowerShell error: ${result.stderr}');
      }
    } catch (e) {
      debugPrint('Windows capture error: $e');
    }
    return null;
  }

  /// macOS: screencapture command
  Future<String?> _captureMacDesktop() async {
    try {
      final tempDir = await getTemporaryDirectory();
      final tempPath = '${tempDir.path}/screen_${DateTime.now().millisecondsSinceEpoch}.png';

      final result = await Process.run('screencapture', ['-x', tempPath]);
      if (result.exitCode == 0) {
        final file = File(tempPath);
        if (await file.exists()) {
          final bytes = await file.readAsBytes();
          try { await file.delete(); } catch (_) {}
          _captureMethod = 'mac-native';
          return base64Encode(bytes);
        }
      }
    } catch (e) {
      debugPrint('macOS capture error: $e');
    }
    return null;
  }

  /// Linux: import (ImageMagick)
  Future<String?> _captureLinuxDesktop() async {
    try {
      final result = await Process.run('import', ['-window', 'root', 'png:-']);
      if (result.exitCode == 0) {
        _captureMethod = 'linux-native';
        return base64Encode(result.stdout as List<int>);
      }
    } catch (e) {
      debugPrint('Linux capture error: $e');
    }
    return null;
  }

  /// Flutter widget fallback
  Future<String?> _captureFlutterWidget() async {
    try {
      final RenderRepaintBoundary? boundary =
      _repaintKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;

      if (boundary == null) return _generateFallbackPngBase64();

      await Future.delayed(const Duration(milliseconds: 50));
      final ui.Image image = await boundary.toImage(pixelRatio: 0.75);
      final ByteData? byteData = await image.toByteData(format: ui.ImageByteFormat.png);

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
    if (_isLive) await _notifyStopStream();

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
          // Main dashboard (fallback capture)
          RepaintBoundary(
            key: _repaintKey,
            child: Container(
              width: double.infinity,
              height: double.infinity,
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFF1A1A2E), Color(0xFF16213E), Color(0xFF0F3460)],
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
                          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 16.0),
                          child: ConstrainedBox(
                            constraints: BoxConstraints(maxWidth: isTablet ? 600 : double.infinity),
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
          // Yellow border overlay on Flutter app itself (visual indicator)
          if (_isLive) _buildYellowHighlightOverlay(),
        ],
      ),
    );
  }

  /// Yellow border overlay on Flutter app (visual indicator for employee)
  Widget _buildYellowHighlightOverlay() {
    return IgnorePointer(
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(color: Colors.yellow.withOpacity(0.8), width: 3),
          boxShadow: [
            BoxShadow(color: Colors.yellow.withOpacity(0.3), blurRadius: 20, spreadRadius: 2),
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
              gradient: const LinearGradient(colors: [Color(0xFFE94560), Color(0xFF903749)]),
              boxShadow: [
                BoxShadow(color: const Color(0xFFE94560).withOpacity(0.4), blurRadius: 12, spreadRadius: 1),
              ],
            ),
            child: const Icon(Icons.person_outline, color: Colors.white, size: 24),
          ),
          const SizedBox(width: 16),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Employee Dashboard',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.white, letterSpacing: 0.5)),
                SizedBox(height: 2),
                Text('Full desktop sharing active', style: TextStyle(fontSize: 13, color: Colors.white54)),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              color: _isLive ? Colors.greenAccent.withOpacity(0.15) : Colors.white.withOpacity(0.08),
              border: Border.all(
                color: _isLive ? Colors.greenAccent.withOpacity(0.5) : Colors.white.withOpacity(0.15),
                width: 1,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 8, height: 8,
                  decoration: BoxDecoration(shape: BoxShape.circle, color: _isLive ? Colors.greenAccent : Colors.white38),
                ),
                const SizedBox(width: 6),
                Text(
                  _isLive ? 'LIVE' : 'OFFLINE',
                  style: TextStyle(
                    fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 1,
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
                border: Border.all(color: const Color(0xFFE94560).withOpacity(0.4), width: 1),
              ),
              child: const Icon(Icons.logout_outlined, size: 20, color: Color(0xFFE94560)),
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
          BoxShadow(color: Colors.black.withOpacity(0.2), blurRadius: 10, offset: const Offset(0, 4)),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 60, height: 60,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: const LinearGradient(colors: [Color(0xFFE94560), Color(0xFF903749)]),
              boxShadow: [
                BoxShadow(color: const Color(0xFFE94560).withOpacity(0.3), blurRadius: 12, spreadRadius: 1),
              ],
            ),
            child: Center(
              child: Text(
                _employeeName.isNotEmpty ? _employeeName[0].toUpperCase() : '?',
                style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold, color: Colors.white),
              ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_employeeName,
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white)),
                const SizedBox(height: 4),
                Text(_role,
                    style: const TextStyle(fontSize: 13, color: Color(0xFFE94560), fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Icon(Icons.badge_outlined, size: 14, color: Colors.white.withOpacity(0.5)),
                    const SizedBox(width: 6),
                    Text(_employeeId,
                        style: TextStyle(fontSize: 12, color: Colors.white.withOpacity(0.7), fontWeight: FontWeight.w500)),
                  ],
                ),
              ],
            ),
          ),
          if (_isFetchingEmployee)
            const SizedBox(
              width: 18, height: 18,
              child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFFE94560)),
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
          begin: Alignment.topLeft, end: Alignment.bottomRight,
          colors: _isLive
              ? [const Color(0xFF0F3460).withOpacity(0.8), const Color(0xFF1A1A2E).withOpacity(0.9)]
              : [Colors.black.withOpacity(0.5), const Color(0xFF0F3460).withOpacity(0.3)],
        ),
        border: Border.all(
          color: _isLive ? Colors.yellow.withOpacity(0.6) : Colors.white.withOpacity(0.1),
          width: 2,
        ),
        boxShadow: _isLive
            ? [BoxShadow(color: Colors.yellow.withOpacity(0.2), blurRadius: 20, spreadRadius: 2)]
            : [BoxShadow(color: Colors.black.withOpacity(0.3), blurRadius: 10, offset: const Offset(0, 4))],
      ),
      child: Stack(
        children: [
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 70, height: 70,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _isLive ? Colors.yellow.withOpacity(0.15) : Colors.white.withOpacity(0.05),
                  border: Border.all(
                    color: _isLive ? Colors.yellow.withOpacity(0.6) : Colors.white.withOpacity(0.15),
                    width: 2,
                  ),
                ),
                child: Icon(
                  _isLive ? Icons.desktop_windows : Icons.desktop_access_disabled,
                  size: 36,
                  color: _isLive ? Colors.yellow : Colors.white.withOpacity(0.4),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                _isLive ? 'Full Desktop Sharing Active' : 'Screen Not Sharing',
                style: TextStyle(
                  fontSize: 16, fontWeight: FontWeight.bold,
                  color: _isLive ? Colors.white : Colors.white.withOpacity(0.6),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                _isLive
                    ? 'Frames uploaded: $_framesUploaded  •  Method: $_captureMethod'
                    : 'Tap "Start Live" to begin full desktop sharing',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: Colors.white.withOpacity(0.5)),
              ),
              if (_isLive) ...[
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.yellow.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.yellow.withOpacity(0.5), width: 1.5),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.border_color, color: Colors.yellow, size: 14),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          'Active window: $_activeWindowTitle',
                          style: const TextStyle(color: Colors.yellow, fontSize: 11, fontWeight: FontWeight.bold),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 20),
              GestureDetector(
                onTap: _isLive ? _stopLive : () => _startLive(),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    gradient: LinearGradient(
                      colors: _isLive
                          ? [Colors.redAccent, const Color(0xFFB71C1C)]
                          : [const Color(0xFFE94560), const Color(0xFF903749)],
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: (_isLive ? Colors.redAccent : const Color(0xFFE94560)).withOpacity(0.4),
                        blurRadius: 12, offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        _isLive ? Icons.stop_circle_outlined : Icons.play_circle_filled,
                        color: Colors.white, size: 22,
                      ),
                      const SizedBox(width: 10),
                      Text(
                        _isLive ? 'Stop Live' : 'Start Live',
                        style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white, letterSpacing: 0.8,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          if (_isLive)
            Positioned(
              top: 0, left: 0,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
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
                        style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 1)),
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
            icon: Icons.timer_outlined, label: 'Active Time',
            value: _formatDuration(_activeDuration), color: Colors.greenAccent,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _buildStatCard(
            icon: Icons.timer_off_outlined, label: 'Offline Time',
            value: _formatDuration(_offlineDuration), color: const Color(0xFFE94560),
          ),
        ),
      ],
    );
  }

  Widget _buildStatCard({
    required IconData icon, required String label,
    required String value, required Color color,
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
                decoration: BoxDecoration(shape: BoxShape.circle, color: color.withOpacity(0.15)),
                child: Icon(icon, size: 16, color: color),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(label,
                    style: TextStyle(fontSize: 12, color: Colors.white.withOpacity(0.6), fontWeight: FontWeight.w500)),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(value,
              style: TextStyle(
                fontSize: 20, fontWeight: FontWeight.bold, color: color,
                fontFeatures: const [FontFeature.tabularFigures()],
              )),
        ],
      ),
    );
  }
}
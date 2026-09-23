import 'dart:convert';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'emp_dashboard.dart';
import 'forgot_pwd.dart';

// ─────────────────────────────────────────────────────────────
// DEVICE ID SERVICE
// ─────────────────────────────────────────────────────────────
class DeviceIdService {
  static const String _deviceIdKey = 'device_uuid';
  static final DeviceInfoPlugin _deviceInfo = DeviceInfoPlugin();
  static const Uuid _uuid = Uuid();

  static Future<Map<String, dynamic>> getCombinedDeviceInfo() async {
    String deviceId = '';
    String deviceName = 'Company PC';

    try {
      if (kIsWeb) {
        final WebBrowserInfo info = await _deviceInfo.webBrowserInfo;
        deviceName = 'Browser (${info.browserName.name})';
      } else if (Platform.isWindows) {
        final WindowsDeviceInfo info = await _deviceInfo.windowsInfo;
        deviceId = info.deviceId;
        deviceName = info.computerName;
      } else if (Platform.isAndroid) {
        final AndroidDeviceInfo info = await _deviceInfo.androidInfo;
        deviceId = info.id;
        deviceName = info.model;
      } else if (Platform.isIOS) {
        final IosDeviceInfo info = await _deviceInfo.iosInfo;
        deviceId = info.identifierForVendor ?? '';
        deviceName = info.name;
      } else if (Platform.isMacOS) {
        final MacOsDeviceInfo info = await _deviceInfo.macOsInfo;
        deviceId = info.systemGUID ?? '';
        deviceName = info.computerName;
      } else if (Platform.isLinux) {
        final LinuxDeviceInfo info = await _deviceInfo.linuxInfo;
        deviceId = info.machineId ?? '';
        deviceName = info.name;
      }
    } catch (e) {
      debugPrint("Device info error: $e");
    }

    if (deviceId.isEmpty) {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      String? savedId = prefs.getString(_deviceIdKey);
      if (savedId == null || savedId.isEmpty) {
        savedId = _uuid.v4();
        await prefs.setString(_deviceIdKey, savedId);
      }
      deviceId = savedId;
    }

    return {
      'uuid': deviceId,
      'name': deviceName,
    };
  }
}

// ─────────────────────────────────────────────────────────────
// AUTH SERVICE
// ─────────────────────────────────────────────────────────────
class AuthService {
  static const String _keyIsLoggedIn = 'is_logged_in';
  static const String _keyUserRole = 'user_role';
  static const String _keyUserEmail = 'user_email';
  static const String _keyUserId = 'user_id';
  static const String _keyEmpId = 'emp_id';
  static const String _keyUserName = 'user_name';
  static const String _keyRememberMe = 'remember_me';
  static const String _keySavedEmail = 'saved_email';
  static const String _keyDeviceId = 'logged_in_device_id';

  static Future<void> saveSession({
    required int userId,
    required String empId,
    required String userName,
    required String role,
    required String email,
    required String deviceId,
    required bool rememberMe,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyIsLoggedIn, true);
    await prefs.setInt(_keyUserId, userId);
    await prefs.setString(_keyEmpId, empId);
    await prefs.setString(_keyUserName, userName);
    await prefs.setString(_keyUserRole, role);
    await prefs.setString(_keyUserEmail, email);
    await prefs.setString(_keyDeviceId, deviceId);
    await prefs.setBool(_keyRememberMe, rememberMe);

    if (rememberMe) {
      await prefs.setString(_keySavedEmail, email);
    } else {
      await prefs.remove(_keySavedEmail);
    }
  }

  static Future<bool> isLoggedIn() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyIsLoggedIn) ?? false;
  }

  static Future<Map<String, dynamic>> getSavedLoginState() async {
    final prefs = await SharedPreferences.getInstance();
    return {
      'rememberMe': prefs.getBool(_keyRememberMe) ?? false,
      'email': prefs.getString(_keySavedEmail) ?? '',
      'role': prefs.getString(_keyUserRole) ?? 'Website Developer',
    };
  }
}

// ─────────────────────────────────────────────────────────────
// LOGIN SCREEN (EMPLOYEE ONLY)
// ─────────────────────────────────────────────────────────────
class LogIn extends StatefulWidget {
  const LogIn({super.key});

  @override
  State<LogIn> createState() => _LogInState();
}

const String _loginApiUrl = 'http://192.168.1.42/grow_logix/login.php';

class _LogInState extends State<LogIn> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _obscurePassword = true;
  String? role = 'Website Developer';
  bool _rememberMe = false;
  bool _isLoading = false;

  // Only Employee designations allowed in this software
  final List<String> _rolesList = [
    'Website Developer',
    'Graphics Designer',
    'Data Scrapper',
    'Video Editor',
    'SEO Executive',
    'Social Media Executive',
  ];

  @override
  void initState() {
    super.initState();
    _loadSavedLoginState();
    _autoLoginIfSessionExists();
  }

  Future<void> _loadSavedLoginState() async {
    final state = await AuthService.getSavedLoginState();
    if (!mounted) return;
    setState(() {
      _rememberMe = state['rememberMe'] ?? false;
      if (_rememberMe) {
        _emailController.text = state['email'] ?? '';
      }
      role = state['role'] ?? 'Website Developer';
      if (!_rolesList.contains(role)) {
        role = 'Website Developer';
      }
    });
  }

  Future<void> _autoLoginIfSessionExists() async {
    final loggedIn = await AuthService.isLoggedIn();
    if (!loggedIn || !mounted) return;

    final state = await AuthService.getSavedLoginState();
    final savedRole = (state['role'] ?? '').toString().toLowerCase();

    // Reject Manager accounts automatically
    if (savedRole == 'manager') {
      return;
    }

    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (context) => const EmpDashboard()),
    );
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    if (_isLoading) return;

    setState(() => _isLoading = true);

    try {
      final deviceData = await DeviceIdService.getCombinedDeviceInfo();
      final deviceId = deviceData['uuid'] ?? 'UNKNOWN';
      final deviceName = deviceData['name'] ?? 'Company PC';

      final loginInput = _emailController.text.trim();
      final password = _passwordController.text;

      final response = await http.post(
        Uri.parse(_loginApiUrl),
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
        body: jsonEncode({
          'email': loginInput,
          'emp_id': loginInput,
          'password': password,
          'role': role,
          'device_id': deviceId,
          'device_name': deviceName,
        }),
      );

      final Map<String, dynamic> responseData = jsonDecode(response.body);

      if (response.statusCode == 200 && responseData['status'] == 'success') {
        final userData = responseData['data'];
        final returnedRole = (userData['role'] ?? '').toString().toLowerCase();

        // Reject if account belongs to a Manager
        if (returnedRole == 'manager') {
          if (!mounted) return;
          setState(() => _isLoading = false);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Access Denied: Managers must use Manager Software.'),
              backgroundColor: Colors.redAccent,
            ),
          );
          return;
        }

        await AuthService.saveSession(
          userId: userData['id'] ?? 0,
          empId: userData['emp_id'] ?? '',
          userName: userData['name'] ?? '',
          role: userData['role'] ?? role,
          email: userData['email'] ?? '',
          deviceId: deviceId,
          rememberMe: _rememberMe,
        );

        if (!mounted) return;
        setState(() => _isLoading = false);

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(responseData['message'] ?? 'Welcome back!'),
            backgroundColor: Colors.green,
          ),
        );

        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (context) => const EmpDashboard()),
        );
      } else {
        if (!mounted) return;
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(responseData['message'] ?? 'Authentication failed.'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Network error: $e'),
          backgroundColor: Colors.redAccent,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final isTablet = size.width > 600;

    return Scaffold(
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF1A1A2E), Color(0xFF16213E), Color(0xFF0F3460)],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 32.0),
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: isTablet ? 480 : double.infinity),
                child: Form(
                  key: _formKey,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Container(
                        width: 80,
                        height: 80,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: const LinearGradient(
                            colors: [Color(0xFFE94560), Color(0xFF903749)],
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: const Color(0xFFE94560).withOpacity(0.4),
                              blurRadius: 20,
                              spreadRadius: 2,
                            ),
                          ],
                        ),
                        child: const Icon(Icons.badge_outlined, size: 40, color: Colors.white),
                      ),
                      const SizedBox(height: 32),
                      const Text(
                        'Employee Portal',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold, color: Colors.white),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Sign in to your employee account',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 16, color: Colors.white.withOpacity(0.6)),
                      ),
                      const SizedBox(height: 40),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.08),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: DropdownButtonHideUnderline(
                          child: DropdownButton<String>(
                            value: role,
                            isExpanded: true,
                            dropdownColor: const Color(0xFF16213E),
                            style: const TextStyle(color: Colors.white, fontSize: 15),
                            items: _rolesList.map((r) {
                              return DropdownMenuItem(value: r, child: Text(r));
                            }).toList(),
                            onChanged: (value) => setState(() => role = value),
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),
                      TextFormField(
                        controller: _emailController,
                        style: const TextStyle(color: Colors.white),
                        decoration: InputDecoration(
                          labelText: 'Email or Employee ID',
                          labelStyle: TextStyle(color: Colors.white.withOpacity(0.7)),
                          prefixIcon: Icon(Icons.person_outline, color: Colors.white.withOpacity(0.7)),
                          filled: true,
                          fillColor: Colors.white.withOpacity(0.08),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
                        ),
                        validator: (v) => v == null || v.isEmpty ? 'Enter Email or Emp ID' : null,
                      ),
                      const SizedBox(height: 20),
                      TextFormField(
                        controller: _passwordController,
                        obscureText: _obscurePassword,
                        style: const TextStyle(color: Colors.white),
                        decoration: InputDecoration(
                          labelText: 'Password',
                          labelStyle: TextStyle(color: Colors.white.withOpacity(0.7)),
                          prefixIcon: Icon(Icons.lock_outline, color: Colors.white.withOpacity(0.7)),
                          suffixIcon: IconButton(
                            icon: Icon(_obscurePassword ? Icons.visibility_off_outlined : Icons.visibility_outlined, color: Colors.white.withOpacity(0.7)),
                            onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                          ),
                          filled: true,
                          fillColor: Colors.white.withOpacity(0.08),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
                        ),
                        validator: (v) => v == null || v.isEmpty ? 'Enter password' : null,
                      ),
                      const SizedBox(height: 16),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Row(
                            children: [
                              Checkbox(
                                value: _rememberMe,
                                onChanged: (v) => setState(() => _rememberMe = v ?? false),
                                activeColor: const Color(0xFFE94560),
                              ),
                              Text('Remember me', style: TextStyle(color: Colors.white.withOpacity(0.7))),
                            ],
                          ),
                          TextButton(
                            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ForgotPwd())),
                            child: const Text('Forgot Password ?', style: TextStyle(color: Color(0xFFE94560))),
                          ),
                        ],
                      ),
                      const SizedBox(height: 32),
                      ElevatedButton(
                        onPressed: _isLoading ? null : _submit,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFE94560),
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                        ),
                        child: _isLoading
                            ? const CircularProgressIndicator(color: Colors.white)
                            : Text('Log In as $role', style: const TextStyle(fontSize: 16, color: Colors.white, fontWeight: FontWeight.bold)),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
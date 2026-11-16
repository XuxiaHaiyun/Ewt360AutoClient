/// 风控启动引导: 在 runApp(真实 App) 之前独立展示致命对话框与启动密码门,
/// 使用 AppTheme 配色 (强调色直接读持久化值); 含跨平台 terminate() 退出。
library;

import 'dart:async';
import 'dart:io' show exit;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme/app_theme.dart';
import 'risk_control_config.dart';
import 'startup_password_dialog.dart';

/// 风控启动引导: 在 runApp(真实 App) 之前展示致命对话框 / 启动密码门。
///
/// 弹窗使用 [AppTheme] 配色, 保持与应用主界面视觉一致;
/// 强调色读取设置页保存的种子色 (尚未进入主 App, 直接读持久化值)。
class RiskControlBoot {
  RiskControlBoot._();

  /// 读取用户保存的强调色种子, 失败/未保存时回退默认品牌蓝
  static Future<Color> _loadSeed() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return AppTheme.seedFromValue(prefs.getInt(AppTheme.accentColorPrefKey));
    } catch (_) {
      return AppTheme.defaultSeed;
    }
  }

  /// 退出应用 (Web 用 SystemNavigator.pop, native 用 exit)
  static void terminate() {
    if (kIsWeb) {
      SystemNavigator.pop();
    } else {
      exit(0);
    }
  }

  /// 弹致命错误对话框 (加载失败 / 一键跑路), 用户点确定后返回。
  static Future<void> showFatalDialog(String message) async {
    final seed = await _loadSeed();
    final completer = Completer<void>();
    runApp(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(seed),
      darkTheme: AppTheme.dark(seed),
      home: _FatalHost(message: message, onDone: completer.complete),
    ));
    await completer.future;
  }

  /// 启动密码门, 返回是否通过。
  static Future<bool> showStartupPasswordGate(
    RiskControlConfig config,
  ) async {
    final seed = await _loadSeed();
    final completer = Completer<bool>();
    runApp(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(seed),
      darkTheme: AppTheme.dark(seed),
      home: _StartupPasswordHost(
        config: config,
        onResult: completer.complete,
      ),
    ));
    return completer.future;
  }
}

class _FatalHost extends StatefulWidget {
  final String message;
  final VoidCallback onDone;
  const _FatalHost({required this.message, required this.onDone});

  @override
  State<_FatalHost> createState() => _FatalHostState();
}

class _FatalHostState extends State<_FatalHost> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => AlertDialog(
          content: Text(widget.message),
          actions: [
            FilledButton(
              onPressed: () {
                Navigator.of(context).pop();
                widget.onDone();
              },
              child: const Text('确定'),
            ),
          ],
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: SizedBox.shrink()));
}

class _StartupPasswordHost extends StatefulWidget {
  final RiskControlConfig config;
  final void Function(bool ok) onResult;
  const _StartupPasswordHost({required this.config, required this.onResult});

  @override
  State<_StartupPasswordHost> createState() => _StartupPasswordHostState();
}

class _StartupPasswordHostState extends State<_StartupPasswordHost> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final ok = await StartupPasswordDialog.show(context, widget.config);
      if (!mounted) return;
      widget.onResult(ok);
    });
  }

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: SizedBox.shrink()));
}

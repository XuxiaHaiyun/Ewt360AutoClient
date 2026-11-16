/// 启动密码弹窗: 进入应用前校验远程配置中的启动密码, 输错可重试,
/// 取消/退出返回 false (调用方应退出应用); 不可点击遮罩关闭。
library;

import 'package:flutter/material.dart';

import 'risk_control_config.dart';

/// 启动密码弹窗
///
/// 进入应用前校验 `RiskControlConfig.startupPassword`。
/// 输错可重试, 取消/退出即关闭应用。
class StartupPasswordDialog extends StatefulWidget {
  final RiskControlConfig config;
  const StartupPasswordDialog({super.key, required this.config});

  @override
  State<StartupPasswordDialog> createState() => _StartupPasswordDialogState();

  /// 返回 true = 通过, false = 用户取消 (应退出应用)
  static Future<bool> show(
    BuildContext context,
    RiskControlConfig config,
  ) async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => StartupPasswordDialog(config: config),
    );
    return result ?? false;
  }
}

class _StartupPasswordDialogState extends State<StartupPasswordDialog> {
  final _controller = TextEditingController();
  bool _obscure = true;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    if (widget.config.verifyStartupPassword(_controller.text)) {
      Navigator.of(context).pop(true);
    } else {
      setState(() {
        _error = widget.config.startupPasswordError;
        _controller.clear();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.config.startupPasswordPrompt),
      content: TextField(
        controller: _controller,
        obscureText: _obscure,
        autofocus: true,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _submit(),
        decoration: InputDecoration(
          errorText: _error,
          suffixIcon: IconButton(
            icon: Icon(_obscure ? Icons.visibility_off : Icons.visibility),
            onPressed: () => setState(() => _obscure = !_obscure),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('退出'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('确定'),
        ),
      ],
    );
  }
}

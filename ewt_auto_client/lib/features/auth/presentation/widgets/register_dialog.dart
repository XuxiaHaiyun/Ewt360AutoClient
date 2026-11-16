/// 短信注册弹窗，流程与短信登录同构：safeToken → 发送验证码 → 校验得 authenticationToken → 创建账号（密码 AES 加密）。
/// 注册成功后自动以密码登录；show 返回 true=注册成功、null=取消/失败。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/constants/crypto_constants.dart';
import '../providers/auth_provider.dart';
import 'captcha_dialog.dart';

/// 短信注册弹窗
///
/// 流程与短信登录同构（4 步）：
///   1. safecenter control/type 获取 safeToken（注册 bizCode）
///   2. 发送注册短信验证码
///   3. 校验短信验证码 → authenticationToken
///   4. 创建账号（密码 AES-256-CBC 加密）
/// 注册成功后自动以密码登录。
class RegisterDialog extends ConsumerStatefulWidget {
  const RegisterDialog({super.key});

  /// 显示注册弹窗，返回 true=注册成功（含自动登录），null=取消/失败
  static Future<bool?> show(BuildContext context) {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const RegisterDialog(),
    );
  }

  @override
  ConsumerState<RegisterDialog> createState() => _RegisterDialogState();
}

class _RegisterDialogState extends ConsumerState<RegisterDialog> {
  final _phoneController = TextEditingController();
  final _codeController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  int _countdown = 0;
  Timer? _countdownTimer;
  bool _registering = false;

  @override
  void dispose() {
    _phoneController.dispose();
    _codeController.dispose();
    _passwordController.dispose();
    _confirmController.dispose();
    _countdownTimer?.cancel();
    super.dispose();
  }

  Future<void> _sendCode() async {
    final phone = _phoneController.text.trim();
    if (phone.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请输入手机号')),
      );
      return;
    }

    final error = await ref
        .read(authProvider.notifier)
        .sendRegisterSmsCode(phone);
    if (error == 'CAPTCHA_REQUIRED') {
      if (!mounted) return;
      final token = await CaptchaDialog.show(
        context,
        bizCode: CryptoConstants.registerSmsCaptchaBizCode,
      );
      if (token == null || !mounted) return;
      final retryError = await ref
          .read(authProvider.notifier)
          .sendRegisterSmsCode(phone, captchaToken: token);
      if (retryError != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(retryError)),
        );
        return;
      }
    } else if (error != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
      return;
    }

    if (!mounted) return;
    setState(() => _countdown = 60);
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_countdown <= 1) {
        _countdownTimer?.cancel();
        if (mounted) setState(() => _countdown = 0);
      } else {
        if (mounted) setState(() => _countdown--);
      }
    });
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    final phone = _phoneController.text.trim();
    final smsCode = _codeController.text.trim();
    final password = _passwordController.text;

    setState(() => _registering = true);
    try {
      final error = await ref.read(authProvider.notifier).registerWithSms(
            phone: phone,
            smsCode: smsCode,
            password: password,
          );
      if (!mounted) return;

      if (error == null) {
        // 注册成功（含自动登录），关闭弹窗并通知外层刷新
        Navigator.of(context).pop(true);
        return;
      }

      // 注册失败，提示错误
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
    } finally {
      if (mounted) setState(() => _registering = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Row(
        children: [
          Icon(Icons.person_add_alt_1_outlined, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          const Text('注册账号'),
        ],
      ),
      content: SizedBox(
        width: 360,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _phoneController,
                decoration: const InputDecoration(
                  labelText: '手机号',
                  prefixIcon: Icon(Icons.phone_android_outlined),
                ),
                keyboardType: TextInputType.phone,
                validator: (v) {
                  if (v == null || v.isEmpty) return '请输入手机号';
                  if (!RegExp(r'^1[3-9]\d{9}$').hasMatch(v)) {
                    return '手机号格式不正确';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _codeController,
                      decoration: const InputDecoration(
                        labelText: '验证码',
                        prefixIcon: Icon(Icons.sms_outlined),
                      ),
                      keyboardType: TextInputType.number,
                      validator: (v) =>
                          (v == null || v.isEmpty) ? '请输入验证码' : null,
                    ),
                  ),
                  const SizedBox(width: 12),
                  SizedBox(
                    height: 56,
                    child: FilledButton.tonal(
                      onPressed: _countdown > 0 ? null : _sendCode,
                      child: Text(_countdown > 0 ? '${_countdown}s' : '获取验证码'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _passwordController,
                decoration: const InputDecoration(
                  labelText: '密码',
                  prefixIcon: Icon(Icons.lock_outline),
                ),
                obscureText: true,
                validator: (v) {
                  if (v == null || v.isEmpty) return '请输入密码';
                  if (v.length < 6) return '密码至少 6 位';
                  return null;
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _confirmController,
                decoration: const InputDecoration(
                  labelText: '确认密码',
                  prefixIcon: Icon(Icons.lock_outline),
                ),
                obscureText: true,
                validator: (v) {
                  if (v == null || v.isEmpty) return '请再次输入密码';
                  if (v != _passwordController.text) return '两次输入的密码不一致';
                  return null;
                },
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: FilledButton(
                  onPressed: _registering ? null : _submit,
                  child: _registering
                      ? const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('注册'),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _registering ? null : () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
      ],
    );
  }
}

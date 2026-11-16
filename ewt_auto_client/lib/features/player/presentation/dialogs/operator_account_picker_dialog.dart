/// 快刷模式 3 的操作者账号多选弹窗：从 accountProvider 已保存账号中选取执行账号。
/// 仅密码登录且已记密码、或 token 检测有效的账号可选；支持用独立 DioClient 批量检测 token 有效性。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/di/injection.dart';
import '../../../../core/network/dio_client.dart';
import '../../../auth/domain/entities/user_session.dart';
import '../../../auth/presentation/providers/account_provider.dart';

/// 操作者账号选取结果
class OperatorPickResult {
  final List<UserSession> selected;

  const OperatorPickResult(this.selected);
}

/// 快刷模式3 操作者账号选取弹窗 (多选)
///
/// 数据源: accountProvider 已保存账号列表。
/// 选取规则:
/// - 密码登录且已记住密码: 直接可选 (token 失效时执行前凭密码自动重登);
/// - 短信/扫码登录 (或密码账号未记密码): token 经"检测 Token"验证为有效
///   后可选 (无法自动重登, 执行前 token 失效会被跳过)。
///
/// "检测 Token" 用独立 DioClient 逐个验证全部账号的 token 有效性
/// (不影响当前登录会话), 结果以徽标展示。
///
/// 布局注意: 项目级禁令 — M3 Dialog 中禁止 SizedBox(width: double.infinity)
/// 包裹 ListView (引发 Cannot hit test / 冻结), 此处使用固定宽度 420。
class OperatorAccountPickerDialog extends ConsumerStatefulWidget {
  /// 预选中的账号 userId 集合 (来自已保存配置)
  final Set<String> initialUserIds;

  const OperatorAccountPickerDialog({super.key, required this.initialUserIds});

  /// 打开弹窗, 确认返回选中账号列表 (取消返回 null)
  static Future<List<UserSession>?> show(
    BuildContext context, {
    required Set<String> initialUserIds,
  }) {
    return showDialog<List<UserSession>>(
      context: context,
      builder: (_) =>
          OperatorAccountPickerDialog(initialUserIds: initialUserIds),
    );
  }

  @override
  ConsumerState<OperatorAccountPickerDialog> createState() =>
      _OperatorAccountPickerDialogState();
}

class _OperatorAccountPickerDialogState
    extends ConsumerState<OperatorAccountPickerDialog> {
  /// 选中账号 userId 集合
  late Set<String> _selected;

  /// token 有效性 (userId → 检测中/有效/无效)
  final Map<String, _TokenState> _validity = {};
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    _selected = Set.of(widget.initialUserIds);
  }

  /// 可选取的账号:
  /// - 密码登录且已记住密码 (token 失效可自动重登) → 直接可选;
  /// - 短信/扫码等其它登录方式 → token 检测为有效后可选 (无法自动重登)。
  bool _pickable(UserSession a) {
    if (a.loginMethod == 'password' && (a.password?.isNotEmpty ?? false)) {
      return true;
    }
    return _validity[a.userId] == _TokenState.valid;
  }

  /// 弹窗为何不可选取的说明 (null = 可选取)
  String? _disabledReason(UserSession a) {
    if (a.loginMethod == 'password' && (a.password?.isNotEmpty ?? false)) {
      return null;
    }
    final v = _validity[a.userId];
    if (v == null) return 'Token 未检测 (检测有效后可选)';
    if (v == _TokenState.checking) return 'Token 检测中...';
    if (v == _TokenState.invalid) return 'Token 无效 (无法自动重登)';
    return null;
  }

  /// 检测全部账号的 token 有效性 (独立 DioClient, 不污染当前登录会话)。
  /// 短信/扫码账号依赖此检测结果决定是否可选。
  Future<void> _checkTokens() async {
    if (_checking) return;
    final accounts = ref.read(accountProvider).accounts;
    if (accounts.isEmpty) return;
    setState(() {
      _checking = true;
      for (final a in accounts) {
        _validity[a.userId] = _TokenState.checking;
      }
    });

    final endpointConfig = getIt<DioClient>().endpointConfig;
    for (final acc in accounts) {
      _TokenState state;
      try {
        final client =
            DioClient(endpointConfig: endpointConfig, proxy: acc.proxy);
        client.token = acc.token;
        final resp = await client
            .get('/api/usercenter/user/login/getUser')
            .timeout(const Duration(seconds: 10));
        state = resp.isSuccess ? _TokenState.valid : _TokenState.invalid;
      } catch (_) {
        state = _TokenState.invalid;
      }
      if (!mounted) return;
      setState(() => _validity[acc.userId] = state);
    }
    if (!mounted) return;
    setState(() => _checking = false);
  }

  void _toggle(UserSession a) {
    setState(() {
      if (_selected.contains(a.userId)) {
        _selected.remove(a.userId);
      } else {
        _selected.add(a.userId);
      }
    });
  }

  void _confirm() {
    final accounts = ref.read(accountProvider).accounts;
    final picked = accounts
        .where((a) => _selected.contains(a.userId))
        .where(_pickable)
        .toList();
    Navigator.of(context).pop(picked);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accounts = ref.watch(accountProvider).accounts;

    // 排序: 可选取的在前, 组内按账号名
    final sorted = [...accounts]..sort((a, b) {
        final pa = _pickable(a) ? 0 : 1;
        final pb = _pickable(b) ? 0 : 1;
        if (pa != pb) return pa - pb;
        return (a.account ?? '').compareTo(b.account ?? '');
      });

    return AlertDialog(
      title: const Text('选择操作者账号'),
      // 固定宽度 420 (项目禁令: 禁止 double.infinity 包 ListView)
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '密码登录且已记住密码的账号: token 失效执行前自动重登; '
              '短信/扫码账号: 点击"检测 Token"验证有效后可选 (无法自动重登)。'
              '受害者为当前登录账号 (不可编辑)。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                TextButton.icon(
                  onPressed: _checking ? null : _checkTokens,
                  icon: _checking
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.verified_user_outlined, size: 16),
                  label: Text(_checking ? '检测中...' : '检测 Token'),
                ),
                const Spacer(),
                Text('已选 ${_selected.length} 个',
                    style: theme.textTheme.labelLarge),
              ],
            ),
            const Divider(),
            Flexible(
              child: sorted.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.symmetric(vertical: 24),
                      child: Center(
                        child: Text(
                          '暂无已保存账号\n请先在登录页保存账号',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      itemCount: sorted.length,
                      itemBuilder: (context, i) {
                        final a = sorted[i];
                        final pickable = _pickable(a);
                        final reason = _disabledReason(a);
                        final validity = _validity[a.userId];
                        return CheckboxListTile(
                          dense: true,
                          value: _selected.contains(a.userId),
                          onChanged: pickable ? (_) => _toggle(a) : null,
                          title: Text(
                            (a.account ?? a.userId) +
                                (a.displayName?.isNotEmpty == true
                                    ? ' (${a.displayName})'
                                    : ''),
                            style: TextStyle(
                              fontSize: 14,
                              color: pickable
                                  ? null
                                  : theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                          subtitle: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (reason != null)
                                Text(reason,
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: theme.colorScheme.onSurfaceVariant,
                                    )),
                              if (validity != null) ...[
                                if (reason != null) const SizedBox(width: 8),
                                _validityBadge(validity, theme, a),
                              ],
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton.icon(
          onPressed: _selected.isEmpty ? null : _confirm,
          icon: const Icon(Icons.check_rounded, size: 18),
          label: const Text('确定'),
        ),
      ],
    );
  }

  Widget _validityBadge(_TokenState state, ThemeData theme, UserSession a) {
    final canRelogin =
        a.loginMethod == 'password' && (a.password?.isNotEmpty ?? false);
    final (label, color) = switch (state) {
      _TokenState.checking => ('检测中', theme.colorScheme.secondary),
      _TokenState.valid => ('Token 有效', Colors.green),
      _TokenState.invalid => (
          canRelogin ? 'Token 无效 (将自动重登)' : 'Token 无效 (无法自动重登)',
          theme.colorScheme.error
        ),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: theme.textTheme.bodySmall?.copyWith(color: color, fontSize: 11),
      ),
    );
  }
}

enum _TokenState { checking, valid, invalid }

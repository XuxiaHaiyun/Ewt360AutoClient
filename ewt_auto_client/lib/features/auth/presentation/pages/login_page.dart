/// 登录页面，两种视图：账号列表（已保存账号 + 批量任务/保活操作）与登录表单（密码/二维码/短信/Token Tab）。
/// 登录方式按风控配置逐项筛选；登录成功/失败、需滑块验证与需改密状态由 authProvider 驱动 UI 流程。
library;

import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../../core/config/endpoint_config.dart';
import '../../../../core/constants/crypto_constants.dart';
import '../../../../core/di/injection.dart';
import '../../../../core/layout/app_breakpoints.dart';
import '../../../../core/risk_control/risk_control_gate.dart';
import '../../../../core/utils/proxy_parser.dart';
import '../../../answer/domain/entities/answer_config.dart';
import '../../../answer/domain/entities/answer_filter_config.dart';
import '../../../answer/presentation/pages/answer_config_page.dart';
import '../../../download/domain/entities/download_config.dart';
import '../../../download/presentation/dialogs/download_config_dialog.dart';
import '../../../homework/presentation/dialogs/task_filter_dialog.dart';
import '../../domain/entities/user_session.dart';
import '../providers/account_provider.dart';
import '../providers/auth_provider.dart';
import '../services/batch_task_executor.dart';
import '../services/keep_alive_service.dart';
import '../widgets/captcha_dialog.dart';
import '../widgets/register_dialog.dart';
import 'package:ewt_auto_client/features/settings/presentation/providers/settings_provider.dart';
import 'package:ewt_auto_client/features/player/domain/entities/report_config.dart';
import 'package:ewt_auto_client/features/player/presentation/pages/report_config_page.dart';
import 'package:ewt_auto_client/features/player/presentation/dialogs/task_progress_dialog.dart';

/// 登录页面
///
/// 两种视图：账号列表（已保存账号 + 批量操作） / 登录表单（Tab 切换）
class LoginPage extends ConsumerStatefulWidget {
  const LoginPage({super.key});

  @override
  ConsumerState<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends ConsumerState<LoginPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  late final List<String> _loginMethods;

  /// true = 显示登录表单，false = 显示账号列表
  bool _showLoginForm = false;

  @override
  void initState() {
    super.initState();
    // 按风控配置筛选可用登录方式 (细粒度逐项)
    _loginMethods = [
      if (RiskControlGate.isFeatureEnabled('login.password')) 'password',
      if (RiskControlGate.isFeatureEnabled('login.qrcode')) 'qrcode',
      if (RiskControlGate.isFeatureEnabled('login.sms')) 'sms',
      if (RiskControlGate.isFeatureEnabled('login.token')) 'token',
    ];
    _tabController = TabController(
      length: _loginMethods.isEmpty ? 1 : _loginMethods.length,
      vsync: this,
    );
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _showCaptchaAndRetry() async {
    final token = await CaptchaDialog.show(context);
    if (token != null && mounted) {
      ref.read(authProvider.notifier).retryWithCaptchaToken(token);
    }
  }

  /// 弱密码 / 需改密：弹出改密弹窗，改密成功后由 provider 自动用新密码重登
  Future<void> _showChangePasswordDialog(AuthPasswordChangeRequired state) async {
    if (!mounted) return;
    await ChangePasswordDialog.show(context, state);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final accountState = ref.watch(accountProvider);

    ref.listen<AuthState>(authProvider, (prev, next) {
      if (next is AuthAuthenticated) {
        // 保存账号到持久化
        ref.read(accountProvider.notifier).addAccount(next.session);
        context.go('/home');
      } else if (next is AuthCaptchaRequired) {
        _showCaptchaAndRetry();
      } else if (next is AuthPasswordChangeRequired) {
        _showChangePasswordDialog(next);
      } else if (next is AuthError) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(next.message), behavior: SnackBarBehavior.floating),
        );
      }
    });

    // 有已保存账号且未切换到登录表单 → 显示账号列表
    final showAccountList = accountState.accounts.isNotEmpty && !_showLoginForm;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: AppBreakpoints.loginFormMaxWidth),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.auto_awesome, size: 56, color: colorScheme.primary),
                  const SizedBox(height: 12),
                  Text(
                    'EWT Auto Client',
                    style: theme.textTheme.headlineSmall
                        ?.copyWith(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'e网通自动化客户端',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 24),
                  if (showAccountList)
                    _AccountListView(
                      onAddAccount: () => setState(() => _showLoginForm = true),
                    )
                  else
                    _LoginFormCard(
                      tabController: _tabController,
                      methods: _loginMethods,
                      showBack: accountState.accounts.isNotEmpty,
                      onBack: () => setState(() => _showLoginForm = false),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════
// 账号列表视图
// ═══════════════════════════════════════════
class _AccountListView extends ConsumerWidget {
  final VoidCallback onAddAccount;

  const _AccountListView({required this.onAddAccount});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final state = ref.watch(accountProvider);
    final notifier = ref.read(accountProvider.notifier);
    final authState = ref.watch(authProvider);
    final isLoggingIn = authState is AuthLoading;
    final settings = ref.watch(appSettingsProvider);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 标题栏
            Row(
              children: [
                Expanded(
                  child: Text(
                    '已保存账号 (${state.accounts.length})',
                    style: theme.textTheme.titleMedium,
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                ),
                // 全选
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: Icon(
                    state.allSelected
                        ? Icons.check_box
                        : Icons.check_box_outline_blank,
                  ),
                  tooltip: '全选',
                  onPressed: notifier.toggleSelectAll,
                ),
                // 验证有效性
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.verified_user_outlined),
                  tooltip: '验证Token有效性',
                  onPressed: () => notifier.validateTokens(
                    tokens: state.hasSelection
                        ? state.selectedTokens.toList()
                        : null,
                  ),
                ),
                // 批量删除
                if (state.hasSelection)
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: Icon(Icons.delete_outline, color: theme.colorScheme.error),
                    tooltip: '删除选中',
                    onPressed: () => _confirmDelete(context, notifier),
                  ),
                // 批量运行任务
                if (state.hasSelection)
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: Icon(Icons.play_arrow, color: theme.colorScheme.primary),
                    tooltip: '批量运行任务',
                    onPressed: () => _batchRun(context, ref, state),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            // 账号列表
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 320),
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: state.accounts.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final account = state.accounts[index];
                  final selected = state.selectedTokens.contains(account.token);
                  final displayName = account.displayName ?? account.account ?? '未知用户';
                  return InkWell(
                    onTap: () {
                      // 单击直接登录该账号
                      ref.read(authProvider.notifier).loginWithToken(account.token);
                    },
                    onLongPress: RiskControlGate.isFeatureEnabled('account_menu.view_detail')
                        ? () => _showAccountDetail(context, ref, account, settings, state)
                        : null,
                    onSecondaryTap: RiskControlGate.isFeatureEnabled('account_menu.view_detail')
                        ? () => _showAccountDetail(context, ref, account, settings, state)
                        : null,
                    child: CheckboxListTile(
                      value: selected,
                      onChanged: (_) => notifier.toggleSelection(account.token),
                      secondary: CircleAvatar(
                        backgroundColor: theme.colorScheme.primaryContainer,
                        backgroundImage: (!settings.demoMode &&
                                account.avatar != null &&
                                account.avatar!.isNotEmpty)
                            ? NetworkImage(account.avatar!)
                            : null,
                        child: (settings.demoMode ||
                                account.avatar == null ||
                                account.avatar!.isEmpty)
                            ? Text(
                                settings.demoMode
                                    ? '*'
                                    : displayName.characters.first,
                                style: TextStyle(
                                    color: theme.colorScheme.onPrimaryContainer),
                              )
                            : null,
                      ),
                      title: Text(
                        settings.mask(displayName),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Row(
                        children: [
                          _ValidityDot(
                            validity: state.validityOf(account.token),
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              'ID: ${settings.mask(account.userId)}${account.schoolName != null ? ' · ${settings.mask(account.schoolName)}' : ''}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall,
                            ),
                          ),
                          // 代理标识
                          if ((account.proxy ?? '').trim().isNotEmpty) ...[
                            const SizedBox(width: 6),
                            Icon(
                              Icons.vpn_key_outlined,
                              size: 12,
                              color: theme.colorScheme.primary,
                            ),
                            const SizedBox(width: 2),
                            Flexible(
                              child: Text(
                                account.proxy!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.primary,
                                  fontSize: 11,
                                  fontFamily: 'monospace',
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 16),
            // 操作按钮
            Row(
              children: [
                // 登录账号（单选）
                Expanded(
                  child: FilledButton.icon(
                    onPressed: state.selectedTokens.length == 1 && !isLoggingIn
                        ? () => _loginSelected(context, ref, state)
                        : null,
                    icon: isLoggingIn
                        ? const SizedBox(
                            width: 16, height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.login, size: 18),
                    label: const Text('登录账号'),
                  ),
                ),
                const SizedBox(width: 12),
                // 新增账号
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: onAddAccount,
                    icon: const Icon(Icons.person_add_outlined, size: 18),
                    label: const Text('新增账号'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _confirmDelete(BuildContext context, AccountNotifier notifier) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认删除'),
        content: const Text('确定要删除选中的账号吗？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () {
              notifier.removeSelected();
              Navigator.pop(ctx);
            },
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }

  void _showAccountDetail(
    BuildContext context,
    WidgetRef ref,
    UserSession account,
    AppSettingsState settings,
    AccountListState state,
  ) {
    final theme = Theme.of(context);
    final validity = state.validityOf(account.token);
    final validityText = switch (validity) {
      TokenValidity.valid => '有效',
      TokenValidity.invalid => '无效',
      TokenValidity.checking => '验证中',
      TokenValidity.unknown => '未验证',
    };
    final validityColor = switch (validity) {
      TokenValidity.valid => Colors.green,
      TokenValidity.invalid => Colors.red,
      TokenValidity.checking => Colors.orange,
      TokenValidity.unknown => Colors.grey,
    };
    // token 只显示前6后4
    final maskedToken = account.token.length > 12
        ? '${account.token.substring(0, 6)}...${account.token.substring(account.token.length - 4)}'
        : '***';

    // 登录方式标签 (与登录表单 Tab 一致); 已记住密码时附加提示
    const methodLabels = {
      'password': '密码',
      'sms': '短信',
      'qrcode': '扫码',
      'token': '凭证',
    };
    final hasPassword = (account.password ?? '').isNotEmpty;
    final methodLabel = methodLabels[account.loginMethod] ?? '-';
    final methodText = hasPassword ? '$methodLabel（已记住密码）' : methodLabel;

    final rows = <MapEntry<String, String>>[
      MapEntry('昵称', settings.mask(account.displayName ?? '-')),
      MapEntry('账号', settings.mask(account.account ?? '-')),
      MapEntry('用户ID', settings.mask(account.userId)),
      MapEntry('学校ID', settings.mask(account.schoolId)),
      MapEntry('学校', settings.mask(account.schoolName ?? '-')),
      MapEntry('手机号', settings.mask(account.mobile ?? '-')),
      MapEntry('登录方式', methodText),
      MapEntry('Token', settings.demoMode ? '****' : maskedToken),
    ];

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            const Icon(Icons.badge_outlined, size: 20),
            const SizedBox(width: 8),
            const Text('账号详情'),
            const Spacer(),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: validityColor.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                validityText,
                style: TextStyle(color: validityColor, fontSize: 12),
              ),
            ),
          ],
        ),
        content: SizedBox(
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: rows.map((e) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 72,
                      child: Text(
                        e.key,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    Expanded(
                      child: SelectableText(
                        e.value,
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                  ],
                ),
              );
            }).toList(),
          ),
        ),
        actions: [
          if (RiskControlGate.isFeatureEnabled('account_menu.copy_token'))
            TextButton.icon(
              icon: const Icon(Icons.copy, size: 16),
              label: const Text('复制Token'),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: account.token));
                Navigator.pop(ctx);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Token 已复制到剪贴板'), duration: Duration(seconds: 1)),
                );
              },
            ),
          // 重新登录: 账号名自动填充, 已记住密码时预填 (仅需确认/重输密码)。
          // 登录结果由页面级 ref.listen 统一处理 (滑块/错误/成功跳转)。
          if (RiskControlGate.isFeatureEnabled('login.password'))
            FilledButton.tonalIcon(
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('重新登录'),
              onPressed: () async {
                Navigator.pop(ctx); // 先关闭详情弹窗
                final cred = await _ReLoginDialog.show(context, account);
                if (cred == null) return;
                ref.read(authProvider.notifier).loginWithPassword(
                      account: cred.account,
                      password: cred.password,
                    );
              },
            ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  /// 登录选中的单个账号
  void _loginSelected(BuildContext context, WidgetRef ref, AccountListState state) {
    final selected = state.accounts
        .where((a) => state.selectedTokens.contains(a.token))
        .toList();
    if (selected.isEmpty) return;
    ref.read(authProvider.notifier).loginWithToken(selected.first.token);
  }

  /// 批量运行任务：弹出任务选择对话框
  ///
  /// 对齐 Python: gui/dialogs/account.py `_execute_batch` + BatchOperationWorker
  /// 第一项"保持账号活跃"为 Flutter 新增 (Python 未实现), 死循环定时 getUser 保活
  void _batchRun(BuildContext context, WidgetRef ref, AccountListState state) {
    final selectedAccounts = state.accounts
        .where((a) => state.selectedTokens.contains(a.token))
        .toList();
    if (selectedAccounts.isEmpty) return;

    showDialog(
      context: context,
      builder: (ctx) => _BatchTaskDialog(
        accounts: selectedAccounts,
        onConfirm: (task, parallel, accounts) {
          Navigator.of(ctx).pop();
          // 代理设置差异持久化到账号 (发生变化才写入)
          _persistProxyChanges(ref, selectedAccounts, accounts);
          // 按任务分发
          if (task == '保持账号活跃') {
            _startKeepAlive(context, ref, accounts);
          } else {
            _startBatchTask(context, ref, accounts, task,
                parallel: parallel);
          }
        },
      ),
    );
  }

  /// 将代理设置差异持久化到账号
  ///
  /// 仅在账号原代理与更新后不同时才写入存储, 避免无谓 IO。
  void _persistProxyChanges(
    WidgetRef ref,
    List<UserSession> original,
    List<UserSession> updated,
  ) {
    final notifier = ref.read(accountProvider.notifier);
    for (final u in updated) {
      UserSession? o;
      for (final a in original) {
        if (a.token == u.token) {
          o = a;
          break;
        }
      }
      if (o == null) continue;
      final oldProxy = o.proxy ?? '';
      final newProxy = u.proxy ?? '';
      if (oldProxy != newProxy) {
        notifier.updateAccountProxy(u.token, u.proxy);
      }
    }
  }

  /// 启动批量任务 (进度上报/试题答案/下载视频/下载试题)
  ///
  /// 流程 (对齐用户需求):
  ///   1. 弹出 TaskFilterDialog (状态/学科/类型) → 获取作业级筛选配置
  ///   2. 打开功能专属配置页:
  ///      - 进度上报: ReportConfigPage (课程级筛选 + 上报参数)
  ///      - 试题答案: AnswerConfigPage (获取方案 + 课程级筛选)
  ///      - 下载视频: DownloadConfigDialog(mode=video)
  ///      - 下载试题: DownloadConfigDialog(mode=paper)
  ///   3. 创建 BatchTaskExecutor 并弹出进度弹窗执行
  ///
  /// 对齐 Python: gui/dialogs/account.py `_start_batch_*` + BatchOperationWorker
  Future<void> _startBatchTask(
    BuildContext context,
    WidgetRef ref,
    List<UserSession> accounts,
    String taskType, {
    bool parallel = false,
  }) async {
    if (!BatchTaskExecutor.supportedTasks.contains(taskType)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('不支持的任务: $taskType'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    // ─── 第 1 步: 任务筛选弹窗 (状态/学科/类型) ───
    final taskFilterConfig = await TaskFilterDialog.show(
      context,
      taskType: taskType,
    );
    if (taskFilterConfig == null) return; // 用户取消
    if (!context.mounted) return;

    // ─── 第 2 步: 功能专属配置弹窗 ───
    ReportConfig? reportConfig;
    AnswerFilterConfig? answerFilterConfig;
    AnswerConfig? answerConfig;
    DownloadConfig? downloadConfig;

    switch (taskType) {
      case BatchTaskExecutor.kTaskReport:
        reportConfig = await ReportConfigPage.show(context);
        if (reportConfig == null) return;
        break;
      case BatchTaskExecutor.kTaskAnswers:
        final answerResult = await AnswerConfigPage.show(context);
        if (answerResult == null) return;
        answerFilterConfig = answerResult.filterConfig;
        answerConfig = answerResult.config;
        break;
      case BatchTaskExecutor.kTaskDownloadVideo:
        downloadConfig = await DownloadConfigDialog.show(
          context,
          mode: 'video',
        );
        if (downloadConfig == null) return;
        break;
      case BatchTaskExecutor.kTaskDownloadPaper:
        downloadConfig = await DownloadConfigDialog.show(
          context,
          mode: 'paper',
        );
        if (downloadConfig == null) return;
        break;
    }
    if (!context.mounted) return;

    // ─── 第 3 步: 创建执行器并弹出进度弹窗 ───
    final endpointConfig = getIt<EndpointConfig>();
    final executor = BatchTaskExecutor(
      accounts: accounts,
      endpointConfig: endpointConfig,
      taskType: taskType,
      taskFilterConfig: taskFilterConfig,
      reportConfig: reportConfig,
      answerFilterConfig: answerFilterConfig,
      answerConfig: answerConfig,
      downloadConfig: downloadConfig,
      parallel: parallel,
    );

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => _BatchTaskProgressDialog(
        executor: executor,
        accountCount: accounts.length,
      ),
    );
  }

  /// 启动账号保活服务并弹出保活进度弹窗
  ///
  /// 对齐 Python `BatchOperationWorker`: 每账号独立 client + 并行 + 可停止
  /// 不同之处: Python 执行 report/answers/video/paper, 这里执行 keep_alive
  void _startKeepAlive(
    BuildContext context,
    WidgetRef ref,
    List<UserSession> accounts,
  ) {
    final sessions = accounts.where((s) => s.token.isNotEmpty).toList();

    if (sessions.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('没有有效账号可用于保活'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    final endpointConfig = getIt<EndpointConfig>();
    final service = KeepAliveService(
      accounts: sessions,
      endpointConfig: endpointConfig,
    );

    // 启动保活循环 (异步, 不阻塞 UI)
    service.start();

    // 弹出保活进度弹窗 (用户可随时停止)
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => _KeepAliveDialog(
        service: service,
        accountCount: sessions.length,
      ),
    );
  }
}

// ═══════════════════════════════════════════
// 重新登录弹窗 (账号名自动填充, 已记住密码时预填)
// ═══════════════════════════════════════════
class _ReLoginDialog extends StatefulWidget {
  final UserSession account;

  const _ReLoginDialog({required this.account});

  /// 返回确认后的登录凭证 (账号+密码), 取消返回 null
  static Future<({String account, String password})?> show(
    BuildContext context,
    UserSession account,
  ) {
    return showDialog<({String account, String password})>(
      context: context,
      builder: (_) => _ReLoginDialog(account: account),
    );
  }

  @override
  State<_ReLoginDialog> createState() => _ReLoginDialogState();
}

class _ReLoginDialogState extends State<_ReLoginDialog> {
  late final TextEditingController _accountController;
  late final TextEditingController _passwordController;
  final _formKey = GlobalKey<FormState>();
  bool _obscure = true;

  @override
  void initState() {
    super.initState();
    // 账号名自动填充 (account 缺失时回退手机号/用户ID)
    final acc = widget.account.account ?? '';
    _accountController = TextEditingController(
      text: acc.isNotEmpty
          ? acc
          : ((widget.account.mobile ?? '').isNotEmpty
              ? widget.account.mobile!
              : widget.account.userId),
    );
    // 已记录密码 → 自动填充, 可修改后确认
    _passwordController =
        TextEditingController(text: widget.account.password ?? '');
  }

  @override
  void dispose() {
    _accountController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.pop(
      context,
      (
        account: _accountController.text.trim(),
        password: _passwordController.text,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasSavedPassword = (widget.account.password ?? '').isNotEmpty;
    return AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.refresh, size: 20),
          const SizedBox(width: 8),
          const Text('重新登录'),
        ],
      ),
      content: Form(
        key: _formKey,
        child: SizedBox(
          width: 320,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _accountController,
                readOnly: true, // 重新登录目标账号, 自动填充不可改
                decoration: const InputDecoration(
                  labelText: '账号',
                  helperText: '自动填充, 无需修改',
                  prefixIcon: Icon(Icons.person_outline),
                ),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _passwordController,
                autofocus: !hasSavedPassword,
                decoration: InputDecoration(
                  labelText: '密码',
                  helperText: hasSavedPassword ? '已自动填充记住的密码' : null,
                  prefixIcon: const Icon(Icons.lock_outline),
                  suffixIcon: IconButton(
                    icon: Icon(_obscure ? Icons.visibility_off : Icons.visibility),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                ),
                obscureText: _obscure,
                validator: (v) => (v == null || v.isEmpty) ? '请输入密码' : null,
                onFieldSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: 8),
              Text(
                '登录中如触发滑块验证会自动弹出，成功后自动进入首页',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton.icon(
          icon: const Icon(Icons.login, size: 16),
          label: const Text('登录'),
          onPressed: _submit,
        ),
      ],
    );
  }
}

// ═══════════════════════════════════════════
// 登录表单卡片
// ═══════════════════════════════════════════
class _LoginFormCard extends ConsumerWidget {
  final TabController tabController;
  final List<String> methods;
  final bool showBack;
  final VoidCallback onBack;

  const _LoginFormCard({
    required this.tabController,
    required this.methods,
    required this.showBack,
    required this.onBack,
  });

  static const _labels = {
    'password': '密码',
    'qrcode': '扫码',
    'sms': '短信',
    'token': '凭证',
  };

  Widget _formForMethod(String m, bool isLoading) => switch (m) {
        'password' => _PasswordLoginForm(isLoading: isLoading),
        'qrcode' => _QRCodeLoginPanel(isLoading: isLoading),
        'sms' => _SmsLoginForm(isLoading: isLoading),
        'token' => _TokenLoginForm(isLoading: isLoading),
        _ => const SizedBox.shrink(),
      };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authState = ref.watch(authProvider);
    final isLoading = authState is AuthLoading;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            if (showBack)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: onBack,
                  icon: const Icon(Icons.arrow_back, size: 18),
                  label: const Text('返回账号列表'),
                ),
              ),
            if (methods.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 48),
                child: Text(
                  '登录功能已停用',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              )
            else ...[
              TabBar(
                controller: tabController,
                tabs: [for (final m in methods) Tab(text: _labels[m] ?? m)],
              ),
              const SizedBox(height: 24),
              SizedBox(
                height: 280,
                child: TabBarView(
                  controller: tabController,
                  children: [
                    for (final m in methods) _formForMethod(m, isLoading),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════
// 密码登录
// ═══════════════════════════════════════════
class _PasswordLoginForm extends ConsumerStatefulWidget {
  final bool isLoading;
  const _PasswordLoginForm({required this.isLoading});

  @override
  ConsumerState<_PasswordLoginForm> createState() => _PasswordLoginFormState();
}

class _PasswordLoginFormState extends ConsumerState<_PasswordLoginForm> {
  final _accountController = TextEditingController();
  final _passwordController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _obscure = true;

  @override
  void dispose() {
    _accountController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    ref.read(authProvider.notifier).loginWithPassword(
          account: _accountController.text.trim(),
          password: _passwordController.text,
        );
  }

  @override
  Widget build(BuildContext context) {
    return Form(
      key: _formKey,
      child: Column(
        children: [
          TextFormField(
            controller: _accountController,
            decoration: const InputDecoration(
              labelText: '手机号 / 账号',
              prefixIcon: Icon(Icons.person_outline),
            ),
            keyboardType: TextInputType.phone,
            validator: (v) => (v == null || v.isEmpty) ? '请输入账号' : null,
            onFieldSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: _passwordController,
            decoration: InputDecoration(
              labelText: '密码',
              prefixIcon: const Icon(Icons.lock_outline),
              suffixIcon: IconButton(
                icon: Icon(_obscure ? Icons.visibility_off : Icons.visibility),
                onPressed: () => setState(() => _obscure = !_obscure),
              ),
            ),
            obscureText: _obscure,
            validator: (v) => (v == null || v.isEmpty) ? '请输入密码' : null,
            onFieldSubmitted: (_) => _submit(),
          ),
          const Spacer(),
          SizedBox(
            width: double.infinity,
            height: 48,
            child: FilledButton(
              onPressed: widget.isLoading ? null : _submit,
              child: widget.isLoading
                  ? const SizedBox(
                      width: 24, height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('登录'),
            ),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════
// 扫码登录
// ═══════════════════════════════════════════
class _QRCodeLoginPanel extends ConsumerStatefulWidget {
  final bool isLoading;
  const _QRCodeLoginPanel({required this.isLoading});

  @override
  ConsumerState<_QRCodeLoginPanel> createState() => _QRCodeLoginPanelState();
}

class _QRCodeLoginPanelState extends ConsumerState<_QRCodeLoginPanel> {
  String? _qrData;
  String? _uuid;
  Timer? _pollTimer;
  String _statusText = '点击生成二维码';

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _generateQR() async {
    _pollTimer?.cancel();
    setState(() => _statusText = '生成中...');
    final result = await ref.read(authProvider.notifier).generateQRCode();
    if (result == null) {
      setState(() => _statusText = '生成失败，请重试');
      return;
    }
    setState(() {
      _qrData = result.qrcodeUrl;
      _uuid = result.uuid;
      _statusText = '请使用 e网通 APP 扫码';
    });
    _startPolling();
  }

  void _startPolling() {
    _pollTimer = Timer.periodic(const Duration(seconds: 3), (_) async {
      if (_uuid == null || !mounted) return;
      try {
        final result =
            await ref.read(authProvider.notifier).checkQRCodeStatus(_uuid!);
        if (!mounted) return;
        switch (result.status) {
          case 2:
            setState(() => _statusText = '已扫码，请在手机上确认');
          case 3:
            _pollTimer?.cancel();
            setState(() {
              _statusText = '二维码已过期';
              _qrData = null;
            });
          case 4:
            _pollTimer?.cancel();
            if (result.token != null && result.token!.isNotEmpty) {
              ref.read(authProvider.notifier).completeQRCodeLogin(result.token!);
            }
          case 5:
            _pollTimer?.cancel();
            setState(() => _statusText = '已取消');
        }
      } catch (_) {}
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: Center(
            child: _qrData != null
                ? QrImageView(
                    data: _qrData!,
                    version: QrVersions.auto,
                    size: 180,
                    backgroundColor: Colors.white,
                  )
                : IconButton(
                    iconSize: 80,
                    icon: const Icon(Icons.qr_code_2_outlined),
                    onPressed: _generateQR,
                  ),
          ),
        ),
        Text(_statusText, style: Theme.of(context).textTheme.bodyMedium),
        const SizedBox(height: 12),
        if (_qrData != null)
          TextButton.icon(
            icon: const Icon(Icons.refresh),
            label: const Text('刷新二维码'),
            onPressed: _generateQR,
          ),
      ],
    );
  }
}

// ═══════════════════════════════════════════
// 短信登录
// ═══════════════════════════════════════════
class _SmsLoginForm extends ConsumerStatefulWidget {
  final bool isLoading;
  const _SmsLoginForm({required this.isLoading});

  @override
  ConsumerState<_SmsLoginForm> createState() => _SmsLoginFormState();
}

class _SmsLoginFormState extends ConsumerState<_SmsLoginForm> {
  final _phoneController = TextEditingController();
  final _codeController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  int _countdown = 0;
  Timer? _countdownTimer;

  @override
  void dispose() {
    _phoneController.dispose();
    _codeController.dispose();
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
    final error = await ref.read(authProvider.notifier).sendSmsCode(phone);
    if (error == 'CAPTCHA_REQUIRED') {
      // 需要滑块验证
      if (!mounted) return;
      final token = await CaptchaDialog.show(
        context,
        bizCode: CryptoConstants.smsCaptchaBizCode,
      );
      if (token == null || !mounted) return;
      final retryError = await ref
          .read(authProvider.notifier)
          .sendSmsCode(phone, captchaToken: token);
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

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    ref.read(authProvider.notifier).loginWithSms(
          phone: _phoneController.text.trim(),
          smsCode: _codeController.text.trim(),
        );
  }

  @override
  Widget build(BuildContext context) {
    return Form(
      key: _formKey,
      child: Column(
        children: [
          TextFormField(
            controller: _phoneController,
            decoration: const InputDecoration(
              labelText: '手机号',
              prefixIcon: Icon(Icons.phone_android_outlined),
            ),
            keyboardType: TextInputType.phone,
            validator: (v) => (v == null || v.isEmpty) ? '请输入手机号' : null,
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
                  validator: (v) => (v == null || v.isEmpty) ? '请输入验证码' : null,
                  onFieldSubmitted: (_) => _submit(),
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
          const Spacer(),
          SizedBox(
            width: double.infinity,
            height: 48,
            child: FilledButton(
              onPressed: widget.isLoading ? null : _submit,
              child: widget.isLoading
                  ? const SizedBox(
                      width: 24, height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('登录'),
            ),
          ),
          if (RiskControlGate.isFeatureEnabled('login.register')) ...[
            const SizedBox(height: 8),
            Center(
              child: TextButton(
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                onPressed: () => RegisterDialog.show(context),
                child: const Text(
                  '还没有账号？立即注册',
                  style: TextStyle(fontSize: 12),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════
// Token 登录
// ═══════════════════════════════════════════
class _TokenLoginForm extends ConsumerStatefulWidget {
  final bool isLoading;
  const _TokenLoginForm({required this.isLoading});

  @override
  ConsumerState<_TokenLoginForm> createState() => _TokenLoginFormState();
}

class _TokenLoginFormState extends ConsumerState<_TokenLoginForm> {
  final _tokenController = TextEditingController();

  @override
  void dispose() {
    _tokenController.dispose();
    super.dispose();
  }

  void _submit() {
    final token = _tokenController.text.trim();
    if (token.isEmpty) return;
    ref.read(authProvider.notifier).loginWithToken(token);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        TextField(
          controller: _tokenController,
          decoration: const InputDecoration(
            labelText: 'Token',
            hintText: 'userId-platform-tokenString',
            prefixIcon: Icon(Icons.key_outlined),
          ),
          maxLines: 3,
          onSubmitted: (_) => _submit(),
        ),
        const SizedBox(height: 12),
        Text(
          '格式: userId-platform-token\n可从浏览器 Cookie 中获取',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
        const Spacer(),
        SizedBox(
          width: double.infinity,
          height: 48,
          child: FilledButton(
            onPressed: widget.isLoading ? null : _submit,
            child: widget.isLoading
                ? const SizedBox(
                    width: 24, height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Token 登录'),
          ),
        ),
      ],
    );
  }
}

// ═══════════════════════════════════════════
// 批量任务选择对话框
// ═══════════════════════════════════════════
class _BatchTaskDialog extends StatefulWidget {
  /// 本次批量任务覆盖的账号列表 (代理设置可在此修改)
  final List<UserSession> accounts;

  /// 确认回调: 返回任务类型 + 并行开关 + (可能已修改代理的) 账号列表
  final void Function(String task, bool parallel, List<UserSession> accounts)
      onConfirm;

  const _BatchTaskDialog({
    required this.accounts,
    required this.onConfirm,
  });

  @override
  State<_BatchTaskDialog> createState() => _BatchTaskDialogState();
}

class _BatchTaskDialogState extends State<_BatchTaskDialog> {
  /// 批量任务列表
  ///
  /// 对齐 Python `gui/dialogs/batch_operation.py` 支持的 4 种操作类型
  /// (report/answers/video/paper), 并在第一项新增"保持账号活跃"
  /// (Python 未实现, Flutter 新增): 死循环定时 getUser 防止 token 过期。
  static const _tasks = [
    '保持账号活跃',
    '进度上报',
    '试题答案',
    '下载视频',
    '下载试题',
  ];

  /// 任务描述 (副标题)
  static const _taskDescriptions = <String, String>{
    '保持账号活跃': '定时查询用户信息, 防止 token 过期 (需手动停止)',
    '进度上报': '对所有课程的视频播放进度批量上报',
    '试题答案': '获取所有课程的试题答案并导出 PDF',
    '下载视频': '下载所有课程视频为 MP4',
    '下载试题': '下载所有课程试题为 PDF',
  };

  String? _selected;

  /// 是否多账号并行运行
  ///
  /// false (默认): 串行执行, 一个账号完成后再执行下一个
  /// true: 所有账号同时执行 (每账号独立 DioClient, 无 token 冲突)
  bool _parallel = false;

  /// 当前账号列表 (代理设置可更新)
  late List<UserSession> _accounts = List.of(widget.accounts);

  IconData _taskIcon(String task) {
    switch (task) {
      case '保持账号活跃':
        return Icons.favorite_outline;
      case '进度上报':
        return Icons.trending_up;
      case '试题答案':
        return Icons.question_answer_outlined;
      case '下载视频':
        return Icons.video_library_outlined;
      case '下载试题':
        return Icons.picture_as_pdf_outlined;
      default:
        return Icons.task_outlined;
    }
  }

  /// 已设代理的账号数
  int get _proxyCount =>
      _accounts.where((a) => (a.proxy ?? '').trim().isNotEmpty).length;

  /// 打开代理设置弹窗
  Future<void> _openProxySettings() async {
    final result = await showDialog<List<UserSession>>(
      context: context,
      builder: (_) => _ProxySettingsDialog(accounts: _accounts),
    );
    if (result != null && mounted) {
      setState(() => _accounts = result);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return AlertDialog(
      icon: Icon(Icons.playlist_play, color: cs.primary),
      title: Text('批量运行任务'),
      content: SizedBox(
        width: 420,
        // 内容可滚动: 小屏/低窗口下 5 个任务卡片 + 代理行可能超过弹窗最大高度,
        // 避免 RenderFlex overflow
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
            Text(
              '已选 ${widget.accounts.length} 个账号 · 选择要批量执行的任务',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            ..._tasks.map((task) {
              final selected = _selected == task;
              return Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Material(
                  color: selected
                      ? cs.secondaryContainer
                      : cs.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(12),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: () => setState(() => _selected = task),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 10),
                      child: Row(
                        children: [
                          Icon(
                            _taskIcon(task),
                            size: 20,
                            color: selected
                                ? cs.onSecondaryContainer
                                : cs.onSurfaceVariant,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  task,
                                  style: theme.textTheme.bodyLarge?.copyWith(
                                    color: selected
                                        ? cs.onSecondaryContainer
                                        : cs.onSurface,
                                    fontWeight: selected
                                        ? FontWeight.w600
                                        : FontWeight.w500,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  _taskDescriptions[task] ?? '',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: selected
                                        ? cs.onSecondaryContainer
                                        : cs.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Icon(
                            selected
                                ? Icons.check_circle
                                : Icons.radio_button_unchecked,
                            size: 20,
                            color: selected ? cs.primary : cs.outline,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            }),
            const SizedBox(height: 4),
            // 代理设置入口
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: cs.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Icon(Icons.vpn_key_outlined,
                      size: 18, color: cs.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _proxyCount > 0
                          ? '$_proxyCount/${_accounts.length} 个账号已设代理'
                          : '未设置代理 (全部直连)',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: _openProxySettings,
                    icon: const Icon(Icons.tune, size: 16),
                    label: const Text('代理设置'),
                  ),
                ],
              ),
            ),
            ],
          ),
        ),
      ),
      actions: [
        Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: InkWell(
                onTap: () => setState(() => _parallel = !_parallel),
                borderRadius: BorderRadius.circular(4),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 4, vertical: 2),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Checkbox(
                        value: _parallel,
                        onChanged: (v) =>
                            setState(() => _parallel = v ?? false),
                      ),
                      const Text('多账号并行运行'),
                    ],
                  ),
                ),
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: _selected == null
                      ? null
                      : () => widget.onConfirm(_selected!, _parallel, _accounts),
                  child: const Text('运行'),
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }
}

// ═══════════════════════════════════════════
// 代理设置对话框 (每账号独立代理)
// ═══════════════════════════════════════════
///
/// 支持两种配置方式:
/// 1. 手动: 每个账号一行输入框, 直接填写 `host:port`
/// 2. TXT 导入自动分配: 从 txt 文件逐行读取代理列表, 自动分配给各账号
///    - 代理数 >= 账号数: 每账号分配独立代理
///    - 代理数 < 账号数: 循环复用 (部分账号共用同一代理)
class _ProxySettingsDialog extends StatefulWidget {
  final List<UserSession> accounts;

  const _ProxySettingsDialog({required this.accounts});

  @override
  State<_ProxySettingsDialog> createState() => _ProxySettingsDialogState();
}

class _ProxySettingsDialogState extends State<_ProxySettingsDialog> {
  late final List<UserSession> _accounts;
  late final List<TextEditingController> _controllers;

  /// 最近一次导入的代理池 (用于自动分配)
  List<String> _pool = [];

  /// 确认时是否将代理保存到账号 (持久化)
  bool _saveToAccount = true;

  @override
  void initState() {
    super.initState();
    _accounts = List.of(widget.accounts);
    _controllers = [
      for (final a in _accounts)
        TextEditingController(text: a.proxy ?? ''),
    ];
  }

  @override
  void dispose() {
    for (final c in _controllers) {
      c.dispose();
    }
    super.dispose();
  }

  /// 确认: 返回更新过代理的账号列表 (pop 结果)
  ///
  /// withProxy 空值归一为 null = 清除代理 (copyWith 传 null 保留原值, 无法清除)
  List<UserSession> _buildResult() {
    return [
      for (var i = 0; i < _accounts.length; i++)
        _accounts[i].withProxy(_controllers[i].text),
    ];
  }

  /// 从 TXT 导入代理列表并自动分配
  Future<void> _importTxt() async {
    final picked = await FilePicker.platform.pickFiles(type: FileType.any);
    if (picked == null || picked.files.isEmpty) return;

    final file = picked.files.single;
    String content;
    try {
      content = await file.xFile.readAsString();
    } catch (_) {
      final bytes = file.bytes;
      if (bytes == null) {
        _toast('无法读取文件内容');
        return;
      }
      content = utf8.decode(bytes, allowMalformed: true);
    }

    final proxies = parseProxyLines(content);
    if (proxies.isEmpty) {
      _toast('未解析到有效代理 (支持 ip:port / http:// / socks5:// / socks5h://, # 为注释)');
      return;
    }

    setState(() {
      _pool = proxies;
      _assignFromPool();
    });
    _toast('已导入 ${proxies.length} 个代理并自动分配');
  }

  /// 从代理池自动分配给各账号 (循环取模, 天然支持"代理少账号多")
  void _assignFromPool() {
    if (_pool.isEmpty) return;
    for (var i = 0; i < _accounts.length; i++) {
      _controllers[i].text = _pool[i % _pool.length];
    }
  }

  /// 清空全部代理
  void _clearAll() {
    setState(() {
      for (final c in _controllers) {
        c.text = '';
      }
    });
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );
  }

  /// 分配策略说明文案
  String get _strategyHint {
    final accountsCount = _accounts.length;
    if (_pool.isEmpty) return '导入 TXT 后自动分配; 代理数 < 账号数时自动循环复用';
    if (_pool.length >= accountsCount) {
      return '代理 ${_pool.length} 个 ≥ 账号 $accountsCount 个 → 每账号独立代理';
    }
    return '代理 ${_pool.length} 个 < 账号 $accountsCount 个 → 循环复用 (部分账号共用)';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final contentHeight =
        (MediaQuery.sizeOf(context).height * 0.62).clamp(320.0, 520.0);

    return AlertDialog(
      icon: Icon(Icons.vpn_key_outlined, color: cs.primary),
      title: Text('代理设置 (${_accounts.length} 个账号)'),
      content: SizedBox(
        width: 560,
        height: contentHeight,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 操作区
            Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                FilledButton.tonalIcon(
                  onPressed: _importTxt,
                  icon: const Icon(Icons.upload_file, size: 16),
                  label: const Text('导入 TXT'),
                ),
                OutlinedButton.icon(
                  onPressed: _pool.isEmpty ? null : _assignFromPool,
                  icon: const Icon(Icons.auto_awesome, size: 16),
                  label: const Text('自动分配'),
                ),
                TextButton.icon(
                  onPressed: _clearAll,
                  icon: const Icon(Icons.cleaning_services_outlined, size: 16),
                  label: const Text('清空全部'),
                ),
                const Spacer(),
                // 保存开关
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('保存到账号',
                        style: theme.textTheme.labelMedium),
                    Switch(
                      value: _saveToAccount,
                      onChanged: (v) => setState(() => _saveToAccount = v),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 4),
            // 策略提示
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: cs.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(Icons.info_outline, size: 14, color: cs.primary),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _strategyHint,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '每行一个代理: ip:port(默认 http)、socks5://ip:port、socks5h://ip:port (# 为注释)',
              style: theme.textTheme.labelSmall?.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            // 账号代理列表
            Expanded(
              child: ListView.separated(
                itemCount: _accounts.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final acc = _accounts[i];
                  final name = acc.displayName ??
                      acc.account ??
                      acc.userId;
                  return Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 130,
                          child: Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: TextField(
                            controller: _controllers[i],
                            decoration: const InputDecoration(
                              isDense: true,
                              hintText: 'ip:port (留空 = 直连)',
                              prefixIcon: Icon(Icons.public, size: 18),
                              contentPadding: EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 8),
                            ),
                            style: theme.textTheme.bodySmall?.copyWith(
                              fontFamily: 'monospace',
                            ),
                            onChanged: (_) => setState(() {}),
                          ),
                        ),
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
        FilledButton(
          onPressed: () {
            final result = _buildResult();
            if (!_saveToAccount) {
              // 不持久化: 仅本次运行生效 (返回结果不带持久化, 由上层自行决定)
            }
            Navigator.of(context).pop(result);
          },
          child: const Text('应用'),
        ),
      ],
    );
  }
}

// ═══════════════════════════════════════════
// 账号保活进度弹窗
// ═══════════════════════════════════════════
class _KeepAliveDialog extends StatefulWidget {
  final KeepAliveService service;
  final int accountCount;

  const _KeepAliveDialog({
    required this.service,
    required this.accountCount,
  });

  @override
  State<_KeepAliveDialog> createState() => _KeepAliveDialogState();
}

class _KeepAliveDialogState extends State<_KeepAliveDialog> {
  /// 日志容量上限 (防内存膨胀)
  static const int _maxLogs = 800;

  final ScrollController _logScrollController = ScrollController();
  final List<ProgressLogEvent> _logs = [];
  StreamSubscription<ProgressLogEvent>? _logSub;
  StreamSubscription<Map<String, AccountKeepAliveState>>? _stateSub;
  Map<String, AccountKeepAliveState> _states = {};
  bool _stopped = false;

  /// 帧合并调度: 每帧最多一次 setState, 防止多账号轮询时的日志/状态
  /// 事件风暴把 UI 线程打满 (与批量进度弹窗同一模式)
  bool _rebuildScheduled = false;

  @override
  void initState() {
    super.initState();
    _states = widget.service.states;
    _logSub = widget.service.logStream.listen(_onLog);
    _stateSub = widget.service.stateStream.listen((s) {
      try {
        _states = s;
        _scheduleRebuild();
      } catch (e) {
        debugPrint('保活状态处理异常(已兜底): $e');
      }
    });
  }

  @override
  void dispose() {
    _logSub?.cancel();
    _stateSub?.cancel();
    _logScrollController.dispose();
    super.dispose();
  }

  /// 帧合并重建 (addPostFrameCallback: 帧后执行, 不干扰 build/layout 管线)
  void _scheduleRebuild() {
    if (_rebuildScheduled || !mounted) return;
    _rebuildScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _rebuildScheduled = false;
      try {
        if (mounted) setState(() {});
        _maybeAutoScroll();
      } catch (e) {
        debugPrint('保活弹窗帧回调异常(已兜底): $e');
      }
    });
  }

  void _onLog(ProgressLogEvent event) {
    if (!mounted) return;
    try {
      _logs.add(event);
      if (_logs.length > _maxLogs) {
        _logs.removeRange(0, _logs.length - _maxLogs);
      }
      _scheduleRebuild();
    } catch (e) {
      debugPrint('保活日志处理异常(已兜底): $e');
    }
  }

  /// 自动滚动到底部 (仅用户停留在底部附近时)
  void _maybeAutoScroll() {
    try {
      if (!_logScrollController.hasClients) return;
      final pos = _logScrollController.position;
      if (pos.pixels >= pos.maxScrollExtent - 120) {
        _logScrollController.jumpTo(pos.maxScrollExtent);
      }
    } catch (e) {
      debugPrint('保活自动滚动异常(已兜底): $e');
    }
  }

  Future<void> _stop() async {
    widget.service.stop();
    if (mounted) setState(() => _stopped = true);
    // 等待循环退出后关闭弹窗
    await Future.delayed(const Duration(milliseconds: 500));
    if (mounted) {
      widget.service.dispose();
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 内容区高度自适应屏幕: 桌面 480, 小屏/横屏取 70% 屏高 (最低 320), 防止溢出
    final contentHeight = (MediaQuery.sizeOf(context).height * 0.7).clamp(320.0, 480.0);
    final states = _states.values.toList();
    final aliveCount = states.where((s) => s.status == KeepAliveStatus.alive).length;
    final deadCount = states.where((s) => s.status == KeepAliveStatus.dead).length;

    return AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.favorite, color: Colors.redAccent, size: 20),
          const SizedBox(width: 8),
          Text('保持账号活跃 (${widget.accountCount} 个账号)'),
          const Spacer(),
          if (_stopped)
            const Padding(
              padding: EdgeInsets.only(right: 8),
              child: SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
        ],
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: AppBreakpoints.formMaxWidth),
        child: SizedBox(
          // 必须固定宽度 (不能用 double.infinity), 原因见批量进度弹窗注释
          width: 520,
          height: contentHeight,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 顶部统计条
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Text('第 ${widget.service.round} 轮'),
                    const SizedBox(width: 16),
                    Text('存活 $aliveCount', style: TextStyle(color: Colors.green[700])),
                    const SizedBox(width: 16),
                    Text('失效 $deadCount', style: const TextStyle(color: Colors.red)),
                  ],
                ),
              ),
            const SizedBox(height: 8),
            // 账号状态列表
            // 注意: 不能用 shrinkWrap (AlertDialog 内容被 IntrinsicWidth 包裹,
            // shrink-wrap 视口不支持固有尺寸测量, 会抛
            // "RenderShrinkWrappingViewport does not support returning intrinsic
            // dimensions" 导致弹窗布局失败→程序卡死); 此处有界(Expanded), 无需 shrinkWrap
            Expanded(
              flex: 3,
              child: ListView(
                children: states.map((s) {
                  final name = s.account.displayName ??
                      s.account.account ??
                      s.account.userId;
                  return ListTile(
                    dense: true,
                    leading: _statusDot(s.status),
                    title: Text(name, overflow: TextOverflow.ellipsis),
                    subtitle: Text(
                      _stateSubtitle(s),
                      style: theme.textTheme.bodySmall,
                    ),
                    trailing: s.failCount > 0
                        ? Text('失败 ${s.failCount}',
                            style: TextStyle(color: Colors.red[700], fontSize: 12))
                        : null,
                  );
                }).toList(),
              ),
            ),
            const Divider(),
            // 日志区域
            Expanded(
              flex: 2,
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.black87,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: ListView.builder(
                  controller: _logScrollController,
                  itemCount: _logs.length,
                  itemBuilder: (_, i) {
                    final log = _logs[i];
                    final color = switch (log.level) {
                      LogLevel.debug => Colors.white38,
                      LogLevel.success => Colors.greenAccent,
                      LogLevel.warning => Colors.yellowAccent,
                      LogLevel.error => Colors.redAccent,
                      LogLevel.info => Colors.white70,
                    };
                    return Text(
                      '[${_timeStr(log.timestamp)}] ${log.message}',
                      style: TextStyle(
                        color: color,
                        fontSize: 12,
                        fontFamily: 'Consolas',
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _stopped ? null : _stop,
          child: Text(_stopped ? '正在停止...' : '停止保活'),
        ),
      ],
    );
  }

  Widget _statusDot(KeepAliveStatus status) {
    final color = switch (status) {
      KeepAliveStatus.idle => Colors.grey,
      KeepAliveStatus.checking => Colors.orange,
      KeepAliveStatus.alive => Colors.green,
      KeepAliveStatus.dead => Colors.red,
    };
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
      ),
    );
  }

  String _stateSubtitle(AccountKeepAliveState s) {
    final parts = <String>[];
    if (s.lastCheck != null) {
      parts.add('最近: ${_timeStr(s.lastCheck!)}');
    }
    if (s.message.isNotEmpty) parts.add(s.message);
    return parts.join(' | ');
  }

  String _timeStr(DateTime t) {
    final h = t.hour.toString().padLeft(2, '0');
    final m = t.minute.toString().padLeft(2, '0');
    final s = t.second.toString().padLeft(2, '0');
    return '$h:$m:$s';
  }
}

// ═══════════════════════════════════════════
// 批量任务进度弹窗 (MD3)
// ═══════════════════════════════════════════
///
/// 设计要点 (对齐需求):
/// 1. 性能修复: 采用"帧合并"策略, 日志/状态事件风暴时每帧最多重建一次,
///    解决"一批量执行就卡死"的问题 (原实现每个日志/状态事件都立即 setState,
///    高频事件下 UI 线程被重建占满导致卡死)。
/// 2. 便捷操作: 顶部账号 chips 切换查看单个账号的
///    任务进度 / 任务日志 / 任务详情, 也可选"全部"总览。
/// 3. MD3: SegmentedButton 视图切换 + ChoiceChip 账号选择 + 圆角卡片 + 状态徽章。
class _BatchTaskProgressDialog extends StatefulWidget {
  final BatchTaskExecutor executor;
  final int accountCount;

  const _BatchTaskProgressDialog({
    required this.executor,
    required this.accountCount,
  });

  @override
  State<_BatchTaskProgressDialog> createState() =>
      _BatchTaskProgressDialogState();
}

class _BatchTaskProgressDialogState extends State<_BatchTaskProgressDialog> {
  /// 日志容量上限 (防内存膨胀; 超限丢弃最旧)
  static const int _maxLogs = 800;

  final ScrollController _logScrollController = ScrollController();
  final List<ProgressLogEvent> _logs = [];
  StreamSubscription<ProgressLogEvent>? _logSub;
  StreamSubscription<Map<String, AccountBatchState>>? _stateSub;
  Map<String, AccountBatchState> _states = {};
  bool _stopped = false;
  bool _finished = false;
  Timer? _finishCheck;

  /// 当前选中账号 token (null = 全部账号总览)
  String? _selectedToken;

  /// 当前视图: 0=进度 1=日志 2=详情
  int _viewIndex = 0;

  // ─── 帧合并调度 (修复卡死的核心) ───
  // 批量任务会产生大量日志/状态事件; 若每个事件都立即 setState 重建整个弹窗,
  // 高频事件 (并行 5 账号 × 每课程多条日志) 会把 UI 线程打满 → 界面卡死。
  // 方案: 事件只标记"需要重建", 由 scheduleFrameCallback 保证每帧最多重建一次,
  // 事件风暴被合并到帧边界, UI 始终保持响应。
  bool _rebuildScheduled = false;

  @override
  void initState() {
    super.initState();
    _states = widget.executor.states;
    // 先建立订阅, 再启动 executor, 避免首条日志丢失
    // (StreamController.broadcast() 无订阅时数据会丢弃)
    _logSub = widget.executor.logStream.listen(_onLog);
    _stateSub = widget.executor.stateStream.listen((s) {
      try {
        _states = s;
        _scheduleRebuild();
        _checkFinished();
      } catch (e) {
        debugPrint('批量任务状态处理异常(已兜底): $e');
      }
    });
    // 定时检查任务是否结束 (兜底)
    _finishCheck = Timer.periodic(const Duration(seconds: 1), (_) {
      _checkFinished();
    });
    // 启动批量任务 (订阅已建立, 日志不会丢失)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.executor.start();
    });
  }

  @override
  void dispose() {
    _logSub?.cancel();
    _stateSub?.cancel();
    _finishCheck?.cancel();
    _logScrollController.dispose();
    super.dispose();
  }

  /// 标记界面需重建: 每帧最多合并为一次 setState (事件风暴防卡死)
  ///
  /// 采用 [addPostFrameCallback] (当前帧绘制完成后) 调度, 而不是
  /// scheduleFrameCallback (帧开始前): 确保 setState/jumpTo 永远不会在
  /// 框架的 build/layout 阶段执行, 避免破坏帧管线导致
  /// "Cannot hit test a render box with no size" 类崩溃。
  /// 回调整体 try/catch 兜底: 本弹窗不得向事件分发链路泄漏未捕获异常。
  void _scheduleRebuild() {
    if (_rebuildScheduled || !mounted) return;
    _rebuildScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _rebuildScheduled = false;
      try {
        if (mounted) setState(() {});
        _maybeAutoScroll();
      } catch (e) {
        debugPrint('批量任务弹窗帧回调异常(已兜底): $e');
      }
    });
  }

  void _onLog(ProgressLogEvent event) {
    if (!mounted) return;
    try {
      _logs.add(event);
      if (_logs.length > _maxLogs) {
        _logs.removeRange(0, _logs.length - _maxLogs);
      }
      _scheduleRebuild();
    } catch (e) {
      debugPrint('批量任务日志处理异常(已兜底): $e');
    }
  }

  /// 自动滚动到底部 (仅日志视图且用户停留在底部附近时, 避免强制滚动打断查看)
  void _maybeAutoScroll() {
    try {
      if (_viewIndex != 1 || !_logScrollController.hasClients) return;
      final pos = _logScrollController.position;
      if (pos.pixels >= pos.maxScrollExtent - 120) {
        _logScrollController.jumpTo(pos.maxScrollExtent);
      }
    } catch (e) {
      // 防御: 滚动控制器可能在帧回调执行间隙被释放
      debugPrint('批量任务弹窗自动滚动异常(已兜底): $e');
    }
  }

  void _checkFinished() {
    // 全部账号处理完毕 (done / failed) 则任务结束
    final states = _states.values.toList();
    if (states.isEmpty) return;
    final allDone = states.every(
      (s) => s.status == BatchStatus.done || s.status == BatchStatus.failed,
    );
    if (allDone && !_finished) {
      _finished = true;
      if (mounted) setState(() {});
    }
  }

  Future<void> _stop() async {
    widget.executor.stop();
    if (mounted) setState(() => _stopped = true);
    // 等待循环退出后关闭弹窗
    await Future.delayed(const Duration(milliseconds: 500));
    if (mounted) {
      widget.executor.dispose();
      Navigator.of(context).pop();
    }
  }

  Future<void> _close() async {
    widget.executor.dispose();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    // 内容区高度自适应屏幕: 桌面 600, 小屏/横屏取 72% 屏高 (最低 360), 防止溢出
    final contentHeight =
        (MediaQuery.sizeOf(context).height * 0.72).clamp(360.0, 600.0);
    final states = _states.values.toList();
    final doneCount =
        states.where((s) => s.status == BatchStatus.done).length;
    final failCount =
        states.where((s) => s.status == BatchStatus.failed).length;
    final totalCourses = states.fold(0, (a, s) => a + s.totalCourses);
    final processedCourses =
        states.fold(0, (a, s) => a + s.processedCourses);
    final overall = totalCourses > 0 ? processedCourses / totalCourses : 0.0;
    final running = !_stopped && !_finished;

    return AlertDialog(
      icon: running ? Icon(_taskIcon(), color: cs.primary) : null,
      title: Row(
        children: [
          if (running) ...[
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 10),
          ],
          Expanded(child: Text(widget.executor.taskType)),
          _StatusBadge(
            done: doneCount,
            fail: failCount,
            total: widget.accountCount,
            finished: _finished,
          ),
          const SizedBox(width: 8),
          Text(
            '${widget.accountCount} 个账号',
            style: theme.textTheme.bodySmall?.copyWith(
              color: cs.onSurfaceVariant,
            ),
          ),
        ],
      ),
      contentPadding: const EdgeInsets.fromLTRB(24, 8, 24, 4),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: AppBreakpoints.loginPanelMaxWidth),
        child: SizedBox(
          // 必须固定宽度 (不能用 double.infinity): AlertDialog 内容被
          // IntrinsicWidth 包裹, width:∞ 会让固有宽度查询穿透到 ListView
          // (viewport 不支持固有尺寸测量) → 弹窗布局失败 → 程序卡死
          width: 640,
          height: contentHeight,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 总进度条 + 统计
              Card(
                elevation: 0,
                color: cs.surfaceContainerHigh,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          _StatItem(
                            icon: Icons.check_circle,
                            iconColor: cs.primary,
                            value: '$doneCount',
                            label: '完成',
                          ),
                          const SizedBox(width: 20),
                          _StatItem(
                            icon: Icons.error_outline,
                            iconColor: cs.error,
                            value: '$failCount',
                            label: '失败',
                          ),
                          const SizedBox(width: 20),
                          _StatItem(
                            icon: Icons.book_outlined,
                            iconColor: cs.onSurfaceVariant,
                            value: '$processedCourses/$totalCourses',
                            label: '课程',
                          ),
                          const Spacer(),
                          Text(
                            '${(overall * 100).toInt()}%',
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontFamily: 'monospace',
                              color: cs.primary,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: overall,
                          minHeight: 8,
                          backgroundColor: cs.surfaceContainerHighest,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 10),
              // 账号切换 chips
              _buildAccountChips(cs, states),
              const SizedBox(height: 8),
              // 视图切换 (MD3 SegmentedButton)
              Center(
                child: SegmentedButton<int>(
                  segments: const [
                    ButtonSegment(
                      value: 0,
                      icon: Icon(Icons.show_chart, size: 16),
                      label: Text('进度'),
                    ),
                    ButtonSegment(
                      value: 1,
                      icon: Icon(Icons.article_outlined, size: 16),
                      label: Text('日志'),
                    ),
                    ButtonSegment(
                      value: 2,
                      icon: Icon(Icons.info_outline, size: 16),
                      label: Text('详情'),
                    ),
                  ],
                  selected: {_viewIndex},
                  onSelectionChanged: (s) =>
                      setState(() => _viewIndex = s.first),
                  showSelectedIcon: false,
                  style: const ButtonStyle(
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              // 视图内容
              Expanded(
                child: switch (_viewIndex) {
                  0 => _buildProgressTab(theme),
                  1 => _buildLogsTab(theme),
                  _ => _buildDetailsTab(theme),
                },
              ),
            ],
          ),
        ),
      ),
      actions: [
        if (_finished)
          FilledButton(
            onPressed: _close,
            child: const Text('关闭'),
          )
        else
          FilledButton.tonal(
            onPressed: _stopped ? null : _stop,
            style: FilledButton.styleFrom(
              backgroundColor: cs.errorContainer,
              foregroundColor: cs.onErrorContainer,
              disabledBackgroundColor:
                  cs.errorContainer.withValues(alpha: 0.5),
              disabledForegroundColor:
                  cs.onErrorContainer.withValues(alpha: 0.5),
            ),
            child: Text(_stopped ? '正在停止...' : '停止'),
          ),
      ],
    );
  }

  // ─── 账号切换 chips ───

  Widget _buildAccountChips(ColorScheme cs, List<AccountBatchState> states) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          ChoiceChip(
            avatar: Icon(
              Icons.grid_view,
              size: 16,
              color: _selectedToken == null
                  ? cs.onSecondaryContainer
                  : cs.onSurfaceVariant,
            ),
            label: const Text('全部'),
            selected: _selectedToken == null,
            onSelected: (_) => setState(() => _selectedToken = null),
            showCheckmark: false,
          ),
          for (final s in states) ...[
            const SizedBox(width: 6),
            ChoiceChip(
              avatar: _statusDot(s.status),
              label: Text(
                s.account.displayName ??
                    s.account.account ??
                    s.account.userId,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              selected: _selectedToken == s.account.token,
              onSelected: (_) =>
                  setState(() => _selectedToken = s.account.token),
              showCheckmark: false,
            ),
          ],
        ],
      ),
    );
  }

  // ─── 视图: 进度 ───

  Widget _buildProgressTab(ThemeData theme) {
    final token = _selectedToken;
    final list = token == null
        ? _states.values.toList()
        : (_states[token] == null
            ? const <AccountBatchState>[]
            : [_states[token]!]);
    if (list.isEmpty) {
      return Center(
        child: Text('无账号数据', style: theme.textTheme.bodyMedium),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.only(bottom: 4),
      itemCount: list.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (_, i) => _AccountProgressCard(
        state: list[i],
        focus: token != null,
      ),
    );
  }

  // ─── 视图: 日志 (按当前选中账号过滤) ───

  List<ProgressLogEvent> get _filteredLogs {
    final token = _selectedToken;
    if (token == null) return _logs;
    return _logs.where((l) => l.accountToken == token).toList();
  }

  Widget _buildLogsTab(ThemeData theme) {
    final cs = theme.colorScheme;
    final filtered = _filteredLogs;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('日志', style: theme.textTheme.labelMedium),
            const SizedBox(width: 8),
            Text(
              '${filtered.length}/${_logs.length} 条',
              style: theme.textTheme.labelSmall?.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
            const Spacer(),
            InkWell(
              borderRadius: BorderRadius.circular(4),
              onTap: filtered.isEmpty ? null : _copyLogs,
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.copy_outlined, size: 13, color: cs.primary),
                    const SizedBox(width: 3),
                    Text('复制',
                        style:
                            TextStyle(fontSize: 12, color: cs.primary)),
                  ],
                ),
              ),
            ),
            InkWell(
              borderRadius: BorderRadius.circular(4),
              onTap: _logs.isEmpty ? null : _clearLogs,
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.delete_outline, size: 13, color: cs.error),
                    const SizedBox(width: 3),
                    Text('清除',
                        style: TextStyle(fontSize: 12, color: cs.error)),
                  ],
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Expanded(
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: cs.surfaceContainerLow,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: cs.outlineVariant.withValues(alpha: 0.5),
              ),
            ),
            child: filtered.isEmpty
                ? Center(
                    child: Text('(无日志)',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: cs.onSurfaceVariant,
                        )))
                : ListView.builder(
                    controller: _logScrollController,
                    itemCount: filtered.length,
                    itemBuilder: (_, i) {
                      final log = filtered[i];
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 2),
                        child: SelectableText(
                          '[${_timeStr(log.timestamp)}] [${log.level.name.toUpperCase()}] ${log.message}',
                          style: TextStyle(
                            fontSize: 11,
                            fontFamily: 'monospace',
                            height: 1.35,
                            color: _logColor(log.level, theme),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ),
      ],
    );
  }

  Future<void> _copyLogs() async {
    final filtered = _filteredLogs;
    if (filtered.isEmpty) return;
    final text = filtered
        .map((l) =>
            '[${_timeStr(l.timestamp)}] [${l.level.name.toUpperCase()}] ${l.message}')
        .join('\n');
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('已复制日志到剪贴板'),
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 1),
        ),
      );
    }
  }

  void _clearLogs() {
    if (_logs.isEmpty) return;
    setState(_logs.clear);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('已清除日志'),
        behavior: SnackBarBehavior.floating,
        duration: Duration(seconds: 1),
      ),
    );
  }

  // ─── 视图: 详情 (按当前选中账号) ───

  Widget _buildDetailsTab(ThemeData theme) {
    final token = _selectedToken;
    final s = token == null ? null : _states[token];
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (s != null) ...[
            const _SectionTitle(title: '账号详情'),
            _KvPanel(rows: _accountDetailRows(s)),
            const SizedBox(height: 12),
          ],
          _SectionTitle(title: s != null ? '任务配置' : '任务摘要'),
          _KvPanel(rows: _taskConfigRows()),
        ],
      ),
    );
  }

  List<_KvRowData> _accountDetailRows(AccountBatchState s) {
    final proxy = (s.account.proxy ?? '').trim();
    final elapsed = s.startedAt != null
        ? _formatElapsed(DateTime.now().difference(s.startedAt!))
        : '-';
    return [
      _KvRowData(
          '账号',
          s.account.displayName ??
              s.account.account ??
              s.account.userId),
      _KvRowData('用户ID', s.account.userId),
      _KvRowData('学校ID', s.account.schoolId),
      _KvRowData('学校', s.account.schoolName ?? '-'),
      _KvRowData('状态', _statusText(s.status),
          valueColor: _statusColor(s.status)),
      _KvRowData(
          '进度',
          '${(s.progress * 100).toInt()}%'
          ' (${s.processedCourses}/${s.totalCourses})'),
      _KvRowData('代理', proxy.isEmpty ? '(直连)' : proxy),
      _KvRowData('开始时间',
          s.startedAt == null ? '-' : _timeStr(s.startedAt!)),
      _KvRowData('已耗时', elapsed),
      _KvRowData('当前消息', s.message),
    ];
  }

  List<_KvRowData> _taskConfigRows() {
    final e = widget.executor;
    final proxyCount = e.accounts
        .where((a) => (a.proxy ?? '').trim().isNotEmpty)
        .length;
    return [
      _KvRowData('任务类型', e.taskType),
      _KvRowData(
          '执行模式',
          e.parallel ? '并行 (最多 5 账号同时执行)' : '串行 (逐个账号执行)'),
      _KvRowData(
          '作业筛选',
          '状态=${e.taskFilterConfig.status ?? "(全部)"} · '
              '学科=${e.taskFilterConfig.subject ?? "(全部)"} · '
              '类型=${e.taskFilterConfig.type ?? "(全部)"}'),
      _KvRowData('账号数', '${e.accounts.length}'),
      _KvRowData('代理统计',
          proxyCount > 0 ? '$proxyCount/${e.accounts.length} 个账号使用代理' : '全部直连'),
      if (e.reportConfig != null) ...[
        _KvRowData('过滤已完成', e.reportConfig!.filterCompleted ? '是' : '否'),
        _KvRowData('心跳间隔', '${e.reportConfig!.heartbeatInterval}s'),
        _KvRowData('播放倍速', '${e.reportConfig!.speed}x'),
        _KvRowData('快刷模式', e.reportConfig!.fastBrush ? '开' : '关'),
      ],
      _KvRowData('日志总数', '${_logs.length} 条'),
    ];
  }

  String _formatElapsed(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    if (h > 0) return '$h 时 $m 分 $s 秒';
    if (m > 0) return '$m 分 $s 秒';
    return '$s 秒';
  }

  String _statusText(BatchStatus st) => switch (st) {
        BatchStatus.pending => '等待中',
        BatchStatus.running => '执行中',
        BatchStatus.done => '已完成',
        BatchStatus.failed => '失败',
      };

  Color _statusColor(BatchStatus st) => switch (st) {
        BatchStatus.pending => Colors.grey,
        BatchStatus.running => Colors.orange,
        BatchStatus.done => Colors.green,
        BatchStatus.failed => Colors.red,
      };

  Widget _statusDot(BatchStatus status) {
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(
        color: _statusColor(status),
        shape: BoxShape.circle,
      ),
    );
  }

  IconData _taskIcon() {
    switch (widget.executor.taskType) {
      case BatchTaskExecutor.kTaskReport:
        return Icons.trending_up;
      case BatchTaskExecutor.kTaskAnswers:
        return Icons.question_answer;
      case BatchTaskExecutor.kTaskDownloadVideo:
        return Icons.video_library;
      case BatchTaskExecutor.kTaskDownloadPaper:
        return Icons.picture_as_pdf;
      default:
        return Icons.task;
    }
  }

  Color _logColor(LogLevel level, ThemeData theme) {
    return switch (level) {
      LogLevel.debug =>
        theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
      LogLevel.info => theme.colorScheme.onSurfaceVariant,
      LogLevel.success => Colors.green,
      LogLevel.warning => Colors.orange,
      LogLevel.error => theme.colorScheme.error,
    };
  }

  String _timeStr(DateTime t) {
    final h = t.hour.toString().padLeft(2, '0');
    final m = t.minute.toString().padLeft(2, '0');
    final s = t.second.toString().padLeft(2, '0');
    return '$h:$m:$s';
  }
}

// ═══════════════════════════════════════════
// 批量任务进度弹窗辅助组件
// ═══════════════════════════════════════════

/// 单账号进度卡片 (进度视图)
class _AccountProgressCard extends StatelessWidget {
  final AccountBatchState state;

  /// 是否聚焦显示 (选中单个账号时)
  final bool focus;

  const _AccountProgressCard({required this.state, this.focus = false});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final s = state;
    final name =
        s.account.displayName ?? s.account.account ?? s.account.userId;
    final color = switch (s.status) {
      BatchStatus.done => Colors.green,
      BatchStatus.failed => cs.error,
      _ => cs.primary,
    };
    return Card(
      elevation: 0,
      color: focus
          ? cs.secondaryContainer.withValues(alpha: 0.35)
          : cs.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: focus
            ? BorderSide(color: cs.primary.withValues(alpha: 0.4))
            : BorderSide.none,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                switch (s.status) {
                  BatchStatus.done => const Icon(Icons.check_circle,
                      size: 18, color: Colors.green),
                  BatchStatus.failed =>
                    Icon(Icons.cancel, size: 18, color: cs.error),
                  BatchStatus.running => const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  BatchStatus.pending => Icon(Icons.radio_button_unchecked,
                      size: 18, color: cs.outline),
                },
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                Text(
                  '${(s.progress * 100).toInt()}%',
                  style: theme.textTheme.labelLarge?.copyWith(
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.w700,
                    color: color,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: s.progress.clamp(0.0, 1.0),
                minHeight: 7,
                backgroundColor: cs.surfaceContainerHighest,
                valueColor: AlwaysStoppedAnimation(color),
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: Text(
                    s.message,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: cs.onSurfaceVariant),
                  ),
                ),
                if (s.startedAt != null) ...[
                  Icon(Icons.schedule, size: 12, color: cs.onSurfaceVariant),
                  const SizedBox(width: 3),
                  Text(
                    _elapsedText(s),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: cs.onSurfaceVariant,
                      fontSize: 10,
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  static String _elapsedText(AccountBatchState s) {
    final d = DateTime.now().difference(s.startedAt!);
    if (d.inHours > 0) return '${d.inHours}h ${d.inMinutes.remainder(60)}m';
    if (d.inMinutes > 0) return '${d.inMinutes}m ${d.inSeconds.remainder(60)}s';
    return '${d.inSeconds}s';
  }
}

/// 顶部状态徽章 (完成/失败汇总)
class _StatusBadge extends StatelessWidget {
  final int done;
  final int fail;
  final int total;
  final bool finished;

  const _StatusBadge({
    required this.done,
    required this.fail,
    required this.total,
    required this.finished,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final (Color bg, Color fg, String text) = finished
        ? (fail > 0
            ? (cs.errorContainer, cs.onErrorContainer, '$done 成功 · $fail 失败')
            : (cs.primaryContainer, cs.onPrimaryContainer, '$done/$total 完成'))
        : (cs.secondaryContainer, cs.onSecondaryContainer, '$done/$total 完成');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          color: fg,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// 统计项 (图标 + 数值 + 标签)
class _StatItem extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String value;
  final String label;

  const _StatItem({
    required this.icon,
    required this.iconColor,
    required this.value,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 15, color: iconColor),
        const SizedBox(width: 4),
        Text(
          value,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w700,
            color: iconColor,
          ),
        ),
        const SizedBox(width: 3),
        Text(
          label,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            fontSize: 11,
          ),
        ),
      ],
    );
  }
}

/// 区块标题 (详情视图)
class _SectionTitle extends StatelessWidget {
  final String title;
  const _SectionTitle({required this.title});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        title,
        style: theme.textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.bold,
          color: theme.colorScheme.primary,
        ),
      ),
    );
  }
}

/// 键值对行数据
class _KvRowData {
  final String key;
  final String value;
  final Color? valueColor;
  const _KvRowData(this.key, this.value, {this.valueColor});
}

/// 键值对面板 (详情视图)
class _KvPanel extends StatelessWidget {
  final List<_KvRowData> rows;
  const _KvPanel({required this.rows});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.6)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0) const SizedBox(height: 5),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 88,
                  child: Text(
                    rows[i].key,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: cs.onSurfaceVariant),
                  ),
                ),
                Expanded(
                  child: SelectableText(
                    rows[i].value,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: rows[i].valueColor ?? cs.onSurface,
                      fontWeight:
                          rows[i].valueColor != null ? FontWeight.w600 : null,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════
// Token 有效性指示点
// ═══════════════════════════════════════════
class _ValidityDot extends StatelessWidget {
  final TokenValidity validity;

  const _ValidityDot({required this.validity});

  @override
  Widget build(BuildContext context) {
    return switch (validity) {
      TokenValidity.valid => Container(
          width: 8,
          height: 8,
          decoration: const BoxDecoration(
            color: Colors.green,
            shape: BoxShape.circle,
          ),
        ),
      TokenValidity.invalid => Container(
          width: 8,
          height: 8,
          decoration: const BoxDecoration(
            color: Colors.red,
            shape: BoxShape.circle,
          ),
        ),
      TokenValidity.checking => const SizedBox(
          width: 8,
          height: 8,
          child: CircularProgressIndicator(strokeWidth: 1.5),
        ),
      TokenValidity.unknown => const SizedBox(width: 8, height: 8),
    };
  }
}

// ═══════════════════════════════════════════
// 弱密码 / 需改密弹窗
// ═════════════════════════════════════════

/// 弱密码改密弹窗
///
/// 登录命中"需改密"响应（弱密码等）时弹出：填写原密码（预填）+ 新密码 + 确认，
/// 提交后调用 [AuthNotifier.changePasswordAndRelogin] 改密并用新密码自动重登。
/// 内容区固定宽度（不用 double.infinity 包裹 ListView，避免 M3 弹窗布局崩溃）。
class ChangePasswordDialog extends ConsumerStatefulWidget {
  final AuthPasswordChangeRequired state;

  const ChangePasswordDialog({super.key, required this.state});

  /// 弹出改密弹窗
  static Future<void> show(
    BuildContext context,
    AuthPasswordChangeRequired state,
  ) =>
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => ChangePasswordDialog(state: state),
      );

  @override
  ConsumerState<ChangePasswordDialog> createState() =>
      _ChangePasswordDialogState();
}

class _ChangePasswordDialogState extends ConsumerState<ChangePasswordDialog> {
  final _formKey = GlobalKey<FormState>();
  final _oldController = TextEditingController();
  final _newController = TextEditingController();
  final _confirmController = TextEditingController();
  bool _obscure = true;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    // 预填原密码（用户登录所用的密码，服务器认可其正确性，仅因过弱要求修改）
    _oldController.text = widget.state.oldPassword;
  }

  @override
  void dispose() {
    _oldController.dispose();
    _newController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    final oldP = _oldController.text;
    final newP = _newController.text;

    setState(() => _submitting = true);
    // 提交后由 provider 状态变化驱动后续（导航 / 提示 / 再次弹窗），本弹窗随后关闭
    await ref.read(authProvider.notifier).changePasswordAndRelogin(
          account: widget.state.account,
          oldPassword: oldP,
          newPassword: newP,
          checkToken: widget.state.checkToken ?? '',
        );
    if (mounted) {
      // 关闭本弹窗；provider 已置为 AuthLoading，登录表单按钮显示加载态，
      // 后续 AuthAuthenticated / AuthError / 再次 AuthPasswordChangeRequired
      // 由 LoginPage 的 ref.listen 处理。
      Navigator.of(context).pop();
    }
  }

  String? _validateNew(String? v) {
    if (v == null || v.isEmpty) return '请输入新密码';
    if (v.length < 6) return '密码至少 6 位';
    if (v == _oldController.text) return '新密码不可与原密码相同';
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isLoading = ref.watch(authProvider) is AuthLoading;

    return AlertDialog(
      icon: Icon(Icons.lock_reset_outlined, color: cs.primary),
      title: const Text('密码过于简单，请修改'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  widget.state.message,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: cs.onSurfaceVariant),
                ),
              ),
              const SizedBox(height: 16),
              Form(
                key: _formKey,
                child: Column(
                  children: [
                    TextFormField(
                      controller: _oldController,
                      decoration: const InputDecoration(
                        labelText: '原密码',
                        prefixIcon: Icon(Icons.lock_outline),
                      ),
                      obscureText: _obscure,
                      validator: (v) =>
                          (v == null || v.isEmpty) ? '请输入原密码' : null,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _newController,
                      decoration: const InputDecoration(
                        labelText: '新密码',
                        prefixIcon: Icon(Icons.lock_reset_outlined),
                      ),
                      obscureText: _obscure,
                      validator: _validateNew,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _confirmController,
                      decoration: const InputDecoration(
                        labelText: '确认新密码',
                        prefixIcon: Icon(Icons.lock_reset_outlined),
                      ),
                      obscureText: _obscure,
                      validator: (v) {
                        if (v == null || v.isEmpty) {
                          return '请再次输入新密码';
                        }
                        if (v != _newController.text) {
                          return '两次输入的密码不一致';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 4),
                    Align(
                      alignment: Alignment.centerRight,
                      child: IconButton(
                        icon: Icon(
                          _obscure ? Icons.visibility_off : Icons.visibility,
                        ),
                        tooltip: '显示/隐藏密码',
                        onPressed: () => setState(() => _obscure = !_obscure),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _submitting
              ? null
              : () {
                  ref.read(authProvider.notifier).cancelPasswordChange();
                  Navigator.of(context).pop();
                },
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: (_submitting || isLoading) ? null : _submit,
          child: (_submitting || isLoading)
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('修改并登录'),
        ),
      ],
    );
  }
}

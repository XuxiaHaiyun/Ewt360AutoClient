/// 设置页面：账号信息、显示（主题/字体/缩放/底栏样式）、网络（代理/SSL/HTTP2/重试）、
/// 高级、平台保活与关于分区；高级分区可由 RiskControlGate 风控隐藏，宽屏双栏布局。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:ewt_auto_client/core/config/endpoint_config.dart';
import 'package:ewt_auto_client/core/di/injection.dart';
import 'package:ewt_auto_client/core/fonts/font_manager.dart';
import 'package:ewt_auto_client/core/layout/app_breakpoints.dart';
import 'package:ewt_auto_client/core/layout/responsive.dart';
import 'package:ewt_auto_client/core/network/dio_client.dart';
import 'package:ewt_auto_client/core/platform/keep_alive_channel.dart';
import 'package:ewt_auto_client/core/risk_control/risk_control_gate.dart';
import 'package:ewt_auto_client/core/theme/app_theme.dart';
import 'package:ewt_auto_client/core/utils/proxy_parser.dart';
import 'package:ewt_auto_client/features/answer/domain/entities/handwriting_config.dart';
import 'package:ewt_auto_client/features/auth/data/datasources/account_storage.dart';
import 'package:ewt_auto_client/features/auth/domain/entities/user_session.dart';
import 'package:ewt_auto_client/features/auth/presentation/providers/account_provider.dart';
import 'package:ewt_auto_client/features/auth/presentation/providers/auth_provider.dart';

import '../providers/settings_provider.dart';
import 'package:ewt_auto_client/features/activity/presentation/providers/checkin_provider.dart';

/// 设置页面
///
/// 对应 Python: gui/interfaces/settings.py
class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(appSettingsProvider);
    final authState = ref.watch(authProvider);
    final session = authState is AuthAuthenticated ? authState.session : null;

    // 风控可直接隐藏整个高级设置分区
    final hideAdvanced = !RiskControlGate.isFeatureEnabled('settings.advanced');

    final isWide = context.isWide;

    // 各设置分区: 窄屏单列纵排, 宽屏按权重分两栏均衡展示
    final sections = <({String title, Widget card})>[
      (title: '显示', card: _displayCard(context, ref, settings)),
      (title: '网络', card: _networkCard(context, ref, settings, session)),
      if (!hideAdvanced)
        (title: '高级', card: _advancedCard(context, ref, settings)),
      if (Platform.isAndroid)
        (title: '保活', card: _androidKeepAliveCard(context, ref, settings)),
      if (Platform.isWindows)
        (title: '保活', card: _windowsKeepAliveCard(context, ref, settings)),
      (title: '关于', card: _aboutCard(context, ref)),
    ];

    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      // 宽屏限幅居中, 避免设置项在大屏上被拉伸到不可读的宽度。
      body: ResponsiveCenter(
        maxWidth: isWide ? 980 : AppBreakpoints.contentMaxWidth,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // ─── 当前账号 ───
            _accountCard(context, ref, settings, session),
            const SizedBox(height: 24),
            if (isWide)
              _twoColumnSections(sections)
            else
              for (final s in sections) ...[
                _SectionHeader(title: s.title),
                const SizedBox(height: 8),
                s.card,
                const SizedBox(height: 24),
              ],
          ],
        ),
      ),
    );
  }

  /// 分区估算权重 (宽屏两栏均衡): 保活分区条目最多, 权重最高
  static double _sectionWeight(String title) => title == '保活' ? 8 : 3;

  /// 宽屏双栏分区布局: 按估算权重贪心分配, 保持分区顺序
  Widget _twoColumnSections(List<({String title, Widget card})> sections) {
    final left = <({String title, Widget card})>[];
    final right = <({String title, Widget card})>[];
    var leftWeight = 0.0;
    var rightWeight = 0.0;
    for (final s in sections) {
      final w = _sectionWeight(s.title);
      if (leftWeight <= rightWeight) {
        left.add(s);
        leftWeight += w;
      } else {
        right.add(s);
        rightWeight += w;
      }
    }

    Widget column(List<({String title, Widget card})> items) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final s in items) ...[
              _SectionHeader(title: s.title),
              const SizedBox(height: 8),
              s.card,
              const SizedBox(height: 24),
            ],
          ],
        );

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: column(left)),
        const SizedBox(width: 12),
        Expanded(child: column(right)),
      ],
    );
  }

  /// 当前账号卡片 (右键 / 长按账号栏可查看账号详细信息)
  Widget _accountCard(
    BuildContext context,
    WidgetRef ref,
    AppSettingsState settings,
    UserSession? session,
  ) {
    final theme = Theme.of(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onSecondaryTapDown: (d) =>
          _showAccountContextMenu(context, ref, d.globalPosition),
      onSecondaryTapUp: (d) =>
          _showAccountContextMenu(context, ref, d.globalPosition),
      onLongPress: () => _showAccountInfoDialog(context, ref, settings),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              CircleAvatar(
                radius: 24,
                backgroundColor: theme.colorScheme.primaryContainer,
                backgroundImage:
                    (session?.avatar != null && session!.avatar!.isNotEmpty)
                    ? NetworkImage(session.avatar!)
                    : null,
                child:
                    (session?.avatar == null || session!.avatar!.isEmpty)
                    ? Text(
                        _initial(
                          session?.displayName ?? session?.account,
                        ),
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: theme.colorScheme.onPrimaryContainer,
                          fontWeight: FontWeight.bold,
                        ),
                      )
                    : null,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      settings.mask(
                        session?.displayName ?? session?.account,
                      ),
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'ID: ${settings.mask(session?.userId)}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              // 切换账号
              FilledButton.tonalIcon(
                icon: const Icon(Icons.swap_horiz, size: 18),
                label: const Text('切换'),
                onPressed: () => _showSwitchAccountDialog(context, ref),
              ),
              const SizedBox(width: 8),
              // 退出登录
              IconButton(
                icon: Icon(
                  Icons.logout,
                  color: theme.colorScheme.error,
                ),
                tooltip: '退出登录',
                onPressed: () => _confirmLogout(context, ref),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 显示分区卡片: 主题模式 / 强调色 / 主页导航 TAB / 悬浮底栏 /
  /// 字体管理 / 界面缩放 / 页面过渡动画 / 演示模式
  Widget _displayCard(
    BuildContext context,
    WidgetRef ref,
    AppSettingsState settings,
  ) {
    return Card(
      child: Column(
        children: [
          // 主题模式
          ListTile(
            leading: const Icon(Icons.palette_outlined),
            title: const Text('主题模式'),
            subtitle: Text(_themeModeLabel(settings.themeMode)),
            trailing: const Icon(Icons.chevron_right, size: 20),
            onTap: () => _showThemeModeDialog(context, ref, settings),
          ),
          const Divider(height: 1, indent: 16, endIndent: 16),
          // 强调色
          ListTile(
            leading: const Icon(Icons.color_lens_outlined),
            title: const Text('强调色'),
            subtitle: Text(_accentColorLabel(settings.accentColor)),
            trailing: const Icon(Icons.chevron_right, size: 20),
            onTap: () => _showAccentColorDialog(context, ref, settings),
          ),
          const Divider(height: 1, indent: 16, endIndent: 16),
          // 主页导航 TAB
          ListTile(
            leading: const Icon(Icons.tab_outlined),
            title: const Text('主页导航 TAB'),
            subtitle: Text(_visibleTabsLabel(settings.visibleTabs)),
            trailing: const Icon(Icons.chevron_right, size: 20),
            onTap: () => _showVisibleTabsDialog(context, ref, settings),
          ),
          const Divider(height: 1, indent: 16, endIndent: 16),
          // 悬浮底栏 (窄屏底部导航悬浮胶囊样式)
          SwitchListTile(
            secondary: const Icon(Icons.dock_outlined),
            title: const Text('悬浮底栏'),
            subtitle: const Text('底部导航悬浮圆角样式, 不贴边显示'),
            value: settings.floatingBottomBar,
            onChanged: (v) =>
                ref.read(appSettingsProvider.notifier).setFloatingBottomBar(v),
          ),
          const Divider(height: 1, indent: 16, endIndent: 16),
          // 字体管理 (全局显示字体 + 手写模拟共用)
          ListTile(
            leading: const Icon(Icons.font_download_outlined),
            title: const Text('字体管理'),
            subtitle: Text(_appFontLabel(settings)),
            trailing: const Icon(Icons.chevron_right, size: 20),
            onTap: () => _showFontManagerDialog(context, ref, settings),
          ),
          const Divider(height: 1, indent: 16, endIndent: 16),
          // 界面缩放
          ListTile(
            leading: const Icon(Icons.zoom_out_map_outlined),
            title: const Text('界面缩放'),
            subtitle: Text('${(settings.uiScale * 100).toStringAsFixed(0)}%'),
            trailing: const Icon(Icons.chevron_right, size: 20),
            onTap: () => _showUiScaleDialog(context, ref, settings),
          ),
          const Divider(height: 1, indent: 16, endIndent: 16),
          // 页面过渡动画
          ListTile(
            leading: const Icon(Icons.animation_outlined),
            title: const Text('页面过渡动画'),
            subtitle: Text(_pageTransitionLabel(settings.pageTransition)),
            trailing: const Icon(Icons.chevron_right, size: 20),
            onTap: () => _showPageTransitionDialog(context, ref, settings),
          ),
          const Divider(height: 1, indent: 16, endIndent: 16),
          // 演示模式
          SwitchListTile(
            secondary: const Icon(Icons.visibility_off_outlined),
            title: const Text('演示模式'),
            subtitle: const Text('遮蔽姓名、ID 等敏感信息'),
            value: settings.demoMode,
            onChanged: (v) =>
                ref.read(appSettingsProvider.notifier).setDemoMode(v),
          ),
        ],
      ),
    );
  }

  /// 网络分区卡片: 请求间隔 / 连接重试 / 网络日志 / SSL/HTTP2 /
  /// 代理(当前登录账号) / 设备信息
  Widget _networkCard(
    BuildContext context,
    WidgetRef ref,
    AppSettingsState settings,
    UserSession? session,
  ) {
    return Card(
      child: Column(
        children: [
          // 请求间隔
          ListTile(
            leading: const Icon(Icons.timer_outlined),
            title: const Text('请求间隔'),
            subtitle: Text('${settings.requestInterval} ms'),
            trailing: const Icon(Icons.chevron_right, size: 20),
            onTap: () => _showIntervalDialog(context, ref, settings),
          ),
          const Divider(height: 1, indent: 16, endIndent: 16),
          // 连接重试次数
          ListTile(
            leading: const Icon(Icons.repeat_outlined),
            title: const Text('连接重试次数'),
            subtitle: Text(
              settings.connectRetryCount == 0
                  ? '不重试 (连接失败直接报错)'
                  : '连接失败后重试 ${settings.connectRetryCount} 次',
            ),
            trailing: const Icon(Icons.chevron_right, size: 20),
            onTap: () => _showRetryCountDialog(context, ref, settings),
          ),
          const Divider(height: 1, indent: 16, endIndent: 16),
          // 连接重试间隔
          ListTile(
            leading: const Icon(Icons.more_time_outlined),
            title: const Text('连接重试间隔'),
            subtitle: Text('${settings.connectRetryIntervalMs} ms'),
            trailing: const Icon(Icons.chevron_right, size: 20),
            onTap: () => _showRetryIntervalDialog(context, ref, settings),
          ),
          const Divider(height: 1, indent: 16, endIndent: 16),
          // 网络日志
          SwitchListTile(
            secondary: const Icon(Icons.receipt_long_outlined),
            title: const Text('网络日志'),
            subtitle: Text(
              settings.networkLogEnabled
                  ? (DioClient.logFilePath ?? '日志文件初始化中...')
                  : '记录请求/响应到日志文件',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            value: settings.networkLogEnabled,
            onChanged: (v) =>
                ref.read(appSettingsProvider.notifier).setNetworkLog(v),
          ),
          const Divider(height: 1, indent: 16, endIndent: 16),
          // 禁用 SSL 证书验证
          SwitchListTile(
            secondary: const Icon(Icons.lock_open_outlined),
            title: const Text('禁用 SSL 证书验证'),
            subtitle: const Text(
              '自签名证书 / 抓包调试场景；开启存在中间人风险，请自行评估',
            ),
            value: settings.disableSslVerify,
            onChanged: (v) =>
                ref.read(appSettingsProvider.notifier).setDisableSslVerify(v),
          ),
          const Divider(height: 1, indent: 16, endIndent: 16),
          // 启用 HTTP/2
          SwitchListTile(
            secondary: const Icon(Icons.bolt_outlined),
            title: const Text('启用 HTTP/2'),
            subtitle: Text(
              settings.enableHttp2
                  ? (settings.disableSslVerify ||
                        (session?.proxy ?? '').trim().isNotEmpty
                      ? '与禁用证书验证/代理互斥，当前实际走 HTTP/1.1'
                      : '多路复用提升并发性能 (全局客户端生效)')
                  : '多路复用提升并发性能；与代理/禁用证书验证互斥',
            ),
            value: settings.enableHttp2,
            onChanged: (v) =>
                ref.read(appSettingsProvider.notifier).setEnableHttp2(v),
          ),
          const Divider(height: 1, indent: 16, endIndent: 16),
          // 代理 (当前登录账号): 修改后当前会话立即生效, 并同步到已保存账号
          // (登录页批量任务按账号走独立代理时沿用同一配置)
          ListTile(
            leading: const Icon(Icons.vpn_key_outlined),
            title: const Text('代理设置'),
            subtitle: Text(
              session == null
                  ? '未登录'
                  : ((session.proxy ?? '').trim().isEmpty
                        ? '直连 (未设置代理)'
                        : session.proxy!),
            ),
            trailing: const Icon(Icons.edit, size: 18),
            enabled: session != null,
            onTap: session == null
                ? null
                : () => _showAccountProxyDialog(context, ref, session),
          ),
          const Divider(height: 1, indent: 16, endIndent: 16),
          // 设备信息
          ListTile(
            leading: const Icon(Icons.fingerprint_outlined),
            title: const Text('设备信息'),
            subtitle: const Text('设备 / UA / SDK / 请求头'),
            trailing: const Icon(Icons.chevron_right, size: 20),
            onTap: () => _showDeviceInfoDialog(context),
          ),
        ],
      ),
    );
  }

  /// 高级分区卡片: 会员鉴权越权 / 周培优班级越权 / 自动签到 / 任意用户进度注入
  Widget _advancedCard(
    BuildContext context,
    WidgetRef ref,
    AppSettingsState settings,
  ) {
    // 高级功能开关受风控限制: 未授权时禁用对应开关
    final lockMemberBypass = !RiskControlGate.isFeatureEnabled(
      'settings.member_auth_bypass',
    );
    final lockWeekendBypass = !RiskControlGate.isFeatureEnabled(
      'settings.weekend_class_bypass',
    );
    final lockAutoCheckin = !RiskControlGate.isFeatureEnabled(
      'settings.auto_checkin',
    );
    final lockReportInject = !RiskControlGate.isFeatureEnabled(
      'settings.report_inject_visible',
    );

    return Card(
      child: Column(
        children: [
          // 会员鉴权越权
          SwitchListTile(
            secondary: lockMemberBypass
                ? const Icon(Icons.lock_outline)
                : const Icon(Icons.enhanced_encryption_outlined),
            title: const Text('会员鉴权越权'),
            subtitle: lockMemberBypass
                ? const Text('风控已限制此功能')
                : const Text('绕过会员门领取播放凭证'),
            value: lockMemberBypass ? false : settings.memberAuthBypass,
            onChanged: lockMemberBypass
                ? null
                : (v) => ref
                      .read(appSettingsProvider.notifier)
                      .setMemberAuthBypass(v),
          ),
          const Divider(height: 1, indent: 16, endIndent: 16),
          // 周培优班级越权
          SwitchListTile(
            secondary: lockWeekendBypass
                ? const Icon(Icons.lock_outline)
                : const Icon(Icons.school_outlined),
            title: const Text('周培优班级越权'),
            subtitle: lockWeekendBypass
                ? const Text('风控已限制此功能')
                : const Text('获取学校全部周培优班级课程'),
            value: lockWeekendBypass ? false : settings.weekendClassBypass,
            onChanged: lockWeekendBypass
                ? null
                : (v) => ref
                      .read(appSettingsProvider.notifier)
                      .setWeekendClassBypass(v),
          ),
          const Divider(height: 1, indent: 16, endIndent: 16),
          // 自动签到 (开关即执行)
          SwitchListTile(
            secondary: lockAutoCheckin
                ? const Icon(Icons.lock_outline)
                : const Icon(Icons.bolt_outlined),
            title: const Text('自动签到'),
            subtitle: lockAutoCheckin
                ? const Text('风控已限制此功能')
                : const Text('开启即用当前账号发送一次签到请求，完成每日签到'),
            value: lockAutoCheckin ? false : settings.checkinRaceEnabled,
            onChanged: lockAutoCheckin
                ? null
                : (v) => _onCheckinRaceToggled(context, ref, settings, v),
          ),
          const Divider(height: 1, indent: 16, endIndent: 16),
          // 任意用户进度注入 (显示开关)
          SwitchListTile(
            secondary: lockReportInject
                ? const Icon(Icons.lock_outline)
                : const Icon(Icons.person_add_alt_1_outlined),
            title: const Text('任意用户进度注入'),
            subtitle: lockReportInject
                ? const Text('风控已限制此功能')
                : const Text('在进度上报配置页显示注入开关，上报 userid 可覆盖为目标用户'),
            value: lockReportInject ? false : settings.showReportInject,
            onChanged: lockReportInject
                ? null
                : (v) => ref
                      .read(appSettingsProvider.notifier)
                      .setShowReportInject(v),
          ),
        ],
      ),
    );
  }

  /// Android 保活分区卡片 (KeepLiveService 框架多策略)
  Widget _androidKeepAliveCard(
    BuildContext context,
    WidgetRef ref,
    AppSettingsState settings,
  ) {
    final theme = Theme.of(context);
    return Card(
      child: Column(
        children: [
          // 保活总开关
          SwitchListTile(
            secondary: const Icon(Icons.bolt),
            title: const Text('保活运行'),
            subtitle: Text(
              settings.keepAliveEnabled
                  ? 'KeepLiveService 框架多策略保活中'
                  : '关闭中，开启后以前台服务/定时唤醒/账户同步等策略维持后台运行',
            ),
            value: settings.keepAliveEnabled,
            onChanged: (v) => _onKeepAliveToggled(context, ref, v),
          ),
          const Divider(height: 1, indent: 16, endIndent: 16),
          // 保持屏幕开启 (功能生效)
          SwitchListTile(
            secondary: const Icon(Icons.lightbulb_outline),
            title: const Text('保持屏幕开启'),
            subtitle: const Text('阻止设备熄屏休眠'),
            value: settings.keepScreenOn,
            onChanged: (v) =>
                ref.read(appSettingsProvider.notifier).setKeepScreenOn(v),
          ),
          const Divider(height: 1, indent: 16, endIndent: 16),
          // 电池优化豁免 (显示真实系统状态)
          const _BatteryOptimizationTile(),
          // ─── 框架选项 (保活总开关开启后显示) ───
          if (settings.keepAliveEnabled) ...[
            const Divider(height: 1, indent: 16, endIndent: 16),
            // 全部框架选项: 按目录分组渲染
            for (final group in _fwOptionGroups) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Text(
                  group.title,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: theme.colorScheme.primary,
                  ),
                ),
              ),
              for (final opt in group.options) ...[
                SwitchListTile(
                  secondary: Icon(opt.icon),
                  title: Text(opt.label),
                  subtitle: Text(opt.subtitle),
                  value: settings.fwOptions[opt.key] ?? false,
                  // 需运行时权限的选项在开启前先动态申请
                  onChanged: (v) =>
                      _onFwOptionToggled(context, ref, opt, v),
                ),
                const Divider(height: 1, indent: 16, endIndent: 16),
              ],
            ],
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('侵袭等级', style: theme.textTheme.titleSmall),
                  const SizedBox(height: 4),
                  Text(
                    '等级越高保活越激进，被查杀概率越低，但耗电与系统资源占用越高',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 8),
                  SegmentedButton<int>(
                    segments: const [
                      ButtonSegment(value: 0, label: Text('低')),
                      ButtonSegment(value: 1, label: Text('中')),
                      ButtonSegment(value: 2, label: Text('高')),
                    ],
                    selected: {settings.fwAggressiveLevel},
                    onSelectionChanged: (selection) => ref
                        .read(appSettingsProvider.notifier)
                        .setFwAggressiveLevel(selection.first),
                  ),
                ],
              ),
            ),
            const Divider(height: 1, indent: 16, endIndent: 16),
            ListTile(
              leading: const Icon(Icons.health_and_safety_outlined),
              title: const Text('立即巡检'),
              subtitle: const Text('检查各保活策略存活状态并自动补偿'),
              trailing: const Icon(Icons.chevron_right, size: 20),
              onTap: () async {
                final ok = await KeepAliveChannel.frameworkCheck();
                if (!context.mounted) return;
                _showTopToast(
                  context,
                  title: ok ? '巡检完成' : '巡检失败',
                  detail: ok
                      ? '框架已检查并自动补偿所有保活策略'
                      : '框架未初始化或调用失败，请先开启保活运行',
                  isError: !ok,
                );
              },
            ),
          ],
          const Divider(height: 1, indent: 16, endIndent: 16),
          // 多任务列表窗口加锁 (系统限制, 仅引导)
          ListTile(
            leading: const Icon(Icons.lock_outline),
            title: const Text('多任务列表窗口加锁'),
            subtitle: const Text('锁定后清理后台不关闭本应用（系统限制，仅引导）'),
            trailing: const Icon(Icons.chevron_right, size: 20),
            onTap: () => _showKeepAliveGuide(
              context,
              title: '多任务列表窗口加锁',
              steps: const [
                '打开系统“最近任务 / 多任务”视图（手势上滑悬停或点方括号按钮）。',
                '找到本应用卡片，长按或下拉该卡片。',
                '点击出现的“锁定”图标（🔒）。',
                '锁定后清理后台时本应用不会被关闭；再次长按卡片点“解锁”可解除。',
              ],
            ),
          ),
          const Divider(height: 1, indent: 16, endIndent: 16),
          // 固定应用 (Android 9+ 直接拉起系统固定确认, 低版本先开屏幕固定)
          const _PinAppTile(),
          const Divider(height: 1, indent: 16, endIndent: 16),
          // 添加桌面卡片 (requestPinAppWidget 直拉系统添加确认 + 模拟更新保活)
          const _PinWidgetTile(),
        ],
      ),
    );
  }

  /// Windows 保活分区卡片: 进程优先级 / 阻止系统睡眠
  Widget _windowsKeepAliveCard(
    BuildContext context,
    WidgetRef ref,
    AppSettingsState settings,
  ) {
    return Card(
      child: Column(
        children: [
          SwitchListTile(
            secondary: const Icon(Icons.speed_outlined),
            title: const Text('提高进程优先级'),
            subtitle: const Text('高优先级运行，避免被系统降级节流'),
            value: settings.windowsHighPriority,
            onChanged: (v) async {
              final ok = await ref
                  .read(appSettingsProvider.notifier)
                  .setWindowsHighPriority(v);
              if (!ok && context.mounted) {
                _showTopToast(
                  context,
                  title: '设置失败',
                  detail: '进程优先级调整未生效，请重试。',
                  isError: true,
                );
              }
            },
          ),
          const Divider(height: 1, indent: 16, endIndent: 16),
          SwitchListTile(
            secondary: const Icon(Icons.power_settings_new_outlined),
            title: const Text('禁止系统睡眠'),
            subtitle: const Text('应用运行期间阻止电脑自动休眠'),
            value: settings.windowsPreventSleep,
            onChanged: (v) async {
              final ok = await ref
                  .read(appSettingsProvider.notifier)
                  .setWindowsPreventSleep(v);
              if (!ok && context.mounted) {
                _showTopToast(
                  context,
                  title: '设置失败',
                  detail: '阻止系统休眠未生效，请重试。',
                  isError: true,
                );
              }
            },
          ),
        ],
      ),
    );
  }

  /// 关于分区卡片: 应用名称 / 版本 / 框架 / 作者 / 免责声明
  Widget _aboutCard(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Card(
      child: Column(
        children: [
          ListTile(
            dense: true,
            title: Text(
              '应用名称',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            subtitle: const Text('EWT Auto Client'),
          ),
          const Divider(height: 1, indent: 16, endIndent: 16),
          ListTile(
            dense: true,
            title: Text(
              '版本',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            subtitle: ref
                .watch(latestVersionProvider)
                .when(
                  data: (v) => Text('${v.isEmpty ? '未知' : v} (Flutter)'),
                  loading: () => const Text('加载中...'),
                  error: (_, _) => const Text('未知'),
                ),
            trailing: const Icon(Icons.chevron_right, size: 18),
            onTap: () => context.push('/changelog'),
          ),
          const Divider(height: 1, indent: 16, endIndent: 16),
          ListTile(
            dense: true,
            title: Text(
              '框架',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            subtitle: const Text('Flutter + Riverpod + Material 3'),
          ),
          const Divider(height: 1, indent: 16, endIndent: 16),
          ListTile(
            dense: true,
            title: Text(
              '作者',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            subtitle: const Text('XuxiaHaiyun'),
            trailing: const Icon(Icons.chevron_right, size: 18),
            onTap: () => _showAuthorDialog(context),
          ),
          const Divider(height: 1, indent: 16, endIndent: 16),
          ListTile(
            dense: true,
            title: Text(
              '免责声明',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            subtitle: const Text('使用本应用前请阅读'),
            trailing: const Icon(Icons.chevron_right, size: 18),
            onTap: () => _showDisclaimerDialog(context),
          ),
        ],
      ),
    );
  }

  String _initial(String? name) {
    if (name == null || name.isEmpty) return '?';
    return name[0].toUpperCase();
  }

  // ─── Dialogs ───

  /// 账号栏右键菜单 (桌面端右键)
  void _showAccountContextMenu(
    BuildContext context,
    WidgetRef ref,
    Offset position,
  ) {
    final authState = ref.read(authProvider);
    final session = authState is AuthAuthenticated ? authState.session : null;
    final account = session?.account ?? '';

    final items = <PopupMenuEntry<String>>[
      const PopupMenuItem(
        value: 'info',
        child: ListTile(
          leading: Icon(Icons.badge_outlined, size: 20),
          title: Text('账号详情'),
        ),
      ),
      const PopupMenuItem(
        value: 'switch',
        child: ListTile(
          leading: Icon(Icons.swap_horiz, size: 20),
          title: Text('切换账号'),
        ),
      ),
      if (account.isNotEmpty)
        const PopupMenuItem(
          value: 'changePassword',
          child: ListTile(
            leading: Icon(Icons.password, size: 20),
            title: Text('修改密码'),
          ),
        ),
      const PopupMenuItem(
        value: 'logout',
        child: ListTile(
          leading: Icon(Icons.logout, size: 20),
          title: Text('退出登录'),
        ),
      ),
    ];

    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx,
        position.dy,
      ),
      items: items,
    ).then((value) {
      if (value == null || !context.mounted) return;
      final settings = ref.read(appSettingsProvider);
      switch (value) {
        case 'info':
          _showAccountInfoDialog(context, ref, settings);
        case 'switch':
          _showSwitchAccountDialog(context, ref);
        case 'changePassword':
          _showChangePasswordDialog(context, ref, account);
        case 'logout':
          _confirmLogout(context, ref);
      }
    });
  }

  /// 修改密码弹窗 (账号板块右键菜单触发)
  ///
  /// 收集 当前密码 / 新密码 / 确认新密码，调用 [AuthNotifier.changePasswordLoggedIn]
  /// （账号中心"修改密码"接口，已登录 session 鉴权），成功后用新密码自动重登。
  void _showChangePasswordDialog(
    BuildContext context,
    WidgetRef ref,
    String account,
  ) {
    showDialog(
      context: context,
      builder: (ctx) => _ChangePasswordDialog(account: account),
    );
  }

  /// 账号详细信息弹窗 (右键 / 长按账号栏触发)
  void _showAccountInfoDialog(
    BuildContext context,
    WidgetRef ref,
    AppSettingsState settings,
  ) {
    final authState = ref.read(authProvider);
    final session = authState is AuthAuthenticated ? authState.session : null;
    final token = session?.token ?? '';
    final rows = <(String, String)>[
      ('账号', settings.mask(session?.account)),
      ('姓名', settings.mask(session?.displayName)),
      ('用户 ID', settings.mask(session?.userId)),
      ('学校 ID', settings.mask(session?.schoolId)),
      ('学校', settings.mask(session?.schoolName)),
      ('手机号', settings.mask(session?.mobile)),
      ('省份代码', settings.mask(session?.provinceCode)),
      ('Token', settings.mask(token)),
    ];

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.badge_outlined),
            SizedBox(width: 8),
            Text('账号详情'),
          ],
        ),
        content: SizedBox(
          width: 360,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final (label, value) in rows)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 90,
                          child: Text(
                            label,
                            style: TextStyle(
                              color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                              fontSize: 13,
                            ),
                          ),
                        ),
                        Expanded(
                          child: SelectableText(
                            value.isEmpty ? '-' : value,
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                            ),
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
          if (RiskControlGate.isFeatureEnabled('account_menu.copy_token') &&
              token.isNotEmpty)
            TextButton.icon(
              icon: const Icon(Icons.copy, size: 16),
              label: const Text('复制Token'),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: token));
                Navigator.pop(ctx);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Token 已复制到剪贴板'),
                    duration: Duration(seconds: 1),
                  ),
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

  void _showThemeModeDialog(
    BuildContext context,
    WidgetRef ref,
    AppSettingsState settings,
  ) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('主题模式'),
        content: RadioGroup<ThemeMode>(
          groupValue: settings.themeMode,
          onChanged: (v) {
            if (v == null) return;
            ref.read(appSettingsProvider.notifier).setThemeMode(v);
            Navigator.pop(ctx);
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              RadioListTile<ThemeMode>(
                title: const Text('深色'),
                value: ThemeMode.dark,
              ),
              RadioListTile<ThemeMode>(
                title: const Text('浅色'),
                value: ThemeMode.light,
              ),
              RadioListTile<ThemeMode>(
                title: const Text('跟随系统'),
                value: ThemeMode.system,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 强调色当前选项名称 (未匹配预设时显示"默认")
  String _accentColorLabel(Color color) {
    for (final preset in AppTheme.accentPresets) {
      if (preset.color.toARGB32() == color.toARGB32()) return preset.name;
    }
    return '默认';
  }

  /// 强调色选择弹窗
  ///
  /// 当前选中项显示对勾与描边; 选择后立即生效 (MaterialApp 主题即时切换)
  /// 并随 [appSettingsProvider] 持久化。
  void _showAccentColorDialog(
    BuildContext context,
    WidgetRef ref,
    AppSettingsState settings,
  ) {
    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('强调色'),
          // 约束 4 列色板 (4*52 + 3*14), 呈整齐 4x2 网格
          content: SizedBox(
            width: 250,
            child: SingleChildScrollView(
              child: Wrap(
                spacing: 14,
                runSpacing: 14,
                alignment: WrapAlignment.spaceEvenly,
                children: [
                  for (final preset in AppTheme.accentPresets)
                    _AccentSwatch(
                      name: preset.name,
                      color: preset.color,
                      selected: preset.color.toARGB32() ==
                          settings.accentColor.toARGB32(),
                      onSelect: () {
                        ref
                            .read(appSettingsProvider.notifier)
                            .setAccentColor(preset.color);
                        Navigator.pop(ctx);
                      },
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
          ],
        );
      },
    );
  }

  void _showIntervalDialog(
    BuildContext context,
    WidgetRef ref,
    AppSettingsState settings,
  ) {
    final controller = TextEditingController(
      text: settings.requestInterval.toString(),
    );

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('请求间隔'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: '间隔 (ms)',
            hintText: '0 - 5000',
            suffixText: 'ms',
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final ms = int.tryParse(controller.text) ?? 0;
              ref
                  .read(appSettingsProvider.notifier)
                  .setRequestInterval(ms.clamp(0, 5000));
              Navigator.pop(ctx);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  /// 连接重试次数选择 (0~5)
  void _showRetryCountDialog(
    BuildContext context,
    WidgetRef ref,
    AppSettingsState settings,
  ) {
    showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('连接重试次数'),
        children: [
          for (final n in [0, 1, 2, 3, 5])
            RadioGroup<int>(
              groupValue: settings.connectRetryCount,
              onChanged: (v) {
                if (v != null) {
                  ref.read(appSettingsProvider.notifier).setConnectRetryCount(v);
                }
                Navigator.pop(ctx);
              },
              child: RadioListTile<int>(
                value: n,
                title: Text(n == 0 ? '不重试' : '重试 $n 次'),
              ),
            ),
        ],
      ),
    );
  }

  /// 连接重试间隔选择 (ms)
  void _showRetryIntervalDialog(
    BuildContext context,
    WidgetRef ref,
    AppSettingsState settings,
  ) {
    showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('连接重试间隔'),
        children: [
          for (final ms in [500, 1000, 2000, 3000, 5000])
            RadioGroup<int>(
              groupValue: settings.connectRetryIntervalMs,
              onChanged: (v) {
                if (v != null) {
                  ref
                      .read(appSettingsProvider.notifier)
                      .setConnectRetryInterval(v);
                }
                Navigator.pop(ctx);
              },
              child: RadioListTile<int>(
                value: ms,
                title: Text('$ms ms'),
              ),
            ),
        ],
      ),
    );
  }

  String _appFontLabel(AppSettingsState settings) {
    switch (settings.appFontKind) {
      case 'system':
        for (final f in FontManager.systemFonts) {
          if (f.value == settings.appFontValue) return f.label;
        }
        return settings.appFontValue;
      case 'bundled':
        final opt = HandwrittenFontOption.all
            .where((o) => o.fontFamily == settings.appFontValue)
            .toList();
        if (settings.appFontValue == 'HarmonyOS') return 'HarmonyOS Sans SC';
        return opt.isEmpty ? settings.appFontValue : opt.first.label;
      case 'imported':
        return settings.appFontValue;
      default:
        return '默认字体 (跟随主题)';
    }
  }

  /// 字体管理弹窗: 默认 / 系统内置 / 应用内置字体包 / 导入字体 (可增删)
  ///
  /// 选中的字体注入全局主题 (AppTheme.fontFamily); 导入的字体同时
  /// 提供给手写模拟 (HandwritingFontConfig.custom 按路径加载)。
  void _showFontManagerDialog(
    BuildContext context,
    WidgetRef ref,
    AppSettingsState settings,
  ) {
    var kind = settings.appFontKind;
    var value = settings.appFontValue;

    final bundledFonts = [
      const AppFontOption(
        kind: 'bundled',
        value: 'HarmonyOS',
        label: 'HarmonyOS Sans SC (鸿蒙黑体)',
      ),
      for (final o in HandwrittenFontOption.all)
        AppFontOption(
          kind: 'bundled',
          value: o.fontFamily,
          label: '${o.label} (手写)',
        ),
    ];

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: const Text('字体管理'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 预览
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '预览：EWT 自动化客户端 Aa 0123',
                    style: TextStyle(
                      fontSize: 16,
                      fontFamily: kind == 'default' ? null : value,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Flexible(
                  child: SingleChildScrollView(
                    child: RadioGroup<String>(
                      groupValue: kind == 'default' ? '' : '$kind|$value',
                      onChanged: (v) {
                        if (v == null || v.isEmpty) {
                          setState(() {
                            kind = 'default';
                            value = '';
                          });
                        } else {
                          final i = v.indexOf('|');
                          setState(() {
                            kind = v.substring(0, i);
                            value = v.substring(i + 1);
                          });
                        }
                      },
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          RadioListTile<String>(
                            value: '',
                            title: const Text('默认字体 (跟随主题)'),
                            dense: true,
                          ),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                            child: Text(
                              '系统内置字体',
                              style: Theme.of(context)
                                  .textTheme
                                  .labelSmall
                                  ?.copyWith(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .primary,
                                  ),
                            ),
                          ),
                          for (final f in FontManager.systemFonts)
                            RadioListTile<String>(
                              value: 'system|${f.value}',
                              title: Text(f.label),
                              dense: true,
                            ),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                            child: Text(
                              '应用内置字体包',
                              style: Theme.of(context)
                                  .textTheme
                                  .labelSmall
                                  ?.copyWith(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .primary,
                                  ),
                            ),
                          ),
                          for (final f in bundledFonts)
                            RadioListTile<String>(
                              value: 'bundled|${f.value}',
                              title: Text(f.label),
                              dense: true,
                            ),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                            child: Text(
                              '导入字体 (显示 + 手写模拟共用)',
                              style: Theme.of(context)
                                  .textTheme
                                  .labelSmall
                                  ?.copyWith(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .primary,
                                  ),
                            ),
                          ),
                          for (final f in settings.importedFonts)
                            RadioListTile<String>(
                              value: 'imported|${f.family}',
                              title: Text(f.family),
                              secondary: IconButton(
                                icon: const Icon(Icons.delete_outline,
                                    size: 18),
                                tooltip: '删除该字体',
                                onPressed: () async {
                                  Navigator.pop(ctx);
                                  await ref
                                      .read(appSettingsProvider.notifier)
                                      .removeImportedFont(f);
                                },
                              ),
                              dense: true,
                            ),
                          if (settings.importedFonts.isEmpty)
                            const Padding(
                              padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                              child: Text(
                                '暂无导入字体，点击下方"导入字体"添加 TTF/OTF 文件',
                                style: TextStyle(fontSize: 12),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton.icon(
              icon: const Icon(Icons.file_open_outlined, size: 16),
              label: const Text('导入字体'),
              onPressed: () async {
                final font = await FontManager.importFont();
                if (font == null) {
                  if (ctx.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('导入失败或已取消 (支持 TTF/OTF/TTC)'),
                        behavior: SnackBarBehavior.floating,
                      ),
                    );
                  }
                  return;
                }
                await ref.read(appSettingsProvider.notifier).addImportedFont(font);
                if (ctx.mounted) {
                  setState(() {
                    kind = 'imported';
                    value = font.family;
                  });
                }
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('字体已导入: ${font.family}'),
                      behavior: SnackBarBehavior.floating,
                    ),
                  );
                }
              },
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                ref.read(appSettingsProvider.notifier).setAppFont(
                      kind: kind,
                      value: value,
                    );
                Navigator.pop(ctx);
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
  }

  /// 界面缩放选择
  void _showUiScaleDialog(
    BuildContext context,
    WidgetRef ref,
    AppSettingsState settings,
  ) {
    showDialog<double>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('界面缩放'),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Text(
              '在系统字体缩放基础上整体调整界面文字大小',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ),
          for (final s in [0.9, 1.0, 1.1, 1.25, 1.4])
            RadioGroup<double>(
              groupValue: settings.uiScale,
              onChanged: (v) {
                if (v != null) {
                  ref.read(appSettingsProvider.notifier).setUiScale(v);
                }
                Navigator.pop(ctx);
              },
              child: RadioListTile<double>(
                value: s,
                title: Text('${(s * 100).toStringAsFixed(0)}%'),
              ),
            ),
        ],
      ),
    );
  }

  String _pageTransitionLabel(String kind) => switch (kind) {
        'fade' => '渐显',
        'slide' => '滑动',
        'none' => '无动画',
        _ => '原生 (跟随平台)',
      };

  /// 页面过渡动画选择
  void _showPageTransitionDialog(
    BuildContext context,
    WidgetRef ref,
    AppSettingsState settings,
  ) {
    showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('页面过渡动画'),
        children: [
          for (final e in [
            ('native', '原生 (跟随平台)'),
            ('fade', '渐显'),
            ('slide', '滑动'),
            ('none', '无动画'),
          ])
            RadioGroup<String>(
              groupValue: settings.pageTransition,
              onChanged: (v) {
                if (v != null) {
                  ref.read(appSettingsProvider.notifier).setPageTransition(v);
                }
                Navigator.pop(ctx);
              },
              child: RadioListTile<String>(
                value: e.$1,
                title: Text(e.$2),
              ),
            ),
        ],
      ),
    );
  }

  /// 自动签到开关回调 (开关即执行)
  ///
  /// 开启时: 校验登录态 → 持久化开启 → 用当前账号完成每日签到 → 顶部弹窗统计。
  /// 关闭时: 仅持久化关闭, 不发起请求。
  /// 未登录时不允许开启 (开关自动回弹并提示)。
  Future<void> _onCheckinRaceToggled(
    BuildContext context,
    WidgetRef ref,
    AppSettingsState settings,
    bool enabled,
  ) async {
    if (enabled == settings.checkinRaceEnabled) return;
    if (!enabled) {
      ref.read(appSettingsProvider.notifier).setCheckinRaceEnabled(false);
      return;
    }
    // 校验登录态 (签到需当前账号 token)
    final authState = ref.read(authProvider);
    final session = authState is AuthAuthenticated ? authState.session : null;
    if (session == null || session.token.isEmpty) {
      if (context.mounted) {
        _showTopToast(
          context,
          title: '请先登录',
          detail: '自动签到需使用当前登录账号，请先登录后再开启。',
          isError: true,
        );
      }
      return; // 不持久化, 开关保持关闭
    }
    // 持久化开启并立即发送一次签到请求
    ref.read(appSettingsProvider.notifier).setCheckinRaceEnabled(true);
    final outcome = await ref.read(checkinRaceProvider.notifier).runRace();
    if (context.mounted) _showTopResultToast(context, outcome);
  }

  /// 保活总开关回调
  ///
  /// 开启时补齐运行时权限:
  /// - 通知权限 (Android 13+): 框架前台服务的常驻通知需要;
  /// - 已开启的各策略所需权限 (蓝牙/媒体/联系人/短信)。
  Future<void> _onKeepAliveToggled(
    BuildContext context,
    WidgetRef ref,
    bool enabled,
  ) async {
    if (enabled) {
      await KeepAliveChannel.requestNotificationPermission();
      final settings = ref.read(appSettingsProvider);
      for (final key in settings.fwOptions.keys) {
        if (settings.fwOptions[key] == true) {
          await KeepAliveChannel.requestOptionPermissions(key);
        }
      }
    }
    await ref.read(appSettingsProvider.notifier).setKeepAliveEnabled(enabled);
  }

  /// 需运行时权限的选项 → 权限用途说明 (拒绝授权时提示用)
  static const _optionPermissionHints = <String, String>{
    'bluetoothBroadcast': '蓝牙权限',
    'mediaContentObserver': '照片和视频权限',
    'contactsContentObserver': '联系人权限',
    'smsContentObserver': '短信权限',
  };

  /// 框架选项开关回调
  ///
  /// 开启需系统授权的选项时先检查/拉起授权; 授权未完成则开关保持关闭
  /// (原生侧 sanitizeConsentGatedOption 同步兜底强制关闭, 保证不崩溃):
  /// - VPN: 系统 VPN 授权对话框 (未授权时框架服务启动会崩溃, 硬性门控);
  /// - 悬浮窗: "显示在其他应用上层"权限;
  /// - 定时唤醒: Android 12+ "闹钟和提醒"精确闹钟权限;
  /// - 设备管理员: 系统激活界面;
  /// - 蓝牙/媒体/联系人/短信: 运行时权限 (未授权也允许开启, 仅提示受限)。
  Future<void> _onFwOptionToggled(
    BuildContext context,
    WidgetRef ref,
    _FwOptionSpec opt,
    bool enabling,
  ) async {
    if (enabling) {
      // VPN: 必须先完成系统授权, 否则框架启动 VPN 服务时会因未调用
      // startForeground 触发 ForegroundServiceDidNotStartInTime 崩溃
      if (opt.key == 'vpnService') {
        final consented = await KeepAliveChannel.prepareVpnAuthorization();
        if (!context.mounted) return;
        if (!consented) {
          _showTopToast(
            context,
            title: '请在系统 VPN 授权对话框中点击"确定"',
            detail: '授权成功后重新开启「${opt.label}」即可生效。',
          );
          return;
        }
      }
      // 悬浮窗: 未授权时浮窗添加视图会抛异常
      if (opt.key == 'floatWindow') {
        final granted = await KeepAliveChannel.isOverlayGranted();
        if (!context.mounted) return;
        if (!granted) {
          await KeepAliveChannel.openOverlaySettings();
          if (!context.mounted) return;
          _showTopToast(
            context,
            title: '请授予悬浮窗权限',
            detail: '在授权页允许"显示在其他应用上层"后，重新开启「${opt.label}」即可生效。',
          );
          return;
        }
      }
      // 定时唤醒: Android 12+ 未授权精确闹钟时 setExact 抛 SecurityException
      if (opt.key == 'scheduledWakeup') {
        final granted = await KeepAliveChannel.isExactAlarmGranted();
        if (!context.mounted) return;
        if (!granted) {
          await KeepAliveChannel.openExactAlarmSettings();
          if (!context.mounted) return;
          _showTopToast(
            context,
            title: '请授予"闹钟和提醒"权限',
            detail: '授权后重新开启「${opt.label}」即可生效。',
          );
          return;
        }
      }
      // 设备管理员: 直接拉起系统激活界面, 激活完成后重新开启
      if (opt.key == 'deviceAdmin') {
        final active = await KeepAliveChannel.requestDeviceAdmin();
        if (!context.mounted) return;
        if (!active) {
          _showTopToast(
            context,
            title: '请激活设备管理员',
            detail: '在系统激活界面确认后，重新开启「${opt.label}」即可生效。',
          );
          return;
        }
      }
      final allGranted = await KeepAliveChannel.requestOptionPermissions(
        opt.key,
      );
      if (!allGranted && context.mounted) {
        final hint = _optionPermissionHints[opt.key];
        if (hint != null) {
          _showTopToast(
            context,
            title: '权限请求已弹出',
            detail: '授予$hint后「${opt.label}」才能完整生效，未授权时策略可能无效。',
          );
        }
      }
      // 伴侣设备需要系统配对授权流程, 未完成授权时原生侧保持关闭
      if (opt.key == 'companionDevice' && context.mounted) {
        _showTopToast(
          context,
          title: '「${opt.label}」需要系统授权',
          detail: '完成系统授权流程前该选项不会实际生效。',
        );
      }
    }
    await ref.read(appSettingsProvider.notifier).setFwOption(opt.key, enabling);
  }

  /// 自动签到结果 - 顶部 Toast 统计
  void _showTopResultToast(BuildContext context, CheckinRaceOutcome outcome) {
    final title = outcome.errorMessage != null
        ? '自动签到失败'
        : (outcome.success > 0 ? '自动签到成功' : '今日已签到 / 签到未成功');
    final detail = outcome.errorMessage != null
        ? outcome.errorMessage!
        : (outcome.attempts.isNotEmpty
              ? 'code ${outcome.attempts.first.code}：${outcome.attempts.first.msg}'
              : '无返回');
    _showTopToast(
      context,
      title: title,
      detail: detail,
      isError: outcome.errorMessage != null,
    );
  }

  /// 通用顶部 Toast (浮层 SnackBar 贴顶)
  void _showTopToast(
    BuildContext context, {
    required String title,
    required String detail,
    bool isError = false,
  }) {
    final theme = Theme.of(context);
    final mq = MediaQuery.of(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        margin: EdgeInsets.only(
          bottom: mq.size.height - 96,
          left: 16,
          right: 16,
        ),
        backgroundColor: isError
            ? theme.colorScheme.errorContainer
            : theme.colorScheme.surfaceContainerHigh,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: isError
                    ? theme.colorScheme.onErrorContainer
                    : theme.colorScheme.onSurface,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              detail,
              style: TextStyle(
                fontSize: 12,
                color: isError
                    ? theme.colorScheme.onErrorContainer
                    : theme.colorScheme.onSurfaceVariant,
              ),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
        duration: const Duration(seconds: 5),
      ),
    );
  }

  /// 当前登录账号代理设置弹窗
  ///
  /// 保存后三处同步生效:
  /// 1. 全局 DioClient (当前会话后续请求立即走新代理 / 直连)
  /// 2. 当前会话 (authProvider + SessionStore 持久化, 重启后保留)
  /// 3. 已保存账号列表对应条目 (登录页批量任务按账号走独立代理时沿用)
  Future<void> _showAccountProxyDialog(
    BuildContext context,
    WidgetRef ref,
    UserSession session,
  ) async {
    final controller = TextEditingController(text: session.proxy ?? '');

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: const Text('代理设置'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: controller,
                decoration: InputDecoration(
                  labelText: '代理地址',
                  hintText: 'ip:port / http://ip:port / socks5://ip:port',
                  helperText: '留空恢复直连',
                  errorText: _proxyError(controller.text),
                ),
                autofocus: true,
                onChanged: (_) => setState(() {}),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            FilledButton(
              // 格式无效时禁止保存 (留空=直连合法)
              onPressed: _proxyError(controller.text) == null
                  ? () => Navigator.pop(ctx, true)
                  : null,
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    if (saved != true) return;

    final clean = controller.text.trim().isEmpty ? null : controller.text.trim();
    // 1) 当前会话 + 全局 DioClient (内部同步代理到全局客户端并持久化)
    await ref.read(authProvider.notifier).updateCurrentSessionProxy(clean);
    // 2) 同步已保存账号列表条目 (批量任务/重新登录按账号继承)
    await AccountStorage.setAccountProxy(session, clean);
    // 3) 刷新账号列表状态
    await ref.read(accountProvider.notifier).reload();

    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(clean == null ? '代理已清除, 恢复直连' : '代理已设置: $clean'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  /// 代理地址格式校验 (留空合法; 非法返回错误提示)
  String? _proxyError(String value) {
    final t = value.trim();
    if (t.isEmpty) return null;
    return parseProxySpec(t) == null ? '格式无效, 示例: 127.0.0.1:8080' : null;
  }

  void _showDeviceInfoDialog(BuildContext context) {
    showDialog(context: context, builder: (_) => const _DeviceInfoDialog());
  }

  void _showAuthorDialog(BuildContext context) {
    final theme = Theme.of(context);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('XuxiaHaiyun'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.chat_bubble_outline),
              title: const Text('联系作者'),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              onTap: () {
                Navigator.pop(ctx);
                _showQrcodeDialog(
                  context,
                  '联系作者',
                  'assets/images/qq_qrcode.jpg',
                );
              },
            ),
            ListTile(
              leading: Icon(
                Icons.favorite_outline,
                color: theme.colorScheme.error,
              ),
              title: const Text('打赏作者'),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              onTap: () {
                Navigator.pop(ctx);
                _showQrcodeDialog(
                  context,
                  '打赏作者',
                  'assets/images/mm_reward_qrcode.png',
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showQrcodeDialog(BuildContext context, String title, String assetPath) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Image.asset(assetPath, width: 260, fit: BoxFit.contain),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  void _showDisclaimerDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('免责声明'),
        content: const SingleChildScrollView(
          child: Text(
            '本应用仅供学习与技术研究使用。\n\n'
            '1. 本应用不涉及任何商业盈利目的，所有功能仅用于个人学习自动化操作。\n\n'
            '2. 使用本应用产生的一切后果由用户自行承担，作者不对任何直接或间接损失负责。\n\n'
            '3. 本应用不会收集、上传或泄露用户的任何隐私数据，所有请求均在用户本地设备发起。\n\n'
            '4. 请遵守相关平台的服务条款，因使用本应用导致的账号风险由用户自行承担。\n\n'
            '5. 如侵犯了您的权益，请联系作者删除。',
            style: TextStyle(height: 1.5),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('我知道了'),
          ),
        ],
      ),
    );
  }

  void _showSwitchAccountDialog(BuildContext context, WidgetRef ref) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('切换账号'),
        content: const Text('将返回登录页面，可选择其他账号登录。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              ref.read(authProvider.notifier).switchAccount();
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  void _confirmLogout(BuildContext context, WidgetRef ref) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('退出登录'),
        content: const Text('确定要退出当前账号吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () {
              Navigator.pop(ctx);
              ref.read(authProvider.notifier).logout();
            },
            child: const Text('退出'),
          ),
        ],
      ),
    );
  }

  String _themeModeLabel(ThemeMode mode) {
    return switch (mode) {
      ThemeMode.dark => '深色',
      ThemeMode.light => '浅色',
      ThemeMode.system => '跟随系统',
    };
  }

  /// 主页导航 TAB 显示文案
  String _visibleTabsLabel(List<String> tabs) {
    const labels = {
      '/home': '首页',
      '/tasks': '任务',
      '/weekend': '周培优',
      '/settings': '设置',
    };
    final shown = [...tabs, '/settings'].map((r) => labels[r] ?? r).join(' / ');
    return shown;
  }

  /// 保活引导弹窗 (操作步骤 + 可选“前往系统设置”按钮)
  void _showKeepAliveGuide(
    BuildContext context, {
    required String title,
    required List<String> steps,
    String? actionLabel,
    Future<bool> Function()? action,
  }) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 380,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < steps.length; i++) ...[
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${i + 1}. ',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      Expanded(child: Text(steps[i])),
                    ],
                  ),
                  const SizedBox(height: 8),
                ],
              ],
            ),
          ),
        ),
        actions: [
          if (actionLabel != null && action != null)
            FilledButton(
              onPressed: () async {
                final ok = await action();
                if (!context.mounted) return;
                Navigator.pop(ctx);
                if (!ok) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('未能打开系统设置，请手动操作'),
                      behavior: SnackBarBehavior.floating,
                    ),
                  );
                }
              },
              child: Text(actionLabel),
            ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  /// 选择主页导航栏显示的 TAB (设置 TAB 固定显示不可隐藏)
  void _showVisibleTabsDialog(
    BuildContext context,
    WidgetRef ref,
    AppSettingsState settings,
  ) {
    const options = [
      (route: '/home', label: '首页', icon: Icons.home_outlined),
      (route: '/tasks', label: '任务', icon: Icons.assignment_outlined),
      (route: '/weekend', label: '周培优', icon: Icons.school_outlined),
    ];
    final selected = <String>{...settings.visibleTabs};

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: const Text('主页导航 TAB'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final opt in options)
                  CheckboxListTile(
                    value: selected.contains(opt.route),
                    title: Row(
                      children: [
                        Icon(opt.icon, size: 20),
                        const SizedBox(width: 8),
                        Text(opt.label),
                      ],
                    ),
                    // 至少保留一个 TAB
                    onChanged: (v) {
                      setState(() {
                        if (v == true) {
                          selected.add(opt.route);
                        } else if (selected.length > 1) {
                          selected.remove(opt.route);
                        }
                      });
                    },
                  ),
                CheckboxListTile(
                  value: true,
                  title: const Row(
                    children: [
                      Icon(Icons.settings_outlined, size: 20),
                      SizedBox(width: 8),
                      Text('设置'),
                    ],
                  ),
                  subtitle: const Text('固定显示，不可隐藏'),
                  onChanged: null,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                ref
                    .read(appSettingsProvider.notifier)
                    .setVisibleTabs(selected.toList());
                Navigator.pop(ctx);
              },
              child: const Text('确定'),
            ),
          ],
        ),
      ),
    );
  }
}

/// 分区标题
class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader({required this.title});

  @override
  Widget build(BuildContext context) {
    return Text(
      title,
      style: Theme.of(context).textTheme.titleSmall?.copyWith(
        color: Theme.of(context).colorScheme.primary,
        fontWeight: FontWeight.w600,
      ),
    );
  }
}

/// 强调色选择弹窗中的单个色板项: 圆形色块 + 名称, 选中项带对勾与描边
class _AccentSwatch extends StatelessWidget {
  final String name;
  final Color color;
  final bool selected;
  final VoidCallback onSelect;

  const _AccentSwatch({
    required this.name,
    required this.color,
    required this.selected,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selectedColor = theme.colorScheme.onSurface;
    return InkWell(
      onTap: onSelect,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                border: Border.all(
                  color: selected ? selectedColor : Colors.transparent,
                  width: 2,
                ),
              ),
              child: selected
                  ? Icon(Icons.check, size: 20, color: selectedColor)
                  : null,
            ),
            const SizedBox(height: 6),
            Text(
              name,
              style: theme.textTheme.labelSmall?.copyWith(
                color: selected
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurfaceVariant,
                fontWeight: selected ? FontWeight.w600 : null,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 电池优化豁免磁贴: 显示系统真实豁免状态, 点击直接拉起授权对话框。
class _BatteryOptimizationTile extends StatefulWidget {
  const _BatteryOptimizationTile();

  @override
  State<_BatteryOptimizationTile> createState() =>
      _BatteryOptimizationTileState();
}

class _BatteryOptimizationTileState extends State<_BatteryOptimizationTile> {
  bool? _ignored;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final ignored = await KeepAliveChannel.isIgnoringBatteryOptimizations()
        .catchError((_) => false);
    if (mounted) setState(() => _ignored = ignored);
  }

  @override
  Widget build(BuildContext context) {
    final ignored = _ignored;
    return ListTile(
      leading: const Icon(Icons.battery_charging_full_outlined),
      title: const Text('电池优化豁免'),
      subtitle: Text(switch (ignored) {
        null => '查询系统状态中...',
        true => '已豁免电池优化，系统不会因省电限制本应用',
        false => '未豁免，点击授权以降低后台被查杀概率',
      }),
      trailing: ignored == true
          ? Icon(
              Icons.check_circle_outline,
              color: Theme.of(context).colorScheme.primary,
            )
          : const Icon(Icons.chevron_right, size: 20),
      onTap: () async {
        // 直接弹系统豁免对话框; 部分 ROM 不支持时回退设置页
        final ok = await KeepAliveChannel.requestIgnoreBatteryOptimizations();
        if (!ok && context.mounted) {
          await KeepAliveChannel.openAndroidSettings('battery');
        }
        await _refresh();
      },
    );
  }
}

/// 固定应用磁贴: 直接使用系统 API 固定本应用。
///
/// Android 9+ 调用 startLockTask() 直接拉起系统固定确认对话框;
/// 8.x 及以下需先开启系统"屏幕固定"(未开启时原生侧会代为打开设置页,
/// 开启后重试即可)。已固定时点击直接解除 (stopLockTask)。
class _PinAppTile extends StatefulWidget {
  const _PinAppTile();

  @override
  State<_PinAppTile> createState() => _PinAppTileState();
}

class _PinAppTileState extends State<_PinAppTile> {
  bool? _pinned;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final pinned = await KeepAliveChannel.isAppPinned().catchError((_) => false);
    if (mounted) setState(() => _pinned = pinned);
  }

  void _toast(String title, String detail, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$title：$detail'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _toggle() async {
    if (_pinned == true) {
      final ok = await KeepAliveChannel.unpinApp();
      if (!mounted) return;
      if (!ok) _toast('解除失败', '当前可能未被固定，请重试', isError: true);
    } else {
      final ok = await KeepAliveChannel.pinApp();
      if (!mounted) return;
      if (!ok) {
        _toast(
          '需先开启屏幕固定',
          '已为你打开系统设置页，开启"屏幕固定"后回到本页重试',
          isError: true,
        );
      }
    }
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final pinned = _pinned;
    return ListTile(
      leading: const Icon(Icons.push_pin_outlined),
      title: const Text('固定应用'),
      subtitle: Text(switch (pinned) {
        null => '查询系统状态中...',
        true => '已固定本应用（清理后台不会被关闭），点击解除固定',
        false => '点击直接固定本应用（Android 9+ 弹系统确认；低版本先开屏幕固定）',
      }),
      trailing: pinned == true
          ? Icon(
              Icons.check_circle_outline,
              color: Theme.of(context).colorScheme.primary,
            )
          : const Icon(Icons.chevron_right, size: 20),
      onTap: _toggle,
    );
  }
}

/// 添加桌面卡片磁贴: requestPinAppWidget 直接拉起系统添加确认。
///
/// 用户确认后原生侧自动启动"模拟更新"闹钟 (每 5 分钟向框架 FwWidgetProvider
/// 发送 APPWIDGET_UPDATE): 卡片内容刷新的同时拉起前台服务, 保持后台驻留。
/// 已添加卡片时点击可手动触发一次模拟更新。
class _PinWidgetTile extends StatefulWidget {
  const _PinWidgetTile();

  @override
  State<_PinWidgetTile> createState() => _PinWidgetTileState();
}

class _PinWidgetTileState extends State<_PinWidgetTile> {
  bool? _supported;
  bool? _bound;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final supported = await KeepAliveChannel.isPinWidgetSupported()
        .catchError((_) => false);
    final bound =
        await KeepAliveChannel.isWidgetBound().catchError((_) => false);
    if (mounted) {
      setState(() {
        _supported = supported;
        _bound = bound;
      });
    }
  }

  void _toast(String title, String detail, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$title：$detail'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  /// 低版本 / 启动器不支持时的手动添加引导
  void _guide() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('添加桌面卡片'),
        content: const Text(
          '当前系统或桌面暂不支持直接添加，请手动操作：\n\n'
          '1. 在桌面空白处长按，选择"窗口小部件 / 微件"。\n'
          '2. 在列表中找到本应用的小部件。\n'
          '3. 长按并拖到桌面空白处完成添加。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Future<void> _onTap() async {
    final supported = _supported ?? false;
    final bound = _bound ?? false;
    if (!supported) {
      _guide();
      return;
    }
    if (bound) {
      final ok = await KeepAliveChannel.refreshKeepAliveWidget();
      if (!mounted) return;
      _toast(
        ok ? '已触发模拟更新' : '触发失败',
        ok ? '卡片已刷新并拉起前台服务保持驻留' : '卡片可能已从桌面移除，请重新添加',
        isError: !ok,
      );
      await _refresh();
      return;
    }
    final ok = await KeepAliveChannel.pinKeepAliveWidget();
    if (!mounted) return;
    if (ok) {
      _toast('已拉起系统添加确认', '在系统对话框中确认后，卡片开始模拟更新保持驻留');
    } else {
      _toast('未能拉起添加确认', '当前桌面可能不支持，请长按桌面空白处手动添加', isError: true);
    }
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final supported = _supported;
    final bound = _bound ?? false;
    final subtitle = switch (supported) {
      null => '查询系统支持中...',
      false => '当前系统/桌面不支持直接添加，点击查看手动添加步骤',
      true when !bound => '点击直接添加保活卡片，添加后每 5 分钟模拟更新保持后台驻留',
      true => '已添加到桌面 · 每 5 分钟模拟更新保持后台驻留，点击立即刷新',
    };
    return ListTile(
      leading: const Icon(Icons.widgets_outlined),
      title: const Text('添加桌面卡片'),
      subtitle: Text(subtitle),
      trailing: bound
          ? Icon(
              Icons.check_circle_outline,
              color: Theme.of(context).colorScheme.primary,
            )
          : const Icon(Icons.chevron_right, size: 20),
      onTap: _onTap,
    );
  }
}

/// 设备信息编辑弹窗（默认填写当前配置）
class _DeviceInfoDialog extends StatefulWidget {
  const _DeviceInfoDialog();

  @override
  State<_DeviceInfoDialog> createState() => _DeviceInfoDialogState();
}

class _DeviceInfoDialogState extends State<_DeviceInfoDialog> {
  late final TextEditingController _uaCtrl;
  late final TextEditingController _sdkCtrl;
  late final TextEditingController _secChUaCtrl;
  late final TextEditingController _secChPlatformCtrl;

  @override
  void initState() {
    super.initState();
    final config = getIt<EndpointConfig>();
    _uaCtrl = TextEditingController(text: config.userAgent);
    _sdkCtrl = TextEditingController(text: config.sdkVersion);
    _secChUaCtrl = TextEditingController(
      text: config.extraHeaders['sec-ch-ua'] ?? '',
    );
    _secChPlatformCtrl = TextEditingController(
      text: config.extraHeaders['sec-ch-ua-platform'] ?? '',
    );
  }

  @override
  void dispose() {
    _uaCtrl.dispose();
    _sdkCtrl.dispose();
    _secChUaCtrl.dispose();
    _secChPlatformCtrl.dispose();
    super.dispose();
  }

  void _save() {
    final config = getIt<EndpointConfig>();
    final headers = Map<String, String>.from(config.extraHeaders);
    headers['sec-ch-ua'] = _secChUaCtrl.text.trim();
    headers['sec-ch-ua-platform'] = _secChPlatformCtrl.text.trim();
    config.update(
      userAgent: _uaCtrl.text.trim(),
      sdkVersion: _sdkCtrl.text.trim(),
      extraHeaders: headers,
    );
    Navigator.of(context).pop();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('设备信息已保存'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final config = getIt<EndpointConfig>();

    return AlertDialog(
      title: const Text('设备信息'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ─── API ───
              Text(
                'API',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _uaCtrl,
                decoration: const InputDecoration(
                  labelText: 'User-Agent',
                  isDense: true,
                ),
                maxLines: 2,
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _sdkCtrl,
                decoration: const InputDecoration(
                  labelText: 'SDK 版本',
                  isDense: true,
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: TextEditingController(text: config.origin),
                readOnly: true,
                decoration: const InputDecoration(
                  labelText: 'Origin',
                  isDense: true,
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: TextEditingController(text: config.referer),
                readOnly: true,
                decoration: const InputDecoration(
                  labelText: 'Referer',
                  isDense: true,
                ),
              ),
              const SizedBox(height: 18),
              // ─── 请求头 ───
              Text(
                '请求头',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _secChUaCtrl,
                decoration: const InputDecoration(
                  labelText: 'sec-ch-ua',
                  isDense: true,
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _secChPlatformCtrl,
                decoration: const InputDecoration(
                  labelText: 'sec-ch-ua-platform',
                  isDense: true,
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
        FilledButton(onPressed: _save, child: const Text('保存')),
      ],
    );
  }
}

/// 修改密码弹窗（账号板块右键菜单触发）
///
/// 收集 当前密码 / 新密码 / 确认新密码，提交后调用 [AuthNotifier.changePasswordLoggedIn]
/// （账号中心"修改密码"接口，已登录 session 鉴权），成功后用新密码自动重登。
///
/// 布局遵循弹窗约束：内容固定宽度 `SizedBox(width: 420)` + Column，不使用
/// `width: double.infinity` 包裹 ListView，避免 M3 固有宽度查询崩溃。
class _ChangePasswordDialog extends ConsumerStatefulWidget {
  final String account;
  const _ChangePasswordDialog({required this.account});

  @override
  ConsumerState<_ChangePasswordDialog> createState() =>
      _ChangePasswordDialogState();
}

class _ChangePasswordDialogState extends ConsumerState<_ChangePasswordDialog> {
  final _formKey = GlobalKey<FormState>();
  final _oldCtrl = TextEditingController();
  final _newCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();
  bool _obscureOld = true;
  bool _obscureNew = true;
  bool _obscureConfirm = true;
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _oldCtrl.dispose();
    _newCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final res = await ref
        .read(authProvider.notifier)
        .changePasswordLoggedIn(
          account: widget.account,
          oldPassword: _oldCtrl.text,
          newPassword: _newCtrl.text,
        );
    if (!mounted) return;
    setState(() => _submitting = false);
    if (res.success) {
      navigator.pop();
      messenger.showSnackBar(
        SnackBar(
          content: Text(res.msg ?? '修改密码成功'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } else {
      setState(() => _error = res.msg ?? '修改密码失败');
    }
  }

  Widget _field(
    String label,
    TextEditingController controller,
    bool obscure,
    VoidCallback toggleObscure, {
    String? Function(String?)? validator,
  }) {
    return TextFormField(
      controller: controller,
      obscureText: obscure,
      decoration: InputDecoration(
        labelText: label,
        isDense: true,
        border: const OutlineInputBorder(),
        suffixIcon: IconButton(
          icon: Icon(
            obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined,
            size: 20,
          ),
          onPressed: toggleObscure,
        ),
      ),
      validator: validator,
      onChanged: (_) {
        if (_error != null) setState(() => _error = null);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.password, size: 22),
          SizedBox(width: 8),
          Text('修改密码'),
        ],
      ),
      content: SizedBox(
        width: 420,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_error != null) ...[
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.errorContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: theme.colorScheme.onErrorContainer,
                      fontSize: 13,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
              ],
              _field(
                '当前密码',
                _oldCtrl,
                _obscureOld,
                () => setState(() => _obscureOld = !_obscureOld),
                validator: (v) => (v == null || v.isEmpty) ? '请输入当前密码' : null,
              ),
              const SizedBox(height: 12),
              _field(
                '新密码',
                _newCtrl,
                _obscureNew,
                () => setState(() => _obscureNew = !_obscureNew),
                validator: (v) {
                  if (v == null || v.isEmpty) return '请输入新密码';
                  if (v.length < 6) return '密码至少 6 位';
                  if (v == _oldCtrl.text) return '新密码不能与当前密码相同';
                  return null;
                },
              ),
              const SizedBox(height: 12),
              _field(
                '确认新密码',
                _confirmCtrl,
                _obscureConfirm,
                () => setState(() => _obscureConfirm = !_obscureConfirm),
                validator: (v) {
                  if (v == null || v.isEmpty) return '请再次输入新密码';
                  if (v != _newCtrl.text) return '两次输入的新密码不一致';
                  return null;
                },
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _submitting ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _submitting ? null : _submit,
          child: _submitting
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('修改并重新登录'),
        ),
      ],
    );
  }
}

/// KeepLiveService 框架单条选项的 UI 描述
class _FwOptionSpec {
  final String key;
  final IconData icon;
  final String label;
  final String subtitle;
  const _FwOptionSpec(this.key, this.icon, this.label, this.subtitle);
}

/// 框架选项分组目录: 渲染顺序即 UI 顺序, 键与原生 FwConfigExt.FwOptionKeys
/// 一一对应 (MediaRoute 策略的服务已从合并 Manifest 移除, 不提供开关)。
const _fwOptionGroups = <({String title, List<_FwOptionSpec> options})>[
  (
    title: '核心策略',
    options: [
      _FwOptionSpec(
        'scheduledWakeup',
        Icons.alarm_outlined,
        '定时唤醒',
        'JobScheduler/WorkManager/闹钟周期拉起',
      ),
      _FwOptionSpec(
        'accountSync',
        Icons.sync_outlined,
        '账户同步保活',
        '注册系统账号, 由系统同步机制周期拉起',
      ),
      _FwOptionSpec(
        'systemBroadcast',
        Icons.settings_suggest_outlined,
        '系统静态广播',
        '开机完成/屏幕解锁等系统事件触发自启',
      ),
      _FwOptionSpec(
        'bluetoothBroadcast',
        Icons.bluetooth_outlined,
        '蓝牙广播唤醒',
        '蓝牙开关/连接等事件触发自启 (需蓝牙权限)',
      ),
      _FwOptionSpec(
        'mediaSession',
        Icons.music_note_outlined,
        'MediaSession 媒体会话',
        '注册媒体会话提升进程优先级',
      ),
      _FwOptionSpec(
        'silentAudio',
        Icons.volume_off_outlined,
        '静音音频保活',
        '循环播放无声音频防 CPU 休眠 (耗电偏高)',
      ),
    ],
  ),
  (
    title: '外设与媒体广播',
    options: [
      _FwOptionSpec(
        'mediaButtonReceiver',
        Icons.headphones_outlined,
        '媒体按键广播',
        '耳机/蓝牙媒体按键事件触发自启',
      ),
      _FwOptionSpec(
        'usbBroadcast',
        Icons.usb_outlined,
        'USB 广播',
        'USB 插拔事件触发自启',
      ),
      _FwOptionSpec('nfcBroadcast', Icons.nfc_outlined, 'NFC 广播', 'NFC 事件触发自启'),
      _FwOptionSpec(
        'mediaMountBroadcast',
        Icons.sd_card_outlined,
        '媒体挂载广播',
        '存储挂载/卸载事件触发自启',
      ),
    ],
  ),
  (
    title: '内容观察者',
    options: [
      _FwOptionSpec(
        'mediaContentObserver',
        Icons.photo_library_outlined,
        '相册观察',
        '相册内容变化拉起 (需存储权限)',
      ),
      _FwOptionSpec(
        'settingsContentObserver',
        Icons.tune_outlined,
        '系统设置观察',
        '系统设置变化拉起',
      ),
      _FwOptionSpec(
        'fileObserver',
        Icons.folder_outlined,
        '文件变化观察',
        '应用目录文件变化拉起',
      ),
      _FwOptionSpec(
        'contactsContentObserver',
        Icons.contacts_outlined,
        '联系人观察',
        '联系人变化拉起 (需敏感权限, 慎开)',
      ),
      _FwOptionSpec(
        'smsContentObserver',
        Icons.sms_outlined,
        '短信观察',
        '短信变化拉起 (需敏感权限, 慎开)',
      ),
    ],
  ),
  (
    title: '进程守护',
    options: [
      _FwOptionSpec(
        'dualProcess',
        Icons.copy_all_outlined,
        '双进程互保',
        '两个进程环形监听互相拉起',
      ),
      _FwOptionSpec(
        'nativeDaemon',
        Icons.terminal_outlined,
        'Native 守护',
        'C 层守护进程监控拉起',
      ),
      _FwOptionSpec(
        'nativeSocket',
        Icons.lan_outlined,
        'Socket 心跳',
        '本地 Socket 心跳监控拉起',
      ),
      _FwOptionSpec(
        'forceStopResistance',
        Icons.gpp_bad_outlined,
        '防强停',
        '对抗用户强制停止 (侵入性强, 仅部分系统有效, 慎开)',
      ),
    ],
  ),
  (
    title: '屏幕类',
    options: [
      _FwOptionSpec(
        'onePixel',
        Icons.crop_free_outlined,
        '1 像素 Activity',
        '息屏时切 1 像素界面保进程 (侵入性较强)',
      ),
      _FwOptionSpec(
        'lockScreenActivity',
        Icons.lock_clock_outlined,
        '锁屏 Activity',
        '锁屏时显示常驻页面保进程 (侵入性较强)',
      ),
      _FwOptionSpec(
        'floatWindow',
        Icons.picture_in_picture_alt_outlined,
        '悬浮窗',
        '悬浮窗视图保活 (需悬浮窗权限)',
      ),
      _FwOptionSpec(
        'dreamService',
        Icons.slideshow_outlined,
        '屏保保活',
        '注册系统屏保 (DreamService)',
      ),
    ],
  ),
  (
    title: '系统组件',
    options: [
      _FwOptionSpec(
        'tileService',
        Icons.grid_view_outlined,
        '快捷设置磁贴',
        '下拉快捷面板中提供保活磁贴',
      ),
      _FwOptionSpec('widget', Icons.widgets_outlined, '桌面小组件', '桌面小部件周期刷新拉起'),
      _FwOptionSpec(
        'deviceAdmin',
        Icons.admin_panel_settings_outlined,
        '设备管理员',
        '提升卸载/查杀门槛 (需激活设备管理员, 慎开)',
      ),
      _FwOptionSpec(
        'vpnService',
        Icons.vpn_lock_outlined,
        'VPN 保活',
        '系统级 VPN 服务保活 (需 VPN 授权)',
      ),
      _FwOptionSpec(
        'companionDevice',
        Icons.watch_outlined,
        '伴侣设备',
        '关联伴侣设备保活 (需系统授权)',
      ),
    ],
  ),
  (
    title: '通知样式豁免',
    options: [
      _FwOptionSpec(
        'mediaSessionNotification',
        Icons.notifications_active_outlined,
        'MediaSession 通知豁免',
        '媒体样式前台通知, 可绕过通知权限限制',
      ),
      _FwOptionSpec(
        'callStyleNotification',
        Icons.call_outlined,
        'CallStyle 通知豁免',
        '通话样式前台通知, 优先级更高',
      ),
    ],
  ),
];

/// 首页，展示当前登录用户信息（用户详情/baseinfo/班级信息），对应 Python user_info 界面。
/// 进入主页时按设置开关静默执行自动签到，同账号同日仅触发一次。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:ewt_auto_client/core/layout/app_breakpoints.dart';
import 'package:ewt_auto_client/features/activity/presentation/providers/checkin_provider.dart';
import 'package:ewt_auto_client/features/auth/presentation/providers/auth_provider.dart';
import 'package:ewt_auto_client/features/settings/presentation/providers/settings_provider.dart';
import 'package:ewt_auto_client/shared/utils/app_feedback.dart';

import '../providers/user_profile_provider.dart';

/// 首页 - 用户信息
///
/// 对应 Python: gui/interfaces/user_info.py
class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  /// 本页面生命周期内已自动签到的 (账号+日期) 标记, 防止同日重复触发
  String? _autoCheckinKey;

  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      ref.read(userProfileProvider.notifier).loadProfile();
    });
  }

  /// 启动 / 登录进入主页面时自动签到 (需「自动签到」开关开启且已登录)
  ///
  /// 每次进入主页面 (启动 / 重新登录, 路由强制落在 /home) 评估一次;
  /// 同一账号同一天只自动执行一次。服务端单日幂等, 重复触发无副作用。
  /// 设置页手动开关仍由设置页自身执行 (开关即执行), 本方法只覆盖
  /// 「开关已开启状态下进入主页面」的场景, 静默执行不弹提示。
  void _maybeAutoCheckin(AuthState authState, AppSettingsState settings) {
    if (!settings.checkinRaceEnabled) return;
    if (authState is! AuthAuthenticated) return;
    final accountId = authState.session.userId;
    if (accountId.isEmpty) return;
    final now = DateTime.now();
    final key = '$accountId:${now.year}-${now.month}-${now.day}';
    if (_autoCheckinKey == key) return;
    _autoCheckinKey = key;
    Future.microtask(() {
      if (!mounted) return;
      ref.read(checkinRaceProvider.notifier).runRace();
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final authState = ref.watch(authProvider);
    final profileState = ref.watch(userProfileProvider);
    final settings = ref.watch(appSettingsProvider);

    final session = authState is AuthAuthenticated ? authState.session : null;

    // 已登录且开启自动签到 → 进入主页时执行一次 (静默)
    _maybeAutoCheckin(authState, settings);

    return Scaffold(
      appBar: AppBar(
        title: const Text('首页'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '刷新',
            onPressed: () async {
              final messenger = ScaffoldMessenger.of(context);
              await ref.read(userProfileProvider.notifier).loadProfile();
              if (!context.mounted) return;
              final st = ref.read(userProfileProvider);
              showAppSnackBar(
                messenger,
                st.error == null ? '刷新完成' : '刷新失败: ${st.error}',
                isError: st.error != null,
              );
            },
          ),
        ],
      ),
      // 宽屏 (平板/桌面) 双列平铺卡片, 充分利用横向空间; 窄屏保持单列。
      body: LayoutBuilder(
        builder: (context, constraints) {
          final isWide = context.isWide;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _buildHeaderCard(theme, session, profileState, settings),
              const SizedBox(height: 24),
              // 基本资料 + 学校班级 在宽屏下并排; 会员信息较短, 宽屏下与其中一张同排。
              isWide
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: _infoSection(
                            theme,
                            '基本资料',
                            _buildBasicInfoCard(theme, session, profileState, settings),
                          ),
                        ),
                        const SizedBox(width: 24),
                        Expanded(
                          child: _infoSection(
                            theme,
                            '学校与班级',
                            _buildSchoolClassCard(theme, session, profileState, settings),
                          ),
                        ),
                      ],
                    )
                  : Column(
                      children: [
                        _infoSection(
                          theme,
                          '基本资料',
                          _buildBasicInfoCard(theme, session, profileState, settings),
                        ),
                        const SizedBox(height: 24),
                        _infoSection(
                          theme,
                          '学校与班级',
                          _buildSchoolClassCard(theme, session, profileState, settings),
                        ),
                      ],
                    ),
              const SizedBox(height: 24),
              _infoSection(
                theme,
                '会员信息',
                _buildMemberCard(theme, profileState, settings),
              ),
            ],
          );
        },
      ),
    );
  }

  /// 区块标题 + 内容卡片。
  Widget _infoSection(ThemeData theme, String title, Widget card) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: theme.textTheme.titleMedium),
        const SizedBox(height: 12),
        card,
      ],
    );
  }

  // ─── 头部卡片 ───

  Widget _buildHeaderCard(
    ThemeData theme,
    dynamic session,
    UserProfileState profileState,
    AppSettingsState settings,
  ) {
    final base = profileState.baseInfo ?? {};
    final displayName = base['realName']?.toString() ??
        session?.displayName ??
        session?.account ??
        '用户';
    final memberType = base['memberTypeName']?.toString() ?? '普通用户';
    final province = base['memberProvinceName']?.toString() ?? '';
    final avatarUrl = base['photoUrl']?.toString() ?? session?.avatar ?? '';

    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 20),
        child: Column(
          children: [
            CircleAvatar(
              radius: 44,
              backgroundColor: theme.colorScheme.primaryContainer,
              backgroundImage:
                  avatarUrl.isNotEmpty ? NetworkImage(avatarUrl) : null,
              child: avatarUrl.isEmpty
                  ? Text(
                      displayName.isNotEmpty
                          ? displayName[0].toUpperCase()
                          : '?',
                      style: theme.textTheme.headlineMedium?.copyWith(
                        color: theme.colorScheme.onPrimaryContainer,
                        fontWeight: FontWeight.bold,
                      ),
                    )
                  : null,
            ),
            const SizedBox(height: 14),
            Text(
              settings.mask(displayName),
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                _badge(theme, memberType, theme.colorScheme.secondaryContainer,
                    theme.colorScheme.onSecondaryContainer),
                if (province.isNotEmpty)
                  _badge(theme, province, theme.colorScheme.tertiaryContainer,
                      theme.colorScheme.onTertiaryContainer),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _badge(ThemeData theme, String text, Color bg, Color fg) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Text(text, style: theme.textTheme.labelMedium?.copyWith(color: fg)),
    );
  }

  // ─── 基本资料 (baseinfo 全字段) ───

  Widget _buildBasicInfoCard(
    ThemeData theme,
    dynamic session,
    UserProfileState profileState,
    AppSettingsState settings,
  ) {
    final base = profileState.baseInfo ?? {};
    final user = profileState.userData ?? {};
    final token = session?.token ?? '';
    final truncatedToken =
        token.length > 24 ? '${token.substring(0, 24)}...' : token;

    final rows = <(String, String)>[
      ('用户ID', settings.mask(base['userId']?.toString() ?? session?.userId)),
      ('用户名', settings.mask(user['userName']?.toString())),
      ('姓名', settings.mask(base['realName']?.toString())),
      ('昵称', _emptyDash(base['nickName']?.toString())),
      ('性别', _sexText(base['sex'])),
      ('地区编码', settings.mask(base['areaCode']?.toString())),
      ('所在地区', settings.mask(base['areaName']?.toString())),
      ('邮箱', _emptyDash(base['email']?.toString())),
      ('QQ', _emptyDash(base['qq']?.toString())),
      ('来源', base['source']?.toString() ?? '-'),
      ('是否教师', base['isTeacher'] == true ? '是' : '否'),
      ('角色ID', base['roleId']?.toString() ?? '-'),
      ('Token', settings.mask(truncatedToken)),
    ];

    return _infoCard(theme, rows);
  }

  // ─── 学校与班级 ───

  Widget _buildSchoolClassCard(
    ThemeData theme,
    dynamic session,
    UserProfileState profileState,
    AppSettingsState settings,
  ) {
    final base = profileState.baseInfo ?? {};
    final cls = profileState.classInfo ?? {};
    final adminClass = cls['joinedAdminClassInfo'] as Map<String, dynamic>? ?? {};
    final teachingList =
        (cls['joinedTeachingClassList'] as List<dynamic>?) ?? [];

    final rows = <(String, String)>[
      ('学校', settings.mask(base['schoolName']?.toString() ?? session?.schoolName)),
      ('学校ID', settings.mask(base['schoolId']?.toString() ?? session?.schoolId)),
      ('年级', _gradeText(base['grade']?.toString())),
      ('毕业年份', base['graduationYear']?.toString() ?? '-'),
      ('── 行政班 ──', ''),
      ('班级名称', settings.mask(adminClass['className']?.toString())),
      ('班级ID', settings.mask(adminClass['classId']?.toString())),
      ('班号', adminClass['classNo']?.toString() ?? '-'),
      ('学生人数', adminClass['numberOfStudent']?.toString() ?? '-'),
      ('毕业年份', adminClass['graduationYear']?.toString() ?? '-'),
      ('是否解散', adminClass['disbanded'] == true ? '是' : '否'),
      ('必学科目', adminClass['mustLearning']?.toString() ?? '-'),
      ('可改姓名', cls['canChangeName'] == true ? '是' : '否'),
      ('可改班级', cls['canChangeClass'] == true ? '是' : '否'),
    ];

    // 教学班列表
    for (int i = 0; i < teachingList.length; i++) {
      final tc = teachingList[i] as Map<String, dynamic>? ?? {};
      rows.add(('── 教学班 ${i + 1} ──', ''));
      rows.add(('班级名称', settings.mask(tc['className']?.toString())));
      rows.add(('班级ID', settings.mask(tc['classId']?.toString())));
      rows.add(('科目ID', tc['subjectId']?.toString() ?? '-'));
      rows.add(('学生人数', tc['numberOfStudent']?.toString() ?? '-'));
      rows.add(('是否解散', tc['disbanded'] == true ? '是' : '否'));
    }

    return _infoCard(theme, rows);
  }

  // ─── 会员信息 ───

  Widget _buildMemberCard(
    ThemeData theme,
    UserProfileState profileState,
    AppSettingsState settings,
  ) {
    final base = profileState.baseInfo ?? {};

    final rows = <(String, String)>[
      ('会员类型', base['memberTypeName']?.toString() ?? '-'),
      ('会员类型码', base['memberType']?.toString() ?? '-'),
      ('会员省份', base['memberProvinceName']?.toString() ?? '-'),
      ('省份编码', settings.mask(base['memberProvinceCode']?.toString())),
      ('到期年份', base['expireYear']?.toString() ?? '-'),
      ('是否过期', base['isExpire'] == true ? '已过期' : '有效'),
      ('是否试用', base['isOnTrial'] == true ? '是' : '否'),
      ('试用到期', _formatTrialExpire(base['trialExpireTime'])),
      ('文理类型', base['departmentalType']?.toString() ?? '-'),
      ('接入类型', base['accessType']?.toString() ?? '-'),
    ];

    return _infoCard(theme, rows);
  }

  // ─── 通用信息卡片 ───

  Widget _infoCard(ThemeData theme, List<(String, String)> rows) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Column(
          children: [
            for (int i = 0; i < rows.length; i++) ...[
              if (i > 0) const Divider(height: 1, indent: 16, endIndent: 16),
              if (rows[i].$1.startsWith('──'))
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
                  child: Text(
                    rows[i].$1.replaceAll('──', '').trim(),
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                )
              else
                ListTile(
                  dense: true,
                  title: Text(
                    rows[i].$1,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  subtitle: Text(
                    rows[i].$2.isEmpty ? '-' : rows[i].$2,
                    style: theme.textTheme.bodyMedium,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  // ─── Helpers ───

  String _sexText(dynamic sex) {
    return switch (sex?.toString()) {
      '1' => '男',
      '2' => '女',
      _ => '未知',
    };
  }

  String _gradeText(String? grade) {
    if (grade == null || grade.isEmpty) return '-';
    return switch (grade) {
      '1' => '高一',
      '2' => '高二',
      '3' => '高三',
      _ => grade,
    };
  }

  String _emptyDash(String? v) {
    if (v == null || v.isEmpty || v == 'null') return '-';
    return v;
  }

  /// 格式化试用到期时间戳 (13 位毫秒时间戳 → "YYYY-MM-DD HH:mm:ss")
  ///
  /// 对齐 Python: baseInfo['trialExpireTime'] 后端返回 13 位毫秒时间戳,
  /// 直接 toString() 会显示原始数字, 需转换为可读时间。
  String _formatTrialExpire(dynamic value) {
    int ms;
    if (value is int) {
      ms = value;
    } else if (value is String) {
      ms = int.tryParse(value) ?? 0;
    } else if (value is double) {
      ms = value.toInt();
    } else {
      return '-';
    }
    if (ms <= 0) return '-';
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    final y = dt.year.toString();
    final mo = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    final h = dt.hour.toString().padLeft(2, '0');
    final mi = dt.minute.toString().padLeft(2, '0');
    final s = dt.second.toString().padLeft(2, '0');
    return '$y-$mo-$d $h:$mi:$s';
  }
}

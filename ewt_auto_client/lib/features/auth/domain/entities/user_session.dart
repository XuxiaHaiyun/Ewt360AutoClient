/// 用户会话实体
///
/// 对应 Python: core/data_classes.py LoginResult + 登录后的用户上下文
class UserSession {
  final String token;
  final String userId;
  final String schoolId;
  final String? account;
  final String? displayName;
  final String? avatar;
  final String? schoolName;
  final String? provinceCode;
  final String? mobile;

  /// 本账号绑定的 HTTP 代理 (`host:port`), null 表示直连
  ///
  /// 由"批量运行任务 → 代理设置"中手动配置或从 TXT 导入自动分配,
  /// 持久化到 accounts.json, 批量任务执行时按账号走独立代理。
  final String? proxy;

  /// 登录方式 ('password' / 'sms' / 'qrcode'), null 表示未记录
  ///
  /// 凭证登录 (密码/短信/扫码) 成功时记录, Token 会话刷新不覆盖
  /// (保留首次登录方式)。用于账号详情展示与重新登录流程判断。
  final String? loginMethod;

  /// 记住的登录密码 (仅密码登录时记录), null 表示未记录
  ///
  /// 用于账号详情"重新登录": 自动填充密码, 仅需用户确认。
  final String? password;

  const UserSession({
    required this.token,
    required this.userId,
    required this.schoolId,
    this.account,
    this.displayName,
    this.avatar,
    this.schoolName,
    this.provinceCode,
    this.mobile,
    this.proxy,
    this.loginMethod,
    this.password,
  });

  UserSession copyWith({
    String? token,
    String? userId,
    String? schoolId,
    String? account,
    String? displayName,
    String? avatar,
    String? schoolName,
    String? provinceCode,
    String? mobile,
    String? proxy,
    String? loginMethod,
    String? password,
  }) {
    return UserSession(
      token: token ?? this.token,
      userId: userId ?? this.userId,
      schoolId: schoolId ?? this.schoolId,
      account: account ?? this.account,
      displayName: displayName ?? this.displayName,
      avatar: avatar ?? this.avatar,
      schoolName: schoolName ?? this.schoolName,
      provinceCode: provinceCode ?? this.provinceCode,
      mobile: mobile ?? this.mobile,
      proxy: proxy ?? this.proxy,
      loginMethod: loginMethod ?? this.loginMethod,
      password: password ?? this.password,
    );
  }

  /// 是否同一账号（已保存账号去重依据）
  ///
  /// 双方 userId 均非空时按 userId 判定（所有登录路径都会填充，Token 格式
  /// `userId-platform-token` 天然携带）；否则回退按 account（登录名）判定。
  /// 二者均无法判定时不视为同一账号。
  bool isSameAccount(UserSession other) {
    if (userId.isNotEmpty && other.userId.isNotEmpty) {
      return userId == other.userId;
    }
    final a = (account ?? '').trim();
    final b = (other.account ?? '').trim();
    return a.isNotEmpty && a == b;
  }

  /// 合并同一账号的新旧会话
  ///
  /// 以较新的 [newer] 为主（token/资料字段以新值为准），旧会话 [older]
  /// 补充新会话缺失的字段：登录方式、记住的密码、代理等本地配置在换
  /// token 重新登录后得以保留。
  static UserSession merge(UserSession newer, UserSession older) {
    String? pick(String? n, String? o) {
      if (n != null && n.isNotEmpty) return n;
      return (o != null && o.isNotEmpty) ? o : null;
    }

    return UserSession(
      token: newer.token,
      userId: pick(newer.userId, older.userId) ?? '',
      schoolId: pick(newer.schoolId, older.schoolId) ?? '',
      account: pick(newer.account, older.account),
      displayName: pick(newer.displayName, older.displayName),
      avatar: pick(newer.avatar, older.avatar),
      schoolName: pick(newer.schoolName, older.schoolName),
      provinceCode: pick(newer.provinceCode, older.provinceCode),
      mobile: pick(newer.mobile, older.mobile),
      proxy: pick(newer.proxy, older.proxy),
      loginMethod: pick(newer.loginMethod, older.loginMethod),
      password: pick(newer.password, older.password),
    );
  }

  /// 返回设置代理后的副本 (null/空串 = 清除代理恢复直连)
  ///
  /// 与 [copyWith] 的区别: copyWith 传 null 保留原值, 无法清除可空字段;
  /// 代理的设置与清除统一走此方法 (自动 trim, 空值归一为 null)。
  UserSession withProxy(String? proxy) {
    final clean = (proxy == null || proxy.trim().isEmpty) ? null : proxy.trim();
    return UserSession(
      token: token,
      userId: userId,
      schoolId: schoolId,
      account: account,
      displayName: displayName,
      avatar: avatar,
      schoolName: schoolName,
      provinceCode: provinceCode,
      mobile: mobile,
      proxy: clean,
      loginMethod: loginMethod,
      password: password,
    );
  }

  /// 序列化为 JSON（用于持久化到 accounts.json）
  Map<String, dynamic> toJson() => {
        'token': token,
        'userId': userId,
        'schoolId': schoolId,
        'account': account,
        'displayName': displayName,
        'avatar': avatar,
        'schoolName': schoolName,
        'provinceCode': provinceCode,
        'mobile': mobile,
        'proxy': proxy,
        'loginMethod': loginMethod,
        'password': password,
      };

  /// 从 JSON 构建会话
  ///
  /// 注意: 服务端/accounts.json 中 userId/schoolId 等可能为数值类型
  /// (如 123456), 统一经 `?.toString()` 安全转换, 避免 `as String?`
  /// 强转抛 `type 'int' is not a subtype of type 'String?'`。
  factory UserSession.fromJson(Map<String, dynamic> json) => UserSession(
        token: json['token']?.toString() ?? '',
        userId: json['userId']?.toString() ?? '',
        schoolId: json['schoolId']?.toString() ?? '',
        account: json['account']?.toString(),
        displayName: json['displayName']?.toString(),
        avatar: json['avatar']?.toString(),
        schoolName: json['schoolName']?.toString(),
        provinceCode: json['provinceCode']?.toString(),
        mobile: json['mobile']?.toString(),
        proxy: json['proxy']?.toString(),
        loginMethod: json['loginMethod']?.toString(),
        password: json['password']?.toString(),
      );
}

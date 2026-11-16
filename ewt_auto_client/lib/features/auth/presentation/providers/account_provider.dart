/// 账号列表状态管理与 Riverpod Provider，负责已保存账号的加载、去重、选中与批量有效性校验。
/// 账号以 userId/account 为唯一标识 upsert，加载时对历史数据按 token 去重迁移。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:ewt_auto_client/core/di/injection.dart';
import 'package:ewt_auto_client/core/network/dio_client.dart';
import 'package:ewt_auto_client/features/auth/data/datasources/account_storage.dart';
import 'package:ewt_auto_client/features/auth/domain/entities/user_session.dart';

/// Token 有效性状态
enum TokenValidity { unknown, checking, valid, invalid }

/// 账号列表状态
class AccountListState {
  final List<UserSession> accounts;
  final Set<String> selectedTokens;
  final bool isLoading;
  final Map<String, TokenValidity> tokenValidity;

  const AccountListState({
    this.accounts = const [],
    this.selectedTokens = const {},
    this.isLoading = false,
    this.tokenValidity = const {},
  });

  AccountListState copyWith({
    List<UserSession>? accounts,
    Set<String>? selectedTokens,
    bool? isLoading,
    Map<String, TokenValidity>? tokenValidity,
  }) {
    return AccountListState(
      accounts: accounts ?? this.accounts,
      selectedTokens: selectedTokens ?? this.selectedTokens,
      isLoading: isLoading ?? this.isLoading,
      tokenValidity: tokenValidity ?? this.tokenValidity,
    );
  }

  bool get hasSelection => selectedTokens.isNotEmpty;
  bool get allSelected =>
      accounts.isNotEmpty && selectedTokens.length == accounts.length;

  TokenValidity validityOf(String token) =>
      tokenValidity[token] ?? TokenValidity.unknown;
}

/// 账号列表管理器
class AccountNotifier extends StateNotifier<AccountListState> {
  AccountNotifier() : super(const AccountListState()) {
    _load();
  }

  Future<void> _load() async {
    state = state.copyWith(isLoading: true);
    final accounts = await AccountStorage.loadAccounts();
    // 历史数据迁移: 旧版本按 token 存储可能残留同账号多条记录,
    // 加载时合并去重, 有变化则回写存储
    final deduped = AccountStorage.dedupeAccounts(accounts);
    if (deduped.length != accounts.length) {
      await AccountStorage.saveAccounts(deduped);
    }
    state = state.copyWith(accounts: deduped, isLoading: false);
  }

  /// 登录成功后保存账号
  ///
  /// 以账号为唯一标识去重（userId / account 命中即视为同一账号），不论
  /// 登录方式：同账号旧条目被新会话原地替换（新 token 生效，旧 token 通常
  /// 已失效），并从旧条目合并保留登录方式 / 记住的密码 / 代理等本地配置。
  Future<void> addAccount(UserSession session) async {
    final updated = await AccountStorage.upsertAccount(session);
    state = state.copyWith(accounts: updated);
  }

  /// 切换选中状态
  void toggleSelection(String token) {
    final selected = Set<String>.from(state.selectedTokens);
    if (selected.contains(token)) {
      selected.remove(token);
    } else {
      selected.add(token);
    }
    state = state.copyWith(selectedTokens: selected);
  }

  /// 全选/取消全选
  void toggleSelectAll() {
    if (state.allSelected) {
      state = state.copyWith(selectedTokens: {});
    } else {
      state = state.copyWith(
        selectedTokens: state.accounts.map((a) => a.token).toSet(),
      );
    }
  }

  /// 清除选择
  void clearSelection() {
    state = state.copyWith(selectedTokens: {});
  }

  /// 批量删除选中账号
  Future<void> removeSelected() async {
    final accounts = await AccountStorage.removeAccounts(
      state.selectedTokens.toList(),
    );
    state = state.copyWith(accounts: accounts, selectedTokens: {});
  }

  /// 删除单个账号
  Future<void> removeAccount(String token) async {
    final accounts = await AccountStorage.removeAccounts([token]);
    final selected = Set<String>.from(state.selectedTokens)..remove(token);
    state = state.copyWith(accounts: accounts, selectedTokens: selected);
  }

  /// 更新指定账号的代理设置并持久化 (登录页批量任务代理设置写入)
  ///
  /// [proxy] 为 `host:port` 格式, null/空串表示清除代理 (直连)。
  /// 以存储为准按 token 匹配 (状态未加载/过期也能正确写入);
  /// 账号不存在时返回当前状态列表, 代理无变化时不落盘。
  Future<List<UserSession>> updateAccountProxy(String token, String? proxy) async {
    final accounts = await AccountStorage.loadAccounts();
    final idx = accounts.indexWhere((a) => a.token == token);
    if (idx < 0) return state.accounts;

    final clean = (proxy == null || proxy.trim().isEmpty) ? null : proxy.trim();
    if (accounts[idx].proxy == clean) return accounts;

    final newAccounts =
        List.of(accounts)..[idx] = accounts[idx].withProxy(clean);
    await AccountStorage.saveAccounts(newAccounts);
    state = state.copyWith(accounts: newAccounts);
    return newAccounts;
  }

  /// 重新从存储加载账号列表 (外部直接改写存储后同步状态)
  Future<void> reload() => _load();

  /// 验证账号 token 有效性
  ///
  /// [tokens] 为空时验证所有账号，否则验证指定 token
  Future<void> validateTokens({List<String>? tokens}) async {
    final targets = tokens ?? state.accounts.map((a) => a.token).toList();
    final client = getIt<DioClient>();

    // 标记为 checking
    final validity = Map<String, TokenValidity>.from(state.tokenValidity);
    for (final t in targets) {
      validity[t] = TokenValidity.checking;
    }
    state = state.copyWith(tokenValidity: validity);

    // 逐个验证
    for (final token in targets) {
      try {
        client.token = token;
        final response = await client.get('/api/usercenter/user/login/getUser');
        validity[token] =
            response.isSuccess ? TokenValidity.valid : TokenValidity.invalid;
      } catch (_) {
        validity[token] = TokenValidity.invalid;
      }
      state = state.copyWith(tokenValidity: Map.from(validity));
    }
  }
}

final accountProvider =
    StateNotifierProvider<AccountNotifier, AccountListState>((ref) {
  return AccountNotifier();
});

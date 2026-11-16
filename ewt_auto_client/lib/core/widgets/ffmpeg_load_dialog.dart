/// ffmpeg.wasm 核心下载进度弹窗 (Web 专用): 展示下载进度/字节数,
/// 支持 CDN 切换 (持久化)、取消与失败重试; ensureLoaded 供服务层无 context 调用。
library;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../router/app_router.dart';
import '../services/ffmpeg_load_progress.dart';
import '../services/ffmpeg_service.dart';

/// ffmpeg.wasm 核心组件下载进度弹窗 (Web 专用)
///
/// 首次使用 ffmpeg.wasm (视频下载 HLS remux) 时从 CDN 拉取 ~25MB core,
/// 本弹窗提供:
/// - 下载进度条与字节数反馈
/// - 手动切换下载 CDN (npmmirror/jsdelivr/unpkg, 选择持久化)
/// - 取消下载 (中止 fetch) / 失败后换 CDN 重试
class FfmpegLoadDialog {
  FfmpegLoadDialog._();

  /// 确保 ffmpeg 已初始化; 未初始化时弹出进度弹窗
  ///
  /// [context] 可为 null (服务层调用), 此时回退全局根 Navigator;
  /// 两者都不可用时静默加载 (无 UI)。
  /// 返回 true = 已加载; false = 用户取消或放弃。
  static Future<bool> ensureLoaded([BuildContext? context]) async {
    if (FfmpegService.instance.isInitialized) return true;

    final ctx = (context != null && context.mounted)
        ? context
        : rootNavigatorKey.currentContext;
    if (ctx == null || !ctx.mounted) {
      // 无 UI 可挂载: 静默加载 (使用持久化的 CDN 选择)
      try {
        final cdn = await _loadSavedCdn();
        await FfmpegService.instance.ensureInitialized(cdnBase: cdn);
        return true;
      } catch (_) {
        return false;
      }
    }

    final result = await showDialog<bool>(
      context: ctx,
      barrierDismissible: false,
      builder: (_) => const _FfmpegLoadDialog(),
    );
    return result ?? false;
  }

  static Future<String> _loadSavedCdn() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(kFfmpegCdnPrefKey) ?? kFfmpegCdnDefault;
    } catch (_) {
      return kFfmpegCdnDefault;
    }
  }

  static Future<void> saveCdn(String base) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(kFfmpegCdnPrefKey, base);
    } catch (_) {}
  }
}

class _FfmpegLoadDialog extends StatefulWidget {
  const _FfmpegLoadDialog();

  @override
  State<_FfmpegLoadDialog> createState() => _FfmpegLoadDialogState();
}

class _FfmpegLoadDialogState extends State<_FfmpegLoadDialog> {
  // 先用默认 CDN 渲染, 持久化选择异步读回
  String _cdn = kFfmpegCdnDefault;
  FfmpegLoadProgress? _progress;
  String? _error;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _initCdnAndStart();
  }

  Future<void> _initCdnAndStart() async {
    final saved = await FfmpegLoadDialog._loadSavedCdn();
    if (mounted && saved != _cdn) setState(() => _cdn = saved);
    await _startLoad();
  }

  Future<void> _startLoad() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
      _progress = null;
    });
    try {
      await FfmpegService.instance.ensureInitialized(
        cdnBase: _cdn,
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
      );
      if (!mounted) return;
      await FfmpegLoadDialog.saveCdn(_cdn);
      _loading = false;
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      final msg = e.toString();
      if (msg.contains('已取消')) {
        // 用户取消: 关闭并反馈取消
        Navigator.of(context).pop(false);
        return;
      }
      setState(() {
        _loading = false;
        _error = msg;
      });
    }
  }

  String _fmtMB(int bytes) => (bytes / 1024 / 1024).toStringAsFixed(1);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = _progress;
    final phaseText = switch (p?.phase) {
      'wasm' => '下载 ffmpeg wasm 核心',
      'script' => '加载 ffmpeg core 脚本',
      _ => '准备下载...',
    };

    return AlertDialog(
      title: const Text('加载 ffmpeg 组件'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_error != null) ...[
            Row(
              children: [
                Icon(Icons.error_outline,
                    color: theme.colorScheme.error, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '加载失败, 可切换 CDN 后重试',
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              _error!,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
          ] else ...[
            Text(phaseText, style: theme.textTheme.bodyMedium),
            const SizedBox(height: 10),
            LinearProgressIndicator(value: p?.ratio),
            const SizedBox(height: 8),
            Text(
              p == null
                  ? '首次使用需从 CDN 下载 ~25MB 核心组件'
                  : p.totalBytes > 0
                      ? '${_fmtMB(p.receivedBytes)} MB / ${_fmtMB(p.totalBytes)} MB'
                          ' (${(p.ratio * 100).toStringAsFixed(0)}%)'
                      : '已下载 ${_fmtMB(p.receivedBytes)} MB',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
          ],
          // CDN 选择
          Row(
            children: [
              Text('下载 CDN', style: theme.textTheme.bodySmall),
              const SizedBox(width: 12),
              Expanded(
                child: DropdownButtonFormField<String>(
                  initialValue: _cdn,
                  isDense: true,
                  decoration: const InputDecoration(
                    isDense: true,
                    border: OutlineInputBorder(),
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  ),
                  items: kFfmpegCdnPresets
                      .map((preset) => DropdownMenuItem<String>(
                            value: preset.$2,
                            child: Text(preset.$1,
                                style: theme.textTheme.bodySmall),
                          ))
                      .toList(),
                  onChanged: _loading
                      ? null
                      : (v) {
                          if (v != null) setState(() => _cdn = v);
                        },
                ),
              ),
            ],
          ),
        ],
      ),
      actions: [
        TextButton(
          // 取消: 中止下载, 弹窗以"取消"关闭 (下载任务随之取消)
          onPressed: _loading
              ? () {
                  FfmpegService.instance.abortLoad();
                  // abort 后 load future 会以"已取消"失败,
                  // 由 _startLoad 的 catch 分支 pop(false)
                }
              : _error != null
                  ? () => Navigator.of(context).pop(false)
                  : null,
          child: const Text('取消'),
        ),
        if (_error != null)
          FilledButton.icon(
            onPressed: _loading ? null : _startLoad,
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('重试'),
          )
        else
          FilledButton(
            onPressed: _loading ? null : _startLoad,
            child: const Text('开始'),
          ),
      ],
    );
  }
}

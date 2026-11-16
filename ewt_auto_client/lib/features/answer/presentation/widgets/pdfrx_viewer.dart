/// 内嵌 PDF 预览组件（基于 pdfrx），支持页码导航、缩放、加载/错误态与重试。
/// 关键约束：完全内嵌渲染，禁止唤起外部 PDF 阅读器或浏览器。
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

/// 内嵌 PDF 预览组件 (基于 pdfrx)
///
/// 关键约束: 完全内嵌渲染, **禁止** 唤起外部 PDF 阅读器或浏览器下载�?///
/// 能力:
/// - 页码导航 (上一�?下一�?
/// - 缩放 (放大/缩小)
/// - 加载�?(CircularProgressIndicator)
/// - 错误�?(损坏/网络失败�?: 提示 + 重新加载, 不跳转外�?///
/// PDF viewer widget.
class PdfrxViewer extends StatefulWidget {
  final Uint8List bytes;
  final String sourceName;

  /// 是否显示底部控制�?(页码/缩放)
  final bool showControls;

  const PdfrxViewer({
    super.key,
    required this.bytes,
    this.sourceName = 'document.pdf',
    this.showControls = true,
  });

  @override
  State<PdfrxViewer> createState() => _PdfrxViewerState();
}

class _PdfrxViewerState extends State<PdfrxViewer> {
  late PdfViewerController _controller;
  bool _ready = false;
  int _pageCount = 0;
  int _currentPage = 1;

  /// 重新加载令牌: 变更即重�?PdfViewer, 触发重新解析 (用于错误重试)
  int _reloadToken = 0;

  @override
  void initState() {
    super.initState();
    _controller = PdfViewerController();
  }

  @override
  void dispose() {
    super.dispose();
  }

  void _onViewerReady(PdfDocument doc, PdfViewerController ctrl) {
    if (!mounted) return;
    setState(() {
      _ready = true;
      _pageCount = ctrl.pageCount;
      _currentPage = 1;
    });
  }

  void _retry() {
    if (!mounted) return;
    // rebuild viewer
    _controller = PdfViewerController();
    setState(() {
      _ready = false;
      _pageCount = 0;
      _currentPage = 1;
      _reloadToken++;
    });
  }

  Widget _buildViewer() {
    return PdfViewer.data(
      widget.bytes,
      key: ValueKey(_reloadToken),
      sourceName: widget.sourceName,
      controller: _controller,
      params: PdfViewerParams(
        backgroundColor:
            Theme.of(context).colorScheme.surfaceContainerHighest,
        // 加载�?(bytes 已在内存, 一般瞬�? 仍保留占�?
        loadingBannerBuilder: (ctx, bytesDownloaded, totalBytes) =>
            const Center(child: CircularProgressIndicator()),
        // 错误�? 禁止外部打开, 仅提�?+ 重试
        errorBannerBuilder: (ctx, error, stackTrace, docRef) => Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.broken_image_outlined, size: 48),
                const SizedBox(height: 12),
                Text(
                  'PDF 加载失败: $error',
                  textAlign: TextAlign.center,
                  style: Theme.of(ctx).textTheme.bodyMedium,
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: _retry,
                  icon: const Icon(Icons.refresh),
                  label: const Text('重新加载'),
                ),
              ],
            ),
          ),
        ),
        onViewerReady: _onViewerReady,
        onPageChanged: (page) {
          if (mounted && page != null) setState(() => _currentPage = page);
        },
      ),
    );
  }

  Widget _buildControls() {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: theme.dividerColor)),
        color: theme.colorScheme.surface,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            icon: const Icon(Icons.zoom_out),
            tooltip: '缩小',
            onPressed: _ready ? () => _controller.zoomDown() : null,
          ),
          IconButton(
            icon: const Icon(Icons.zoom_in),
            tooltip: '放大',
            onPressed: _ready ? () => _controller.zoomUp() : null,
          ),
          const SizedBox(width: 8),
          IconButton(
            icon: const Icon(Icons.chevron_left),
              tooltip: 'Previous',
            onPressed: _ready && _currentPage > 1
                ? () => _controller.goToPage(pageNumber: _currentPage - 1)
                : null,
          ),
          Text(
              _pageCount > 0 ? '$_currentPage / $_pageCount' : 'Loading...',
            style: theme.textTheme.labelMedium,
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right),
              tooltip: 'Next',
            onPressed: _ready && _currentPage < _pageCount
                ? () => _controller.goToPage(pageNumber: _currentPage + 1)
                : null,
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final viewer = _buildViewer();
    if (!widget.showControls) return viewer;
    return Column(
      children: [
        Expanded(child: viewer),
        _buildControls(),
      ],
    );
  }
}




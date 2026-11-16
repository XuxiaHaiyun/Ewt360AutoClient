/// 批量任务相关弹窗的布局安全测试 (离线)
///
/// 背景: M3 AlertDialog 内容被 IntrinsicWidth 包裹, 内容中若存在
/// shrinkWrap 的 ListView/GridView 会在 performLayout 抛
/// "RenderShrinkWrappingViewport does not support returning intrinsic
/// dimensions", 导致弹窗从未完成布局 → 后续点击全部
/// "Cannot hit test a render box with no size" → 程序卡死。
///
/// 本测试用与真实弹窗一致的布局结构逐一打开弹窗并完成布局,
/// 确保不再出现该类异常。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _openDialog(WidgetTester tester, Widget dialog) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => Center(
          child: ElevatedButton(
            onPressed: () => showDialog(context: context, builder: (_) => dialog),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350)); // 弹窗入场动画
  await tester.pump();
}

void main() {
  testWidgets('批量任务选择弹窗内容可正常布局', (tester) async {
    await _openDialog(
      tester,
      AlertDialog(
        icon: const Icon(Icons.playlist_play),
        title: const Text('批量运行任务'),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('已选 3 个账号 · 选择要批量执行的任务'),
                const SizedBox(height: 12),
                for (var i = 0; i < 5; i++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Material(
                      color: Colors.grey.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(12),
                      child: ListTile(
                        title: Text('任务$i'),
                        subtitle: Text('描述$i'),
                      ),
                    ),
                  ),
                Container(
                  padding: const EdgeInsets.all(8),
                  child: Row(
                    children: [
                      const Text('未设置代理 (全部直连)'),
                      TextButton(onPressed: () {}, child: const Text('代理设置')),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () {}, child: const Text('取消')),
          FilledButton(onPressed: () {}, child: const Text('运行')),
        ],
      ),
    );
    expect(tester.takeException(), isNull, reason: '批量任务选择弹窗不应抛异常');
  });

  testWidgets('批量进度弹窗内容可正常布局 (Card+chips+SegmentedButton+列表)', (tester) async {
    await _openDialog(
      tester,
      AlertDialog(
        title: const Text('进度上报'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: SizedBox(
            width: 640,
            height: 500,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Card(
                  elevation: 0,
                  color: Colors.grey.withValues(alpha: 0.15),
                  child: const Padding(
                    padding: EdgeInsets.all(12),
                    child: Text('完成 1 · 失败 0 · 课程 5/10'),
                  ),
                ),
                const SizedBox(height: 10),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (var i = 0; i < 6; i++)
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: ChoiceChip(
                            avatar: const SizedBox(
                                width: 10,
                                height: 10,
                                child: DecoratedBox(
                                    decoration: BoxDecoration(
                                        color: Colors.green, shape: BoxShape.circle))),
                            label: Text('账号$i'),
                            selected: i == 0,
                            onSelected: (_) {},
                            showCheckmark: false,
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                Center(
                  child: SegmentedButton<int>(
                    segments: const [
                      ButtonSegment(value: 0, label: Text('进度')),
                      ButtonSegment(value: 1, label: Text('日志')),
                      ButtonSegment(value: 2, label: Text('详情')),
                    ],
                    selected: {0},
                    onSelectionChanged: (_) {},
                    showSelectedIcon: false,
                  ),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: ListView.builder(
                    itemCount: 10,
                    itemBuilder: (_, i) => Padding(
                      padding: const EdgeInsets.all(8),
                      child: Text('任务 $i'),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull, reason: '批量进度弹窗不应抛异常');
  });

  testWidgets('保活弹窗内容可正常布局 (统计条+账号列表+日志, 无 shrinkWrap)', (tester) async {
    await _openDialog(
      tester,
      AlertDialog(
        title: const Text('保持账号活跃 (3 个账号)'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: SizedBox(
            width: 520,
            height: 400,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.grey.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Text('第 1 轮 · 存活 2 · 失效 1'),
                ),
                const SizedBox(height: 8),
                Expanded(
                  flex: 3,
                  child: ListView(
                    children: [
                      for (var i = 0; i < 10; i++)
                        ListTile(dense: true, title: Text('账号$i')),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                Expanded(
                  flex: 2,
                  child: Container(
                    color: Colors.black.withValues(alpha: 0.6),
                    child: ListView.builder(
                      itemCount: 20,
                      itemBuilder: (_, i) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 1),
                        child: Text('log $i'),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          FilledButton(onPressed: () {}, child: const Text('停止')),
        ],
      ),
    );
    expect(tester.takeException(), isNull, reason: '保活弹窗不应抛异常');
  });

  testWidgets('代理设置弹窗内容可正常布局 (输入框列表)', (tester) async {
    await _openDialog(
      tester,
      AlertDialog(
        icon: const Icon(Icons.vpn_key_outlined),
        title: const Text('代理设置 (3 个账号)'),
        content: SizedBox(
          width: 560,
          height: 400,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  FilledButton.tonal(
                      onPressed: () {}, child: const Text('导入 TXT')),
                  OutlinedButton(onPressed: () {}, child: const Text('自动分配')),
                  TextButton(onPressed: () {}, child: const Text('清空全部')),
                ],
              ),
              const SizedBox(height: 4),
              Container(
                padding: const EdgeInsets.all(6),
                color: Colors.grey.withValues(alpha: 0.15),
                child: const Text('代理 5 个 ≥ 账号 3 个 → 每账号独立代理'),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: ListView.separated(
                  itemCount: 10,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (_, i) => Padding(
                    padding: const EdgeInsets.all(6),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 130,
                          child: Text('账号$i', overflow: TextOverflow.ellipsis),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: TextField(
                            decoration: const InputDecoration(
                              isDense: true,
                              hintText: 'ip:port (留空 = 直连)',
                            ),
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
          TextButton(onPressed: () {}, child: const Text('取消')),
          FilledButton(onPressed: () {}, child: const Text('应用')),
        ],
      ),
    );
    expect(tester.takeException(), isNull, reason: '代理设置弹窗不应抛异常');
  });

  testWidgets('shrinkWrap ListView 在 AlertDialog 内确实会抛异常 (回归对照)', (tester) async {
    await _openDialog(
      tester,
      AlertDialog(
        title: const Text('shrinkWrap 对照'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: SizedBox(
            width: double.infinity,
            height: 300,
            child: Column(
              children: [
                Expanded(
                  child: ListView(
                    shrinkWrap: true,
                    children: [for (var i = 0; i < 5; i++) Text('item $i')],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    // 该场景应抛 IntrinsicWidth 相关异常, 验证测试本身能捕获此类问题
    expect(tester.takeException(), isNotNull,
        reason: 'shrinkWrap 在弹窗内必须抛异常 (对照组)');
  });

  testWidgets('width:double.infinity + 普通 ListView 在弹窗内也会抛异常 (真实触发模式)', (tester) async {
    // 关键: 不是 shrinkWrap 的问题, 而是 width: double.infinity 让固有宽度
    // 查询穿透到任何 ListView (普通 viewport 同样不支持固有尺寸)
    await _openDialog(
      tester,
      AlertDialog(
        title: const Text('对照 2'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: SizedBox(
            width: double.infinity,
            height: 400,
            child: Column(
              children: [
                Expanded(
                  child: ListView.builder(
                    itemCount: 5,
                    itemBuilder: (_, i) => Text('item $i'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNotNull,
        reason: 'width:double.infinity + ListView 在弹窗内必须抛异常');
  });

  testWidgets('固定宽度 SizedBox + ListView 在弹窗内可正常布局 (修复方案)', (tester) async {
    await _openDialog(
      tester,
      AlertDialog(
        title: const Text('固定宽度对照'),
        content: SizedBox(
          width: 520,
          height: 400,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Padding(padding: EdgeInsets.all(8), child: Text('统计条')),
              const SizedBox(height: 8),
              Expanded(
                child: ListView.builder(
                  itemCount: 20,
                  itemBuilder: (_, i) =>
                      Padding(padding: const EdgeInsets.all(6), child: Text('任务 $i')),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull, reason: '固定宽度方案不应抛异常');
  });

  testWidgets('Dialog+ConstrainedBox(maxWidth+maxHeight)+Flexible(ListView) 安全 (存量 Dialog 结构)', (tester) async {
    // 实证: 仅 maxWidth 约束(不收紧)不会让固有宽度查询穿透到 ListView,
    // 存量 Dialog 结构 (answer_result/course_detail/weekend_task_detail) 安全
    await _openDialog(
      tester,
      Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 700, maxHeight: 640),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(padding: EdgeInsets.all(12), child: Text('标题')),
              const Divider(height: 1),
              Flexible(
                child: ListView.builder(
                  itemCount: 20,
                  itemBuilder: (_, i) => Text('条目 $i'),
                ),
              ),
              const Divider(height: 1),
              TextButton(onPressed: () {}, child: const Text('关闭')),
            ],
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull,
        reason: 'maxWidth 约束 + Flexible(ListView) 不应抛异常');
  });

  testWidgets('Dialog+固定宽度+ConstrainedBox(maxHeight)+Flexible(ListView) 可正常布局 (修复方案)', (tester) async {
    await _openDialog(
      tester,
      Dialog(
        child: SizedBox(
          width: 700,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 640),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Padding(padding: EdgeInsets.all(12), child: Text('标题')),
                const Divider(height: 1),
                Flexible(
                  child: ListView.builder(
                    itemCount: 20,
                    itemBuilder: (_, i) => Text('条目 $i'),
                  ),
                ),
                const Divider(height: 1),
                TextButton(onPressed: () {}, child: const Text('关闭')),
              ],
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull, reason: '固定宽度 Dialog 方案不应抛异常');
  });

  testWidgets('日期/学科多选弹窗结构 (CheckboxListTile+固定宽度 ListView) 可正常布局 (2026-08-24 修复)', (tester) async {
    // 镜像 homework_list_page _DateMultiSelectDialog/_SubjectMultiSelectDialog:
    // 修复前为 SizedBox(width:double.infinity)+ListView → 布局异常程序卡死,
    // 修复后固定宽度 360 + 固定高度 + ListView.builder
    await _openDialog(
      tester,
      AlertDialog(
        title: const Text('多选日期 (0/25)'),
        content: SizedBox(
          width: 360,
          height: 300,
          child: ListView.builder(
            itemCount: 25,
            itemBuilder: (_, i) => CheckboxListTile(
              title: Text('第${i + 1}天'),
              subtitle: Text('$i/$i 已完成'),
              value: false,
              onChanged: (_) {},
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () {}, child: const Text('全选')),
          TextButton(onPressed: () {}, child: const Text('反选')),
          TextButton(onPressed: () {}, child: const Text('清除')),
          TextButton(onPressed: () {}, child: const Text('取消')),
          FilledButton(onPressed: () {}, child: const Text('确认')),
        ],
      ),
    );
    expect(tester.takeException(), isNull, reason: '多选弹窗固定宽度方案不应抛异常');
  });
}

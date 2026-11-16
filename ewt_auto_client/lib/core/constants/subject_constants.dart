/// 学科常量: 学科 ID → 名称/颜色映射
///
/// 原分散在 homework_provider 与 progress_report_service 两份重复定义,
/// 统一收敛于此 (对齐 getStudentHomeworkDaySubjectStat 接口实际返回)。
library;

import 'package:flutter/material.dart';

/// 学科颜色映射 (subjectId -> Color, 对齐 getStudentHomeworkDaySubjectStat 接口)
const Map<int, Color> subjectColorMap = {
  1: Color(0xFFE53935), // 语文 - Red
  2: Color(0xFF1E88E5), // 数学 - Blue
  3: Color(0xFF43A047), // 英语 - Green
  4: Color(0xFF8E24AA), // 物理 - Purple
  5: Color(0xFFFF8F00), // 化学 - Amber
  6: Color(0xFF00ACC1), // 生物 - Cyan
  7: Color(0xFFD81B60), // 政治 - Pink
  8: Color(0xFF6D4C41), // 历史 - Brown
  9: Color(0xFF3949AB), // 地理 - Indigo
  10: Color(0xFF546E7A), // 心灵成长 - BlueGrey
  11: Color(0xFF7CB342), // 生涯规划 - LightGreen
  12: Color(0xFFF4511E), // 综合素养 - DeepOrange
  13: Color(0xFFF4511E), // 综合素养 - DeepOrange
  14: Color(0xFF26A69A), // 信息 - Teal
  15: Color(0xFFAB47BC), // 通用 - PurpleAccent
  16: Color(0xFF66BB6A), // 科学 - GreenAccent
};

/// 学科名称映射 (对齐 getStudentHomeworkDaySubjectStat 接口实际返回)
const Map<int, String> subjectNameMap = {
  1: '语文',
  2: '数学',
  3: '英语',
  4: '物理',
  5: '化学',
  6: '生物',
  7: '政治',
  8: '历史',
  9: '地理',
  10: '心灵成长',
  11: '生涯规划',
  12: '综合素养',
  13: '综合素养',
  14: '信息',
  15: '通用',
  16: '科学',
};

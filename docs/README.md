# 文档中心

EwtAutoClient 项目文档索引。逆向分析类文档均基于 ewt360.com 线上页面 / 站点 bundle 的实证分析（Edge DevTools 抓包 + 源码静态分析）。配套的可运行 Python 参考脚本统一放在 `debug/` 下（answer / player / reverse），本文档仅收录说明文档。

## 目录结构

```
docs/
├── answer/           # 答题模块：answer-pc 报告/分析页流程与 API
├── favorites/        # 收藏夹批量获取答案
├── player/           # 视频播放器（mstplayer）行为与认真度检测
├── reverse/          # 逆向分析结论：阿里云私有加密、短信登录
└── vulnerabilities.md # 平台弱点利用说明（项目所用全部漏洞的归纳）
```

## answer/ — 答题模块

answer-pc 报告页（`/answer-pc/exam/analysis`，bizCode=204）与作业报告页（`/answer-pc/report`，bizCode=205）的完整链路分析。

| 文档 | 内容 |
|---|---|
| [page_type_routing_doc.md](answer/page_type_routing_doc.md) | 页面类型判断与跳转流程（教师端任务概览 → 中间路由 → 落地页） |
| [params_source_doc.md](answer/params_source_doc.md) | 页面参数（homeworkId 等）的来源与获取方式 |
| [page_loading_flow_doc.md](answer/page_loading_flow_doc.md) | 页面详细加载流程（请求时序） |
| [answer_display_flow_doc.md](answer/answer_display_flow_doc.md) | 答案展示流程（5 个标签页渲染逻辑） |
| [answer_report_api_doc.md](answer/answer_report_api_doc.md) | 答题报告/分析页面 API 调用文档 |
| [focus_check_api_doc.md](answer/focus_check_api_doc.md) | 认真度检测（Focus Check）接口文档 |

> 配套脚本：`debug/answer/test_answer_report_api.py`、`debug/answer/focus_check_flow.py`

## favorites/ — 收藏夹获取答案

从 EWT360「错题/收藏夹」批量拉取题干 + 答案 + 解析的方案与 4 个接口（含签名规则）。

| 文档 | 内容 |
|---|---|
| [README.md](favorites/README.md) | 方案总览与快速开始 |
| [favorites_api_doc.md](favorites/favorites_api_doc.md) | API 文档（4 个接口 + 端到端时序） |

> 配套脚本：`debug/answer/favorites_answer.py`

## player/ — 视频播放与埋点

站点播放器 `mstplayer-v3.0.37.min.js` 的行为分析，是进度上报与认真度检测实现的依据。

| 文档 | 内容 |
|---|---|
| [mstplayer_behavior_doc.md](player/mstplayer_behavior_doc.md) | 看课埋点行为分析（基础） |
| [mstplayer_seriousness_check_doc.md](player/mstplayer_seriousness_check_doc.md) | 认真度检测详细分析 |

> 配套脚本：`debug/player/test_mstplayer_api.py`、`debug/player/test_mstplayer_seriousness.py`

## reverse/ — 逆向分析结论

| 文档 | 内容 |
|---|---|
| [aliyun_vod_encryption.md](reverse/aliyun_vod_encryption.md) | 阿里云私有加密（HLS `_vpk`）逆向结论，逐字节比对通过 |
| [sms_login.md](reverse/sms_login.md) | 短信验证码登录接口文档与 Python 参考实现（`debug/reverse/sms_login.py`） |

## 弱点利用说明

| 文档 | 内容 |
|---|---|
| [vulnerabilities.md](vulnerabilities.md) | **项目利用的全部平台弱点归纳** |

> 阿里云加密逆向的脚本与中间产物（bundle、测试向量、密钥样本等）位于 `debug/AliyunVoDEncryption/`。

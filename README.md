<div align="center">

<img src="ewt_auto_client/ewt_auto.png" alt="EwtAutoClient" width="120"/>

# EwtAutoClient

**EWT360（e学网 ewt360.com）自动化客户端 —— 基于 Flutter 的跨平台应用**

<div>
<img src="https://img.shields.io/badge/Flutter-3.x-02569B?logo=flutter" alt="Flutter"/>
<img src="https://img.shields.io/badge/Dart-%5E3.12.2-0175C2?logo=dart" alt="Dart"/>
<img src="https://img.shields.io/badge/Platform-Windows%20%2F%20Android-0078D6" alt="Platform"/>
<img src="https://img.shields.io/badge/License-Personal%20Learning%20Only-lightgrey" alt="License"/>
</div>

<br>

[文档中心](docs/README.md) ｜
[快速开始](#-快速开始) ｜
[项目结构](#-项目结构) ｜
[技术栈](#-技术栈) ｜
[开发约定](#-开发约定) ｜
[特别鸣谢](#-特别鸣谢) ｜
[许可](#-许可)

</div>

EwtAutoClient 是一个面向 EWT360（e学网）平台的跨平台自动化客户端，基于 Flutter 构建，覆盖登录鉴权、作业批量处理、视频播放与进度上报、认真度检测等完整链路，可正常用来看课。

> [!NOTE]
> 仅供个人学习与技术交流，请勿用于任何违反服务条款或法律法规的用途。

## ✨ 主要功能

1. 🔐 **鉴权**：账号登录、QR 码登录、弱密码处理、checkToken 改密、主动改密。
2. 📝 **作业**：批量任务拉取、试题渲染与作答辅助。
3. ▶️ **播放**：课程正常播放，支持腾讯云和阿里云路线。
4. 📊 **进度上报**：EventPackage 数据包上报 + 认真度自动绕过（正常/答题/滑块全过）。 （**仅支持正常上报，漏洞上报已被修复**)
5. 🧩 **验证码**：滑块验证码自动求解。
6. 🗂 **答案**：多种方案批量拉取题干、答案与解析。
7. 🛠 **下载**：下载课程 / 试题 / 导学案。

## 🚀 快速开始

> [!IMPORTANT]
> **环境要求**：Flutter SDK 3.x（Dart ^3.12.2）；Windows 端需 VS 桌面开发工作负载；Android 端需 Android Studio / SDK。

**本地运行（推荐调试方式）：**

```bash
cd ewt_auto_client
flutter pub get          # 安装依赖
flutter run -d windows   # Windows 桌面端运行
```

**构建发布：**

```bash
flutter build windows    # 构建 Windows 发布版
flutter build apk        # 构建 Android APK
```

## 📁 项目结构

```
EwtAutoClient/
├── ewt_auto_client/            # Flutter 主工程
│   ├── lib/
│   │   ├── core/               # 基础设施：network/ crypto/ captcha/ risk_control/ router/ theme/ ...
│   │   ├── features/           # 业务模块（按特性垂直切分）：auth/ homework/ player/ answer/ ...
│   │   └── shared/             # 跨特性共享 utils / widgets
│   ├── assets/                 # 字体 / 图片 / 配置
│   ├── risk_control/           # 风控加密配置
│   └── windows/ android/ web/  # 平台宿主工程
├── docs/                       # 📚 项目文档（API / 流程 / 逆向分析）
├── debug/                      # 逆向调试脚本与产物（JS / 字体 / 样本），与主工程无依赖
└── README.md
```

架构分层：**core 基础设施 → features 按特性垂直切分 → shared 共享层**，页面层统一使用 Riverpod Provider 管理状态。

## 🧱 技术栈

Flutter 3.x · Riverpod 2.x（代码生成）· dio 5.x · go_router · media_kit · freezed · get_it

<details>
<summary>关键依赖说明</summary>

| 用途 | 依赖 |
| :--- | :--- |
| 状态管理 | flutter_riverpod + riverpod_annotation（代码生成） |
| 网络 | dio 5.x 拦截器架构，加解密收敛于 `core/crypto` 与 `core/network` |
| 路由 | go_router |
| 加密 | encrypt / crypto（AES-256-CBC） |
| 视频 | media_kit + media_kit_video（阿里云私有加密链路） |
| 富文本 / 公式 | flutter_html + flutter_math_fork（题干与 LaTeX 渲染） |
| 数据模型 | freezed + json_serializable |

</details>

## 📚 文档

全部技术文档收录于 [docs/](docs/README.md)，按主题分为五类：

- **[answer/](docs/answer)** — answer-pc 报告 / 分析页：页面路由、参数来源、加载时序、答案展示、报告 API、认真度检测
- **[favorites/](docs/favorites)** — 收藏夹批量获取答案：4 个接口 + 签名规则 + 端到端时序
- **[player/](docs/player)** — mstplayer 播放器行为与认真度检测的逆向分析
- **[reverse/](docs/reverse)** — 阿里云私有加密逆向结论、短信登录接口与参考实现
- **[vulnerabilities.md](docs/vulnerabilities.md)** — 项目利用的平台弱点归纳

每篇文档均基于 ewt360.com 线上页面实证分析（抓包 + 站点 bundle 静态分析），配套可运行的 Python 参考脚本位于 `debug/` 对应目录（answer / player / reverse）。

## 📐 开发约定

- **状态管理**：新页面一律使用 Riverpod（推荐 riverpod_annotation 代码生成风格）。
- **网络请求**：统一走 dio 拦截器，加解密逻辑收敛于 `core/crypto` 与 `core/network`，禁止在页面层直接拼接口。
- **接口核对**：新增 / 修改接口前，须对照 ewt360.com 线上 SPA 源码或抓包结果验证。
- **UI 红线**：M3 Dialog 中禁止 `SizedBox(width: double.infinity)` 包裹 `ListView`（会触发 Cannot hit test 与界面冻结），应使用固定宽度（360 / 380）替代。

## 🙏 特别鸣谢

- **[GetEWTAnswers](https://github.com/zhicheng233/GetEWTAnswers)** - 提供一种答案获取思路
- **GLM-5.3-Flash / DeepSeek-V4 /Hy4 / Hy3** - 协助编写代码

## 📄 许可

仅限个人学习用途，未授予任何形式的商用许可。

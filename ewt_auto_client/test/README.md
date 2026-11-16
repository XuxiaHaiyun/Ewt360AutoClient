# 测试说明 (test/)

本项目测试分为三层, 全部在 `ewt_auto_client/` 目录下运行:

```bash
cd ewt_auto_client
flutter test                # 全部测试
flutter test test/unit      # 仅离线单元测试 (推荐, 无账号也能跑)
flutter test test/api       # 仅真实 API 集成测试 (需账号)
flutter test test/widget    # 仅 Widget 测试
flutter test test/unit/core/crypto_test.dart   # 单个文件
```

## 目录结构

```
test/
├── README.md                        # 本文件
├── accounts.json                    # 真实账号配置 (API 集成测试使用)
├── helpers/
│   ├── test_accounts.dart           # 账号加载器 + 统一 skip 机制 + 课程预取
│   └── fixtures.dart                # 测试数据工厂 (mock 课程/作业/视频)
├── unit/                            # ① 离线单元测试 (无网络/无账号)
│   ├── core/                        #    核心层: 加密/签名/配置/响应/拦截器/风控/验证码
│   ├── entities/                    #    领域实体: 序列化与纯逻辑
│   └── logic/                       #    业务纯函数: 过滤/视频解析
├── api/                             # ② 真实 API 集成测试 (需 accounts.json)
│   ├── auth_api_test.dart           #    认证
│   ├── homework_api_test.dart       #    作业
│   ├── answer_api_test.dart         #    答案
│   ├── player_api_test.dart         #    播放器
│   ├── weekend_api_test.dart        #    周培优
│   ├── answer_service_test.dart     #    AnswerService 端到端
│   ├── download_service_test.dart   #    DownloadService 端到端
│   └── progress_report_service_test.dart  # 进度上报端到端
└── widget/                          # ③ Widget 测试
    ├── app_smoke_test.dart          #    应用冒烟
    └── handwritten_page_test.dart   #    手写模拟渲染
```

## 三层测试说明

### ① unit/ — 离线单元测试 (推荐)

**不需要任何账号配置, 不发起网络请求**, 可随时运行:
`flutter test test/unit`

覆盖内容:
- **core/**: AES 密码加密 / MD5 / HMAC-SHA1 签名 (与 Python golden 向量交叉验证)、
  EndpointConfig、ApiResponse 与异常层次、Sign/Auth 拦截器 header 注入、
  风控配置与加解密、滑块验证码缺口定位 (合成图像)
- **entities/**: UserSession / QuestionInfo / 过滤配置 / 播放器实体 /
  手写配置 的 JSON 序列化与纯逻辑
- **logic/**: AnswerService.applyFilter、ProgressReportService.filterCourses、
  VideoSourceResolver 无网络路径

### ② api/ — 真实 API 集成测试 (需账号)

验证与 EWT360 真实网关的完整功能链路, **不做任何 mock**。
需要 `test/accounts.json` 配置有效账号:

```json
[
  {
    "token": "你的token",
    "userId": "你的userId",
    "schoolId": "你的schoolId",
    "displayName": "测试账号"
  }
]
```

- 仅提供 `token` 也可 (userId/schoolId 会通过 API 在线补全, 但多出 2 次请求)
- **未配置账号时, 集成测试自动跳过** (标记为 skipped, 不影响其他测试)
- 运行: `flutter test test/api`

注意: 集成测试包含**有副作用**的操作 (进度上报会真实上报),
请使用测试账号, 勿使用正式账号。

### ③ widget/ — Widget 测试

- `app_smoke_test.dart`: 应用入口冒烟, 离线可跑
- `handwritten_page_test.dart`: 手写模拟渲染, 会导出 PNG 到
  `ewt_auto_client/debug/text-to-handwriting/` 供人工检查

## 常用工作流

```bash
# 日常快速回归 (离线, 秒级)
flutter test test/unit test/widget

# 针对某功能模块的真实链路验证 (需账号)
flutter test test/api/answer_api_test.dart

# 全部测试 (单元 + 集成 + Widget)
flutter test

# 带输出查看 (打印接口返回的关键字段)
flutter test --reporter expanded test/api
```

## 新增测试的约定

1. **纯逻辑/序列化** → `test/unit/`, 不要依赖账号与网络
2. **真实 API 链路** → `test/api/`, 统一使用 `loadTestHarnessOrNull()`
   与 `noHarnessSkip(harness)`, 无账号自动 skip
3. **需要"首个作业的课程"** → 复用 `prefetchHomeworkAndCourses()`,
   不要重复手写作业→日期→课程链路
4. **mock 数据** → 优先用 `helpers/fixtures.dart` 的构造函数
5. **不要制造副作用**: 真实接口的提交/收藏/下载操作避免使用真实数据

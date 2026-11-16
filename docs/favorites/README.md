# 收藏夹获取答案 · 方案总览

把 EWT360「错题/收藏夹（wrongquestion label）」里收藏的题目，批量拉取**题干 + 答案 + 解析**。

## 文件清单

| 文件 | 内容 |
|---|---|
| `favorites_api_doc.md` | API 文档：URL / 请求头 / 请求体 / 响应体（4 个接口 + 端到端时序） |
| `debug/answer/favorites_answer.py` | 可运行 Python：签名 + 4 个接口封装 + 端到端 demo |

## 快速开始

```bash
cd debug/answer
pip install requests

# 编辑 favorites_answer.py 顶部常量：
#   TOKEN      = 浏览器 cookie 里的真实 token（形如 161000000-1-xxxxxxxx）
#   SUBJECT_ID = 学科 ID（0=全部）
python favorites_answer.py
```

脚本会先列出你的收藏夹，自动取第一个，翻页拉出全部题目 ID，再逐题拉取详情（答案）。
首次运行建议对照打印出的「原始响应」核对文档里标注「待 HAR 核对」的字段名。

## 四个接口

1. `GET /api/wrongquestion/label/list` — 收藏夹列表（`subjectId`, `questionId=0`）
2. `GET /api/answerprod/web/wrongquestion/label/getquestion` — 收藏夹内题目（多 URL 回退；`labelId`, `subjectId`, `offset`, `limit`）
3. `GET /api/answerprod/web/wrongquestion/collect/question/info` — 单题详情（题干+答案+解析）
4. `GET /api/answerprod/web/wrongquestion/collect/question/analysis` — 单题解析（可选）

## 关键注意

- **请求头用默认拦截器**（Origin/Referer = `www.ewt360.com`）。
- **必须带签名**：`sign = MD5(timestamp + "bdc739ff2dcf").upper()`，并传 `timestamp` / `secretId=2` / `platform=1` / `token`。
- 响应统一结构：`{ success, code, msg, data }`，以 `success == true` 判定成功。


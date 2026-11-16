# -*- coding: utf-8 -*-
"""
EWT 试卷答案获取与提交 - 可运行程序
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import test_answer_api as api


# ============================================================
# 配置区
# ============================================================
TOKEN = "161600000-1-xxxxxxxxxxxxxxxx"                  # 必填: 登录 token (mstid)
PAPER_ID = "1728299126295683249"               # 必填: 试卷 ID
TOTAL_SECONDS = 600         # 答题总用时 (秒)
REPORT_ID = "2327048199072112940"              # 真实答题报告 ID
BIZ_CODE = "204"                               # 真实业务码
HOMEWORK_ID = "10495544"                       # 作业 ID

# 固定图片路径 (默认同目录 onlyhead.png)
IMAGE_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "onlyhead.png")


def print_answer_preview(questions: list):
    """打印答案预览"""
    print("\n答案预览:")
    print("-" * 60)
    for i, q in enumerate(questions, 1):
        num = q.get("number") or str(i)
        answer = q.get("answer") or "(空)"
        qtype = q.get("questionType") or ""
        subjective = "主观" if q.get("subjective") else "客观"

        # 分组题: 展开子题
        if q.get("childQuestions"):
            print(f"  [{num}] {qtype} ({subjective}, {len(q['childQuestions'])} 子题):")
            for j, cq in enumerate(q["childQuestions"], 1):
                c_answer = cq.get("answer") or "(空)"
                c_subjective = "主观" if cq.get("subjective") else "客观"
                print(f"       ({j}) [{c_subjective}] {c_answer}")
        else:
            print(f"  [{num}] {qtype} ({subjective}): {answer}")
    print("-" * 60)


def main():
    # 必填校验
    if not TOKEN:
        print("错误: 请在配置区填入 TOKEN (登录 token)")
        sys.exit(1)
    if not PAPER_ID:
        print("错误: 请在配置区填入 PAPER_ID (试卷 ID)")
        sys.exit(1)

    # 真实作业模式判断: REPORT_ID 和 BIZ_CODE 同时填写即为真实作业模式
    # (HOMEWORK_ID 在真实作业模式必填; 纯越权模式下忽略, 自动用 '0')
    use_real_submit = bool(REPORT_ID.strip()) and bool(BIZ_CODE.strip())
    real_hw_id = HOMEWORK_ID.strip()
    if use_real_submit and not real_hw_id:
        print("错误: 真实作业模式下 HOMEWORK_ID 不能为空")
        sys.exit(1)
    if not use_real_submit and (REPORT_ID.strip() or BIZ_CODE.strip()):
        print("错误: REPORT_ID 和 BIZ_CODE 需同时填写 (或同时留空走纯越权模式)")
        sys.exit(1)

    # 越权获取答案时 homeworkId 写死为 '0' (绕过作业归属检查)
    via_homework_id = "0"

    api.TOKEN = TOKEN

    if not os.path.isfile(IMAGE_PATH):
        print(f"错误: 固定图片不存在: {IMAGE_PATH}")
        sys.exit(1)

    # 打印运行配置
    print("=" * 60)
    print("EWT 试卷答案获取与提交")
    print(f"  paperId    : {PAPER_ID}")
    print(f"  image      : {IMAGE_PATH}")
    if use_real_submit:
        print(f"  提交模式   : 真实作业 (bizCode={BIZ_CODE}, reportId={REPORT_ID}, homeworkId={HOMEWORK_ID})")
    else:
        print(f"  提交模式   : 纯越权 (独立报告, 学生看不到进度, homeworkId=0)")
    print("=" * 60)

    # ----------------------------------------------------------
    # 步骤 1: 获取试卷答案 (越权方案)
    # ----------------------------------------------------------
    print("\n[步骤 1] 获取试卷答案 (越权方案)...")

    course = {
        "title": f"试卷 {PAPER_ID}",
        "contentType": 2,           # 试卷课程
        "paperId": PAPER_ID,
        "reportId": "",
        "homeworkId": via_homework_id,
    }

    result = api.fetch_answers(
        course,
        homework_id=via_homework_id,
        school_id="",
    )

    if not result or not result.get("questions"):
        print("\n获取答案失败或无题目, 程序终止")
        sys.exit(1)

    questions = result["questions"]
    print(f"\n获取到 {len(questions)} 题答案 (越权 reportId={result.get('reportId')})")

    # 真实作业模式: 用真实参数覆盖越权方案的值, 提交到真实作业报告
    # 越权方案的 reportId 已被 submitPaper 标记"已提交", 不可用于真实作业提交
    if use_real_submit:
        result["reportId"] = REPORT_ID
        result["bizCode"] = BIZ_CODE
        result["homeworkId"] = HOMEWORK_ID
        print(f"  已覆盖为真实作业参数: bizCode={BIZ_CODE}, reportId={REPORT_ID}")

    # 打印答案预览
    print_answer_preview(questions)

    # ----------------------------------------------------------
    # 步骤 2: 提交答案并交卷 (主观题用固定图片)
    # ----------------------------------------------------------
    print(f"\n[步骤 2] 提交答案并交卷...")

    oss = api.OssUploadService(token=TOKEN)

    submit_result = api.submit_answers(
        result,
        total_seconds=TOTAL_SECONDS,
        oss=oss,
        fixed_image_path=IMAGE_PATH,
    )

    # ----------------------------------------------------------
    # 输出最终结果
    # ----------------------------------------------------------
    print("\n" + "=" * 60)
    if submit_result.get("success"):
        print(f"提交成功: {submit_result.get('message')}")
        print(f"已提交 {submit_result.get('submittedCount')} 题")
    else:
        print(f"提交失败: {submit_result.get('message')}")
    print("=" * 60)

    # 非 0 退出码便于脚本集成
    sys.exit(0 if submit_result.get("success") else 1)


if __name__ == "__main__":
    main()

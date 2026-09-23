from __future__ import annotations

import shutil
import tempfile
import unittest
from pathlib import Path

from eval import (
    DATA,
    build_haystack,
    check,
    execute_tool,
    grade_agent,
    parse_tool_calls,
    score_needle,
    visible_text,
)


class CheckTests(unittest.TestCase):
    def test_contains_and_think_stripped(self) -> None:
        spec = {"type": "contains_any", "values": ["信濃川"]}
        self.assertTrue(check("信濃川です。", spec))
        self.assertFalse(check("<think>信濃川</think>利根川", spec))

    def test_bullets(self) -> None:
        spec = {"type": "bullets", "count": 3, "prefix": "・", "forbid_suffix": "。"}
        self.assertTrue(check("・春は桜\n・夏は海\n・秋は紅葉", spec))
        self.assertFalse(check("・春は桜。\n・夏は海\n・秋は紅葉", spec))

    def test_json_with_fence(self) -> None:
        spec = {"type": "json_equals", "value": {"name": "佐藤花子", "age": 34}}
        self.assertTrue(check('```json\n{"name": "佐藤花子", "age": 34}\n```', spec))
        self.assertFalse(check('{"name": "佐藤花子", "age": "34"}', spec))

    def test_all_questions_have_valid_checks(self) -> None:
        import json

        for item in json.loads((DATA / "ja.json").read_text(encoding="utf-8")):
            check("", item["check"])


class NeedleTests(unittest.TestCase):
    def test_deterministic_and_contains_needles(self) -> None:
        a, answers = build_haystack(2000)
        b, _ = build_haystack(2000)
        self.assertEqual(a, b)
        for label, code in answers.items():
            self.assertEqual(a.count(f"{label}の合言葉は「{code}」"), 1)
        self.assertEqual(len(set(answers.values())), 3)

    def test_needle_depth_order(self) -> None:
        text, answers = build_haystack(2000)
        positions = [text.index(code) / len(text) for code in answers.values()]
        self.assertEqual(positions, sorted(positions))
        self.assertLess(positions[0], 0.2)
        self.assertGreater(positions[2], 0.8)

    def test_score(self) -> None:
        _, answers = build_haystack(100)
        output = '{"北門": "%s", "中庭": "x", "南塔": "%s"}' % (answers["北門"], answers["南塔"])
        self.assertEqual(sum(score_needle(output, answers).values()), 2)
        self.assertEqual(sum(score_needle("not json", answers).values()), 0)


class ToolTests(unittest.TestCase):
    def test_parse_tool_calls(self) -> None:
        text = (
            "確認します。\n<tool_call>\n<function=write_file>\n<parameter=path>\na.py\n</parameter>\n"
            "<parameter=content>\nx = 1\n\n</parameter>\n</function>\n</tool_call>"
        )
        calls = parse_tool_calls(text)
        self.assertEqual(calls, [{"name": "write_file", "arguments": {"path": "a.py", "content": "x = 1\n"}}])
        self.assertEqual(visible_text(text), "確認します。")

    def test_path_escape_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            result = execute_tool(Path(tmp), "write_file", {"path": "../evil.py", "content": ""})
            self.assertTrue(result.startswith("error"))

    def test_reference_solutions_pass_and_originals_fail(self) -> None:
        for task_dir in sorted(p for p in (DATA / "agent").iterdir() if p.is_dir()):
            with self.subTest(task=task_dir.name), tempfile.TemporaryDirectory() as tmp:
                work = Path(tmp) / "repo"
                shutil.copytree(task_dir / "repo", work)
                self.assertFalse(grade_agent(task_dir, work)["success"])
                for ref in (task_dir / "reference").iterdir():
                    shutil.copy(ref, work / ref.name)
                self.assertTrue(grade_agent(task_dir, work)["success"])

    def test_editing_tests_fails_grading(self) -> None:
        task_dir = DATA / "agent" / "pagination"
        with tempfile.TemporaryDirectory() as tmp:
            work = Path(tmp) / "repo"
            shutil.copytree(task_dir / "repo", work)
            for ref in (task_dir / "reference").iterdir():
                shutil.copy(ref, work / ref.name)
            (work / "tests" / "test_pager.py").write_text("", encoding="utf-8")
            self.assertFalse(grade_agent(task_dir, work)["tests_untouched"])


if __name__ == "__main__":
    unittest.main()

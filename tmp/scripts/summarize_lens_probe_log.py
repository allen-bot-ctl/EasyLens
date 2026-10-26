#!/usr/bin/env python3
"""Summarize the latest EasyLens local run without reading screen text."""

from __future__ import annotations

import argparse
import json
import statistics
from pathlib import Path


def ratio(numerator: int, denominator: int) -> str:
    return f"{numerator}/{denominator} ({numerator / denominator:.0%})" if denominator else "0/0 (n/a)"


def median_ms(events: list[dict], field: str) -> str:
    values = [event[field] for event in events if isinstance(event.get(field), (int, float))]
    return f"{statistics.median(values):.1f} ms" if values else "n/a"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("path", nargs="?", type=Path,
                        help="JSONL file; by default use the latest individual run")
    parser.add_argument("--run-id", help="Show a specific run instead of the latest one")
    args = parser.parse_args()
    log_dir = Path(__file__).resolve().parent / ".build"
    if args.path:
        path = args.path
    elif args.run_id:
        path = log_dir / f"lens-probe-{args.run_id}.jsonl"
        if not path.exists():
            path = log_dir / "lens-probe.jsonl"
    else:
        candidates = [item for item in log_dir.glob("lens-probe-*.jsonl")
                      if item.stat().st_size > 0]
        path = max(candidates, key=lambda item: item.stat().st_mtime) if candidates else log_dir / "lens-probe.jsonl"
    if not path.exists():
        parser.error(f"log not found: {path}")

    events = []
    for line in path.read_text(encoding="utf-8").splitlines():
        try:
            record = json.loads(line)
            if isinstance(record, dict) and "run_id" in record:
                events.append(record)
        except json.JSONDecodeError:
            continue
    if not events:
        parser.error("log has no valid events")

    run_id = args.run_id or events[-1]["run_id"]
    selected = [event for event in events if event["run_id"] == run_id]
    if not selected:
        parser.error(f"run not found: {run_id}")

    def of_kind(kind: str) -> list[dict]:
        return [event for event in selected if event.get("event") == kind]

    captures = of_kind("capture.completed")
    requested = of_kind("translation.requested")
    started = of_kind("translation.started")
    completed = of_kind("translation.completed")
    presented = of_kind("translation.presented")
    failed = of_kind("translation.failed")
    discarded = of_kind("translation.discarded")
    candidate_captures = [c for c in captures if c.get("english_segments", 0) > 0]
    ocr_captures = [c for c in captures if c.get("ocr_lines", 0) > 0]
    requested_segments = sum(r.get("segments", 0) for r in requested)
    completed_segments = sum(c.get("responses", 0) for c in completed)

    print(f"日志: {path}")
    print(f"run_id: {run_id}")
    print(f"取像次数: {len(captures)}")
    print(f"OCR 检出文字: {ratio(len(ocr_captures), len(captures))}")
    print(f"短词 OCR 校正: {sum(c.get('ocr_corrected') is True for c in captures)}")
    print(f"英文门禁通过: {ratio(len(candidate_captures), len(captures))}")
    print(f"非英文/无候选跳过: {len(captures) - len(candidate_captures)}")
    print(f"文字自适应框选: {ratio(sum(c.get('auto_fitted') is True for c in candidate_captures), len(candidate_captures))}")
    print(f"疑似截断: {sum(c.get('possible_truncation') is True for c in captures)}")
    print(f"候选→翻译请求: {ratio(len(requested), len(candidate_captures))}")
    print(f"请求→任务启动: {ratio(len(started), len(requested))}")
    print(f"请求→译文返回: {ratio(len(completed), len(requested))}")
    print(f"译文返回→完整窗口显示: {ratio(len(presented), len(completed))}")
    print(f"英文片段→译文片段: {ratio(completed_segments, requested_segments)}")
    print(f"失败: {len(failed)}；过期丢弃: {len(discarded)}")
    print("中位耗时: 取像 {}；OCR {}；本地翻译 {}".format(
        median_ms(captures, "capture_ms"),
        median_ms(captures, "ocr_ms"),
        median_ms(completed, "translation_ms"),
    ))
    requested_ids = {r.get("capture_id") for r in requested}
    started_ids = {s.get("capture_id") for s in started}
    finished_ids = {e.get("capture_id") for e in completed + failed + discarded}
    print(f"候选未发请求: {[c.get('capture_id') for c in candidate_captures if c.get('capture_id') not in requested_ids]}")
    print(f"请求未启动: {sorted(requested_ids - started_ids)}")
    print(f"启动后未结案: {sorted(started_ids - finished_ids)}")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Exercise every focus word in one fixed, public English sentence.

Uses the same sentence, local, micro and prefix spans as the Swift probe.
Requires a built EasyLensProbe.app; output never includes screen content.
"""

import re
import subprocess
import sys
from pathlib import Path


SENTENCES = [
    "Morning!",
    "Though it's already afternoon in Shanghai, so I hope the day's treating you well.",
    "What are you working on today?",
]
# Human-reviewed semantic cues, independent of the probe's output labels.
EXPECTED = [
    ["早上"],
    ["虽然", "是", "已经", "下午", "在", "上海", "所以", "我", "希望",
     "限定", "正在", "善待", "你", "好"],
    ["什么", "正在", "你", "工作", "合译", "今天"],
]
WORDS = re.compile(r"[A-Za-z]+(?:['’][A-Za-z]+)?")
PUNCTUATION = set(",;:.?!")
MARKER = "⟦X⟧"
RESULT = re.compile(r"FOCUS_SELF_TEST result=(.*?) basis=(.*?) translatedMs=")


def span(text, matches, left, right, target):
    start = matches[left].start()
    end = matches[right].end()
    source = text[start:end]
    mask_start = matches[target].start() - start
    mask_end = matches[target].end() - start
    return source, source[:mask_start] + MARKER + source[mask_end:]


def context(text, matches, index):
    def crosses(left, right):
        return any(ch in PUNCTUATION for ch in text[matches[left].end():matches[right].start()])

    left = right = index
    for _ in range(2):
        if left == 0 or crosses(left - 1, left):
            break
        left -= 1
    for _ in range(3):
        if right + 1 == len(matches) or crosses(right, right + 1):
            break
        right += 1
    local = span(text, matches, left, right, index)

    micro_left = micro_right = index
    for _ in range(2):
        if micro_right + 1 == len(matches) or crosses(micro_right, micro_right + 1):
            break
        micro_right += 1
    if micro_right == index:
        for _ in range(2):
            if micro_left == 0 or crosses(micro_left - 1, micro_left):
                break
            micro_left -= 1
    micro = span(text, matches, micro_left, micro_right, index)

    prefix_left = prefix_right = index
    if index > 0 and not crosses(index - 1, index):
        prefix_left -= 1
    elif index + 1 < len(matches) and not crosses(index, index + 1):
        prefix_right += 1
    prefix = span(text, matches, prefix_left, prefix_right, index)
    masked_sentence = text[:matches[index].start()] + MARKER + text[matches[index].end():]
    return [text, masked_sentence, *local, *micro, *prefix]


def main():
    binary = Path(__file__).parent / ".build/EasyLensProbe.app/Contents/MacOS/EasyLensProbe"
    if not binary.is_file():
        print("Build the probe first: sh tmp/scripts/run_word_magnifier_probe.sh", file=sys.stderr)
        return 2
    unresolved = []
    failed = []
    mismatches = []
    total = 0
    for sentence, expectations in zip(SENTENCES, EXPECTED):
        matches = list(WORDS.finditer(sentence))
        assert len(matches) == len(expectations)
        for index, match in enumerate(matches):
            anchor = match.group()
            args = [str(binary), "--translate-focus-both", anchor]
            args.extend(context(sentence, matches, index))
            try:
                run = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                     text=True, timeout=20)
            except subprocess.TimeoutExpired:
                failed.append(anchor + ": timeout")
                print("{}\tERROR timeout".format(anchor), flush=True)
                continue
            line = RESULT.search(run.stdout)
            if not line:
                failed.append(anchor + ": no result")
                print("{}\tERROR {}".format(anchor, run.stdout.strip() or run.stderr.strip()), flush=True)
                continue
            result, basis = line.groups()
            total += 1
            if result == "unresolved":
                unresolved.append(anchor)
            if expectations[index] not in result:
                mismatches.append(anchor)
            print("{}\t{}\t{}\t{}".format(
                anchor, result, basis, "OK" if expectations[index] in result else "MISMATCH"),
                flush=True)
    # A possessive before an -ing noun must not be read as an "is" contraction.
    contrast = "The company's working group met today."
    matches = list(WORDS.finditer(contrast))
    index = next(i for i, match in enumerate(matches) if match.group() == "company's")
    args = [str(binary), "--translate-focus-both", "company's"]
    args.extend(context(contrast, matches, index))
    run = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                         text=True, timeout=20)
    contrast_result = RESULT.search(run.stdout)
    if not contrast_result or "公司" not in contrast_result.group(1) or "正在" in contrast_result.group(1):
        mismatches.append("company's(possessive)")
    print("company's(possessive)\t{}\t{}".format(
        contrast_result.group(1) if contrast_result else "ERROR",
        "OK" if "company's(possessive)" not in mismatches else "MISMATCH"), flush=True)
    print("SUMMARY resolved={}/{} unresolved={} failed={}".format(
        total - len(unresolved), total, ",".join(unresolved) or "-", ",".join(failed) or "-"))
    print("QUALITY semantic_cues={}/{} mismatches={}".format(
        total + 1 - len(mismatches), total + 1, ",".join(mismatches) or "-"))
    return 1 if failed or mismatches else 0


if __name__ == "__main__":
    sys.exit(main())

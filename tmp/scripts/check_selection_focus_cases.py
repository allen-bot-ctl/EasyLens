#!/usr/bin/env python3
"""Check copied-selection focus against OCR merges and nearby-row conflicts."""

import re
import subprocess
import sys
from pathlib import Path


WORD = re.compile(r"[A-Za-z]+(?:['’][A-Za-z]+)?")
BINARY = Path(__file__).parent / ".build/EasyLensProbe.app/Contents/MacOS/EasyLensProbe"


def focus_index(line, word, occurrence=0):
    matches = [i for i, match in enumerate(WORD.finditer(line))
               if match.group().lower() == word.lower()]
    return matches[occurrence]


def main():
    if not BINARY.is_file():
        print("Build the probe first: sh tmp/scripts/run_word_magnifier_probe.sh",
              file=sys.stderr)
        return 2
    selection = "Thanks again for the kind words. Is there anything I can help you with today?"
    earlier = "Hi! 👋 Nice to just hang out with no work attached. I hope your Friday is going well so far."
    noisy = earlier.replace("👋", "").replace("attached", "attachecl")
    cases = [
        ("merged focus and typo", selection, "ThanksagaIn",
         "ThanksagaIn for the kind words. Is there anything I can help you with today?", 0, True),
        ("merged focus only", "Thanks again", "ThanksagaIn", "ThanksagaIn", 0, True),
        ("distant OCR error", earlier, "Friday", noisy,
         focus_index(noisy, "Friday"), True),
        ("adjacent line", "line twelve selected", "selected",
         "line thirteen selected", 2, False),
        ("shared prefix", "before the meeting", "before",
         "before the calendar", 0, False),
        ("same short phrase", "before the meeting", "before",
         "before the meeting", 0, True),
        ("stale one", "one two", "Two", "three Two", 1, False),
        ("short-word conflict", "it is", "in", "it in", 1, False),
        ("repeated wrong occurrence", "one two", "one",
         "one three one two", 0, False),
        ("repeated right occurrence", "one two", "one",
         "one three one two", 2, True),
        ("single copied word", "before", "before",
         "before the meeting", 0, False),
        ("nearby conflicting word", selection, "ThanksagaIn",
         "ThanksagaIn with the kind words", 0, False),
    ]
    for name, copied, anchor, line, index, expected in cases:
        run = subprocess.run(
            [str(BINARY), "--inspect-selection-focus", copied, anchor, line, str(index)],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=10)
        actual = run.stdout.strip().endswith("promotes=true")
        if run.returncode or actual != expected:
            print("FAIL {}: {} {}".format(name, run.stdout.strip(), run.stderr.strip()))
            return 1
        print("PASS {}".format(name))
    print("SUMMARY passed={}/{}".format(len(cases), len(cases)))
    return 0


if __name__ == "__main__":
    sys.exit(main())

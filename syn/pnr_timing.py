#!/usr/bin/env python3
"""Read a Gowin P&R timing report and fail if anything is violated.

Why this exists. `gw_sh` writes its timing summary into an HTML report and
exits 0 whether or not the design closed. A bitstream with setup violations
programs perfectly and then behaves in ways that look like design bugs: the
benchmark's soak build once came out with 1068 setup-violated endpoints and
produced no UART output at all, and an hour went into looking for a hang in
the sequencer. The timing report had the answer the whole time.

So every build that produces a bitstream should pass through here, and a
violated endpoint should be an exit code rather than a line in a file nobody
opened.

Usage:
    syn/pnr_timing.py <impl/pnr/BASE_tr_content.html> [more ...]

Exit status:
    0  every report read cleanly and reported zero violated endpoints
    1  at least one report has a violated endpoint
    2  a report could not be read, or did not contain the summary
"""

import html
import re
import sys

FIELD = re.compile(r"Numbers of (Setup|Hold) Violated Endpoints")
CELL = re.compile(r"<td.*?</td>", re.S)
TAGS = re.compile(r"<.*?>")


def violations(path):
    """Return {'Setup': n, 'Hold': n} for one report, or None if not found."""
    with open(path, errors="ignore") as fh:
        text = fh.read()

    found = {}
    for match in FIELD.finditer(text):
        # The count is the next table cell after the label. Taking the first
        # cell rather than a fixed offset keeps this working across the two
        # table layouts Gowin emits for the two fields.
        tail = text[match.end():match.end() + 400]
        cells = [html.unescape(TAGS.sub("", c)).strip() for c in CELL.findall(tail)]
        for cell in cells:
            if cell.isdigit():
                found[match.group(1)] = int(cell)
                break
    return found or None


def main(argv):
    if len(argv) < 2:
        print(__doc__.strip())
        return 2

    worst = 0
    for path in argv[1:]:
        try:
            counts = violations(path)
        except OSError as err:
            print(f"UNREADABLE  {path}: {err}")
            worst = max(worst, 2)
            continue

        if counts is None:
            print(f"NO SUMMARY  {path} -- the report has no violated-endpoint field")
            worst = max(worst, 2)
            continue

        setup = counts.get("Setup")
        hold = counts.get("Hold")
        if setup is None or hold is None:
            print(f"NO SUMMARY  {path} -- found only {sorted(counts)}")
            worst = max(worst, 2)
            continue

        if setup or hold:
            print(f"VIOLATED    {path}: {setup} setup, {hold} hold")
            worst = max(worst, 1)
        else:
            print(f"CLEAN       {path}: 0 setup, 0 hold")

    return worst


if __name__ == "__main__":
    sys.exit(main(sys.argv))

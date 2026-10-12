#!/usr/bin/env python3
"""Flatten a Gowin Timing Analysis Report into something reviewable.

Gowin writes STA as HTML with one table cell per line, which is unreadable in a
diff and unquotable in a report. This turns one of those files into text:
the run summary, the clock table, the Fmax table, the TNS table, and the
25 worst setup and hold paths as one line each.

    python3 syn/sta_report.py <impl/pnr/project_tr_content.html> [title]

The full per-path dumps stay in the HTML; this is the part that gets read.
"""
import html
import re
import sys

ROW_FIELDS = 9           # path number, slack, from, to, 2 clocks, relation, skew, delay
MAX_ROWS = 25            # report_timing is run with -max_paths 25


def flatten(path):
    raw = open(path, encoding='utf8', errors='ignore').read()
    text = html.unescape(re.sub(r'<[^>]+>', '\n', raw))
    return [line.strip() for line in text.split('\n') if line.strip()]


def section(lines, start, end_markers, limit=None):
    try:
        i = lines.index(start)
    except ValueError:
        return []
    out = []
    for line in lines[i:]:
        if out and line in end_markers:
            break
        out.append(line)
        if limit and len(out) >= limit:
            break
    return out


def path_table(lines, title):
    """The N worst paths, one line each instead of ten."""
    try:
        i = lines.index(title)
    except ValueError:
        return []
    header = lines[i + 1]
    # column names run from after the header to the first numeric path index
    start = i + 2
    while start < len(lines) and not lines[start].isdigit():
        start += 1
    rows = []
    for n in range(MAX_ROWS):
        base = start + n * ROW_FIELDS
        cells = lines[base:base + ROW_FIELDS]
        if len(cells) < ROW_FIELDS or not cells[0].isdigit():
            break
        _, slack, frm, to, fclk, tclk, rel, skew, delay = cells
        rows.append(f'  {slack:>8}  {frm}  ->  {to}'
                    f'   [{fclk} -> {tclk}]  rel {rel}  skew {skew}  delay {delay}')
    return [title, header, '  slack     from -> to   [clocks]  relation/skew/delay'] + rows


def main():
    src = sys.argv[1]
    title = sys.argv[2] if len(sys.argv) > 2 else src
    lines = flatten(src)
    out = [f'# {title}', '']
    out += section(lines, 'Timing Messages', {'Timing Summaries'})
    out += ['']
    out += section(lines, 'STA Tool Run Summary:', {'Timing Details'})
    out += ['']
    out += path_table(lines, 'Setup Paths Table')
    out += ['']
    out += path_table(lines, 'Hold Paths Table')
    out += ['', f'Full per-path dumps: {src}']
    print('\n'.join(out))


if __name__ == '__main__':
    main()

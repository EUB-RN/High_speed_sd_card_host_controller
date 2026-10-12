#!/usr/bin/env bash
#
# mutation.sh -- break the RTL on purpose, one fault at a time, and require the
# regression to notice (R-DEL-7).
#
# A test suite that passes proves nothing on its own: it has to be shown to
# FAIL when the design is wrong. The client does this by injecting the faults
# of Appendix E.4 into the RTL and re-running the suite, so this script does it
# first, automatically, and reports any fault the suite lets through.
#
# HOW IT WORKS. For each fault: copy the whole rtl/ tree to a scratch
# directory, apply one textual substitution, run a named subset of the
# regression against the mutated tree, and record whether it failed. A fault
# the suite does not catch is a hole in the suite, and the script exits
# non-zero naming it.
#
# Nothing under rtl/ is modified: the mutation is applied to the copy, and the
# test is pointed at the copy with RTL_DIR. If this script is interrupted the
# working tree is untouched by construction, which is the reason it works on a
# copy rather than patching and reverting in place.
#
# ABOUT THE FAULT LIST. The eight faults below are this project's own, chosen
# to put one fault on each mechanism the design depends on -- the CRCs, the
# framing, the retry budget, the FIFO commit, the timeouts, the write status
# token, the card-detect polarity and the register decode. When the client's
# Appendix E.4 list is to hand, each entry there replaces or joins one line in
# the table: a fault is a file, a search string, a replacement and the tests
# that must catch it. Nothing else in this script changes.
#
# ONE FAULT THAT HAD TO BE REWRITTEN, because it is the trap this script is
# most likely to fall into. The first version of the commit fault replaced
# `wptr_pub <= wptr_nxt` with `wptr_pub <= wptr_bin`, and nothing caught it.
# That was not a hole in the suite: `wptr_nxt` is `wptr_bin + wr_push`, and the
# block layer raises wr_commit on a cycle with no write, so on every cycle the
# fault could fire the two expressions are equal and the mutant is the original
# design. An equivalent mutant is not a missed fault, and the only way to tell
# the two apart is to read why the test passed rather than trusting the count.
#
# USAGE
#   test/error_injection/mutation.sh            # all faults
#   test/error_injection/mutation.sh crc16_poly # one fault by name
#   KEEP=1 test/error_injection/mutation.sh     # keep the mutated trees
#
set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
work="${TMPDIR:-/tmp}/ultra_sd_mutation.$$"

mkdir -p "$work"
cleanup() { [ "${KEEP:-0}" = "1" ] || rm -rf "$work"; }
trap cleanup EXIT

# name | file (relative to rtl/) | search | replace | tests that must catch it
#
# The search strings are deliberately long enough to be unique: a mutation that
# silently matches nothing would "pass" by not being applied at all, and the
# script checks for exactly that below.
faults=(
"crc16_poly|ultra_sd_pkg.sv|CRC16_POLY = 16'h1021|CRC16_POLY = 16'h1011|crc16 line_card block_axis_read"
"crc7_poly|ultra_sd_pkg.sv|CRC7_POLY  = 7'h09|CRC7_POLY  = 7'h0b|crc7 init_ladder_basic"
"retry_budget|ultra_sd_block.sv|(retry_q < RTY_W'(CRC_RETRIES))|1'b0|error_inject"
"fifo_commit|axi4/async_fifo.sv|if (wr_commit) begin|if (1'b1) begin|async_fifo error_inject"
"fifo_overpublish|axi4/async_fifo.sv|wptr_pub  <= wptr_nxt;|wptr_pub  <= wptr_nxt + 1;|async_fifo block_axis_write"
"fifo_rewind|axi4/async_fifo.sv|wptr_bin <= wptr_pub;|wptr_bin <= wptr_bin;|async_fifo error_inject"
"write_status_token|ultra_sd_line.sv|tx_status_ok_q <= ({stat_sh_q, dat_in_i[0]} == 3'b010);|tx_status_ok_q <= 1'b1;|error_inject block_axis_write"
"card_detect_polarity|system_controller.sv|card_present_q <= ~cd_raw;|card_present_q <= cd_raw;|system_controller top_integration"
"reg_decode_ctrl|ultra_sd_reg.sv|REG_CTRL[5:2]|REG_STATUS[5:2]|ultra_sd_reg top_integration"
)

want="${1:-}"
pass=0; miss=0; skipped=0
missed_names=""

for entry in "${faults[@]}"; do
  IFS='|' read -r name file search replace tests <<<"$entry"
  file="${file#rtl_top:}"          # tolerated prefix, kept for readability above

  if [ -n "$want" ] && [ "$want" != "$name" ]; then continue; fi

  tree="$work/$name"
  rm -rf "$tree"
  cp -r "$repo/rtl" "$tree"

  target="$tree/$file"
  if [ ! -f "$target" ]; then
    echo "SKIP  $name -- $file not found"
    skipped=$((skipped+1)); continue
  fi

  # A mutation that matches nothing is not a passing fault, it is a broken
  # fault definition, and silently counting it as caught would be the worst
  # outcome this script can produce.
  if ! grep -qF -- "$search" "$target"; then
    echo "SKIP  $name -- search string no longer present in $file"
    echo "        (the RTL moved; update the fault table)"
    skipped=$((skipped+1)); continue
  fi

  python3 - "$target" "$search" "$replace" <<'PY'
import sys
path, search, replace = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(path).read()
# One occurrence only: a fault is one fault.
open(path, 'w').write(s.replace(search, replace, 1))
PY

  caught=0
  for t in $tests; do
    if ! make -C "$repo/test" "$t" RTL_DIR="$tree" >"$work/$name.$t.log" 2>&1; then
      caught=1
      break
    fi
  done

  if [ "$caught" = "1" ]; then
    echo "CAUGHT  $name -- $t failed, as it must"
    pass=$((pass+1))
  else
    echo "MISSED  $name -- every one of: $tests passed on a broken design"
    echo "        logs in $work/$name.*.log"
    miss=$((miss+1))
    missed_names="$missed_names $name"
  fi
done

echo
echo "mutation.sh: $pass caught, $miss missed, $skipped skipped"
if [ "$miss" -gt 0 ]; then
  echo "the suite does not catch:$missed_names"
  exit 1
fi
[ "$skipped" -gt 0 ] && exit 2
exit 0

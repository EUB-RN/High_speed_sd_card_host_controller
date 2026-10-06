# Coverage closure. Functional coverage says which of the specification's
# states were actually exercised; without it a green regression only proves
# that whatever ran, passed.
#
# Covergroups live in test/common/cov/ and are instantiated by the functional
# and vip testbenches, not here. This category owns the merge-and-report step
# and the ratchet: coverage may not go down.

coverage_TESTS :=

# Still to write here:
#   covergroups          command opcodes issued, response types seen, error
#                        codes of Table 5-3 reached, bus widths, every
#                        CFG_CLK divisor, every Table 7-1 fallback entered
#   report               merge per-run databases, emit reports/coverage.txt

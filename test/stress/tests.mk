# Stress and soak. Long, randomised, deliberately hostile: random
# backpressure and starvation patterns on both streams, randomised block
# counts and LBAs, clock changes mid-transfer, card removal at the worst
# moment. Reproducibility comes from the seed, so every failure is replayable
# with `make <test> SEED=<n>`.
#
# These runs are long enough that they belong in a nightly regression rather
# than the pre-commit gate.

stress_TESTS :=

# Still to write here:
#   random_traffic       seeded random read/write mix, scoreboard-checked
#   backpressure_soak    worst-case tready/tvalid patterns, sustained
#   soak_30min           the R-MEAS-5 soak, zero unrecovered errors

# Error- and fault-injection tests. Two distinct jobs, both living here:
#
#   1. Injecting errors into the *environment* -- a card that corrupts CRC,
#      drops a response, returns a bad status token -- and checking that the
#      design recovers as specified. This is design verification.
#
#   2. Injecting faults into the *design* and checking that the testbench
#      notices (R-DEL-7, Appendix E.4). This is verification of the
#      verification, and the client does exactly this to the delivery. Each
#      mutation is applied to a copy of the RTL under build/, never in place.
#
# Run it with `make error_injection`; mutation runs expect to FAIL the
# testbench, so the pass criterion is inverted and owned by the script.

error_injection_TESTS :=

# Still to write here:
#   crc16_read_error     corrupt a read block, expect retry then CRC_RETRIES
#                        exhaustion and the Table 5-3 error code
#   crc_status_reject    card returns a write CRC status token of "rejected"
#   response_timeout     card never answers, expect the named timeout
#   dat_stuck_busy       card holds DAT0 low past the busy timeout
#   mutation.sh          the Appendix E.4 fault list, one mutation at a time

# Functional tests: end-to-end scenarios against a behavioural SD card model,
# written in the language of the specification rather than of the RTL. These
# are the R-DEL-6 required scenarios.

functional_TESTS := ultra_sd_line

# DAT hatti cerceveleme: yazma / okuma / CRC16 / CRC durum token'i, davranissal
# bir kart modeline karsi.
ultra_sd_line_SRCS := $(PKG) $(RTL_DIR)/crc/ultra_sd_crc16.sv \
                      $(RTL_DIR)/ultra_sd_line.sv \
                      $(TEST_DIR)/functional/tb_ultra_sd_line.sv

# Still to write here (R-DEL-6):
#   init_ladder        Section 6.1 / Appendix B, including the 74-clock ramp
#   hs_switch          CMD6 High Speed switch, verified by status block read-back
#   sdsc_reject        SDSC detected and rejected, not silently mishandled
#   read_single        CMD17
#   read_multi         CMD18 streaming, tlast correct on the last beat
#   write_multi        CMD25 with ACMD23 pre-erase
#   bus_width          4-bit operation (ACMD6)
#   card_detect        active-low card detect, insert and remove mid-transfer
#   error_recovery     recovery without full re-initialisation (R-FUNC-16)
#   timeouts           every wait bounded by its named timeout (R-FUNC-17)
#   degradation        the Table 7-1 fallback ladder, Section 7.4 procedure

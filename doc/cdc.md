# Clock-domain crossings

Required by R-DEL-2. List **every** crossing with its structure and its
justification, or state explicitly that the design is single-domain (R-CLK-3).

Permitted structures (R-CLK-3):

- two-flop synchroniser -- single-bit control only
- asynchronous FIFO -- data
- full handshake -- data

Undocumented crossings are a gate failure.

| # | Signal / bus | From | To | Structure | Justification |
|---|--------------|------|----|-----------|---------------|
|   |              |      |    |           |               |

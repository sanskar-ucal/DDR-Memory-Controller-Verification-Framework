# Functional Coverage Matrix

Merged from 9 regression runs (12,600 host requests) on 2026-10-20 00:14, commit `9995f0c`.

**Closure: 103/103 planned bins (100.0%).** Every planned bin is reachable by design; none are excluded.

## Closure by group

| Group | Bins | Hit | Closure | Hit by pure random |
|---|---|---|---|---|
| `op_bank_rowstate` | 24 | 24 | 100% | 0/24 |
| `row_buffer` | 1 | 1 | 100% | 0/1 |
| `row_alias_conflict` | 12 | 12 | 100% | 0/12 |
| `timing_edge` | 13 | 13 | 100% | 0/13 |
| `dram_cmd` | 7 | 7 | 100% | 0/7 |
| `write_data_pattern` | 7 | 7 | 100% | 0/7 |
| `addr_corner` | 4 | 4 | 100% | 0/4 |
| `same_addr_hazard` | 4 | 4 | 100% | 0/4 |
| `outstanding_depth` | 5 | 5 | 100% | 0/5 |
| `queue_full_backpressure` | 4 | 4 | 100% | 0/4 |
| `out_of_order_completion` | 4 | 4 | 100% | 0/4 |
| `bank_parallelism` | 4 | 4 | 100% | 0/4 |
| `refresh_open_banks` | 5 | 5 | 100% | 0/5 |
| `refresh_interrupt` | 5 | 5 | 100% | 0/5 |
| `host_back_to_back` | 4 | 4 | 100% | 0/4 |

## Bin x test matrix

Cells are hit counts summed over all seeds of a test (`·` = never hit). Column key: **smoke** = `ddr_smoke_test`, **mixed** = `ddr_rand_test`, **hazard** = `ddr_hazard_test`, **refresh** = `ddr_refresh_test`, **alias** = `ddr_row_alias_test`.

### `op_bank_rowstate`

| Bin | Total | smoke | mixed | hazard | refresh | alias |
|---|---:|---:|---:|---:|---:|---:|
| `RD_B0_HIT` | 932 | 16 | 604 | 108 | 48 | 156 |
| `RD_B0_MISS` | 62 | 4 | 36 | 6 | 14 | 2 |
| `RD_B0_CONFLICT` | 686 | 63 | 428 | 61 | 132 | 2 |
| `RD_B1_HIT` | 878 | 14 | 580 | 113 | 59 | 112 |
| `RD_B1_MISS` | 65 | 2 | 36 | 7 | 20 | · |
| `RD_B1_CONFLICT` | 628 | 58 | 398 | 57 | 113 | 2 |
| `RD_B2_HIT` | 846 | 12 | 528 | 148 | 64 | 94 |
| `RD_B2_MISS` | 64 | 2 | 34 | 8 | 16 | 4 |
| `RD_B2_CONFLICT` | 669 | 55 | 422 | 82 | 108 | 2 |
| `RD_B3_HIT` | 783 | 15 | 487 | 88 | 71 | 122 |
| `RD_B3_MISS` | 61 | 4 | 29 | 8 | 19 | 1 |
| `RD_B3_CONFLICT` | 657 | 56 | 418 | 59 | 121 | 3 |
| `WR_B0_HIT` | 642 | 6 | 483 | 97 | 56 | · |
| `WR_B0_MISS` | 78 | 3 | 47 | 6 | 13 | 9 |
| `WR_B0_CONFLICT` | 857 | 50 | 496 | 56 | 104 | 151 |
| `WR_B1_HIT` | 620 | 15 | 426 | 126 | 53 | · |
| `WR_B1_MISS` | 80 | 2 | 47 | 10 | 8 | 13 |
| `WR_B1_CONFLICT` | 873 | 65 | 529 | 70 | 108 | 101 |
| `WR_B2_HIT` | 647 | 12 | 453 | 143 | 39 | · |
| `WR_B2_MISS` | 78 | 4 | 45 | 7 | 11 | 11 |
| `WR_B2_CONFLICT` | 880 | 57 | 555 | 70 | 109 | 89 |
| `WR_B3_HIT` | 585 | 18 | 391 | 109 | 67 | · |
| `WR_B3_MISS` | 65 | 3 | 35 | 9 | 8 | 10 |
| `WR_B3_CONFLICT` | 864 | 64 | 493 | 52 | 139 | 116 |

### `row_buffer`

| Bin | Total | smoke | mixed | hazard | refresh | alias |
|---|---:|---:|---:|---:|---:|---:|
| `MISS_AFTER_REFRESH` | 517 | 16 | 293 | 57 | 105 | 46 |

### `row_alias_conflict`

| Bin | Total | smoke | mixed | hazard | refresh | alias |
|---|---:|---:|---:|---:|---:|---:|
| `BIT0` | 536 | 35 | 283 | 14 | 181 | 23 |
| `BIT1` | 495 | 47 | 273 | 25 | 130 | 20 |
| `BIT2` | 289 | 3 | 127 | 18 | 123 | 18 |
| `BIT3` | 75 | 2 | 54 | · | · | 19 |
| `BIT4` | 64 | 9 | 32 | · | · | 23 |
| `BIT5` | 23 | · | 8 | · | · | 15 |
| `BIT6` | 33 | · | 13 | · | · | 20 |
| `BIT7` | 32 | · | 11 | · | · | 21 |
| `BIT8` | 33 | · | 11 | · | · | 22 |
| `BIT9` | 40 | · | 12 | · | · | 28 |
| `BIT10` | 37 | · | 18 | · | · | 19 |
| `BIT11` | 28 | · | 13 | · | · | 15 |

### `timing_edge`

| Bin | Total | smoke | mixed | hazard | refresh | alias |
|---|---:|---:|---:|---:|---:|---:|
| `TRCD` | 4.5k | 312 | 2.7k | 399 | 637 | 511 |
| `TRP` | 4.3k | 329 | 2.7k | 431 | 637 | 234 |
| `TRAS` | 868 | 75 | 550 | 107 | 127 | 9 |
| `TRC` | 667 | 55 | 418 | 88 | 99 | 7 |
| `TRRD` | 1.6k | 121 | 941 | 64 | 278 | 165 |
| `TRTP` | 1.3k | 46 | 739 | 73 | 140 | 298 |
| `TWR` | 1.7k | 164 | 1.1k | 173 | 299 | 5 |
| `RD_RD_TCCD` | 3.4k | 120 | 2.2k | 406 | 383 | 272 |
| `WR_WR_TCCD` | 2.7k | 78 | 1.8k | 409 | 246 | 158 |
| `WR_RD_TWTR` | 1.8k | 90 | 1.1k | 169 | 192 | 218 |
| `RD_WR_TRTW` | 1.2k | 70 | 777 | 147 | 174 | 3 |
| `TRFC` | 157 | 7 | 98 | 19 | 19 | 14 |
| `PREA_REF_TRP` | 174 | 8 | 101 | 19 | 32 | 14 |

### `dram_cmd`

| Bin | Total | smoke | mixed | hazard | refresh | alias |
|---|---:|---:|---:|---:|---:|---:|
| `MRS` | 9 | 2 | 4 | 1 | 1 | 1 |
| `ACT` | 6.8k | 498 | 4.1k | 577 | 1.1k | 519 |
| `RD` | 6.3k | 301 | 4.0k | 745 | 785 | 500 |
| `WR` | 6.3k | 299 | 4.0k | 755 | 715 | 500 |
| `PRE` | 6.1k | 468 | 3.7k | 507 | 934 | 466 |
| `PREA` | 174 | 8 | 101 | 19 | 32 | 14 |
| `REF` | 181 | 8 | 102 | 19 | 38 | 14 |

### `write_data_pattern`

| Bin | Total | smoke | mixed | hazard | refresh | alias |
|---|---:|---:|---:|---:|---:|---:|
| `RANDOM` | 4.4k | 208 | 2.8k | 526 | 533 | 359 |
| `ZERO` | 328 | 20 | 228 | 33 | 24 | 23 |
| `ONES` | 299 | 12 | 184 | 38 | 31 | 34 |
| `WALK1` | 303 | 18 | 195 | 36 | 31 | 23 |
| `WALK0` | 313 | 18 | 189 | 47 | 35 | 24 |
| `ALT_AA` | 305 | 16 | 203 | 41 | 29 | 16 |
| `ALT_55` | 280 | 7 | 186 | 34 | 32 | 21 |

### `addr_corner`

| Bin | Total | smoke | mixed | hazard | refresh | alias |
|---|---:|---:|---:|---:|---:|---:|
| `ROW_MIN` | 1.4k | 92 | 905 | 152 | 251 | · |
| `ROW_MAX` | 214 | · | 214 | · | · | · |
| `COL_MIN` | 728 | 43 | 578 | 11 | 92 | 4 |
| `COL_MAX` | 248 | · | 235 | 9 | · | 4 |

### `same_addr_hazard`

| Bin | Total | smoke | mixed | hazard | refresh | alias |
|---|---:|---:|---:|---:|---:|---:|
| `RAW` | 1.4k | · | 745 | 141 | 12 | 500 |
| `WAR` | 412 | 1 | 285 | 115 | 11 | · |
| `WAW` | 351 | · | 231 | 118 | 2 | · |
| `RAW_BACK_TO_BACK` | 117 | · | 107 | 8 | 2 | · |

### `outstanding_depth`

| Bin | Total | smoke | mixed | hazard | refresh | alias |
|---|---:|---:|---:|---:|---:|---:|
| `D1` | 98 | 5 | 37 | 1 | 54 | 1 |
| `D2_4` | 465 | 37 | 223 | 3 | 199 | 3 |
| `D5_8` | 5.7k | 199 | 3.7k | 973 | 404 | 433 |
| `D9_12` | 4.7k | 249 | 3.0k | 505 | 530 | 455 |
| `D13_PLUS` | 1.6k | 110 | 1.1k | 18 | 313 | 108 |

### `queue_full_backpressure`

| Bin | Total | smoke | mixed | hazard | refresh | alias |
|---|---:|---:|---:|---:|---:|---:|
| `B0` | 1.3k | 15 | 878 | 193 | 43 | 180 |
| `B1` | 1.2k | 25 | 757 | 249 | 67 | 84 |
| `B2` | 1.2k | 14 | 769 | 318 | 41 | 67 |
| `B3` | 1.1k | 39 | 692 | 203 | 75 | 102 |

### `out_of_order_completion`

| Bin | Total | smoke | mixed | hazard | refresh | alias |
|---|---:|---:|---:|---:|---:|---:|
| `RD_BYPASS_WR` | 1.7k | 26 | 1.0k | 291 | 125 | 241 |
| `WR_BYPASS_RD` | 1.5k | 38 | 950 | 340 | 143 | · |
| `SAME_DIR_BYPASS` | 1.3k | 60 | 761 | 307 | 160 | 9 |
| `CROSS_BANK` | 19k | 1.1k | 12k | 1.5k | 2.8k | 1.5k |

### `bank_parallelism`

| Bin | Total | smoke | mixed | hazard | refresh | alias |
|---|---:|---:|---:|---:|---:|---:|
| `BANKS_1` | 2.0k | 23 | 1.4k | 428 | 84 | 115 |
| `BANKS_2` | 3.3k | 84 | 2.0k | 670 | 213 | 276 |
| `BANKS_3` | 3.5k | 155 | 2.1k | 342 | 425 | 438 |
| `BANKS_4` | 3.8k | 338 | 2.5k | 60 | 778 | 171 |

### `refresh_open_banks`

| Bin | Total | smoke | mixed | hazard | refresh | alias |
|---|---:|---:|---:|---:|---:|---:|
| `OPEN_0` | 7 | · | 1 | · | 6 | · |
| `OPEN_1` | 1 | · | 1 | · | · | · |
| `OPEN_2` | 15 | 1 | 7 | 2 | 4 | 1 |
| `OPEN_3` | 44 | 4 | 26 | 6 | 5 | 3 |
| `OPEN_4` | 114 | 3 | 67 | 11 | 23 | 10 |

### `refresh_interrupt`

| Bin | Total | smoke | mixed | hazard | refresh | alias |
|---|---:|---:|---:|---:|---:|---:|
| `PENDING_REQUESTS` | 153 | 7 | 97 | 19 | 16 | 14 |
| `READ_DATA_IN_FLIGHT` | 30 | · | 15 | 5 | 4 | 6 |
| `REQ_ACCEPTED_DURING_TRFC` | 83 | 1 | 37 | · | 44 | 1 |
| `BACKPRESSURE_DURING_REFRESH` | 18 | 1 | 9 | 1 | 5 | 2 |
| `QUEUE_FULL_AT_REFRESH` | 130 | 5 | 86 | 19 | 6 | 14 |

### `host_back_to_back`

| Bin | Total | smoke | mixed | hazard | refresh | alias |
|---|---:|---:|---:|---:|---:|---:|
| `RD_RD` | 1.7k | 81 | 1.0k | 122 | 346 | 140 |
| `RD_WR` | 1.6k | 72 | 892 | 144 | 300 | 146 |
| `WR_RD` | 1.5k | 72 | 910 | 151 | 268 | 140 |
| `WR_WR` | 1.6k | 74 | 1.0k | 119 | 280 | 140 |


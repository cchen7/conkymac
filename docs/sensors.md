# Sensors on Apple Silicon

CPU and GPU temperature, CPU frequency and the P/E cluster split come from private interfaces. macOS has no public API for them. The approach follows [Stats](https://github.com/exelban/stats). All access is read-only, and nothing is written to the SMC.

Because key names and table layouts change between chip generations, these readings are the least portable part of the app. If a value shows N/A, run:

```sh
/Applications/ConkyMac.app/Contents/MacOS/ConkyMac --sensors
```

It prints the chip, the core types, every DVFS table found, the IOReport channels and the table each one matched, and every floating-point `T*` SMC key with its value; the keys used for the CPU reading are marked with `*`. It ends with the final readings and any issues. Please attach that output to bug reports.

## Core types

Each core's `cluster-type` is read from `IODeviceTree:/cpus`. `E` is efficiency. `P` and `M` both count as performance, because M5 reports `M` ("performance") and `P` ("super") cores. The base M5 tested has only `E` and `P`.

## Temperature

The SMC keys are enumerated once at startup; there are a few thousand. Which keys count as CPU temperature depends on the chip generation, which is parsed from the brand string (`Apple M<n>`):

| Generation | Keys |
| --- | --- |
| M1–M3 | Stats' per-generation lists |
| M4 | `Tpx*` and `Tex*` cluster sensors, plus Stats' M4 list |
| M5 | Stats' M5 list (`Tp00`, `Tp04`, ...) |
| Unknown or newer | The M5 list plus `Tpx*`/`Tex*` |

The panel shows the **hottest** valid reading (10–120 °C), not an average. Idle P-core sensors on M4 Max report a floor of 40 °C, which would distort an average. The GPU reading is the hottest `Tg*` key.

Each generation has its own list because a key can measure something unrelated on a different chip, and any value in the valid range would raise the maximum.

Observations behind these choices:

- **M4 Max.** The maximum of the cluster keys matched the maximum of all 67 per-core keys at idle, under an 8-process load and while cooling.
- **M5.** Under a 10-process load the selected `Tp0*` keys included the hottest sensor on the machine (102 °C, against 88 °C for the hottest `Te0*` key). So `Te0*` is not included, even though at idle it reads about 2 °C above the selected keys. Loading only the E cores was not tested.

## Frequency

The IOReport group `CPU Stats` / `CPU Complex Performance States` reports how long each cluster spent in each performance state. The pmgr device-tree tables (`voltage-states*-sram`) give the frequency of each state, in kHz on M4 and later and in Hz on earlier chips.

| Channel | Table |
| --- | --- |
| `ECPU*` | `voltage-states1-sram` |
| `PCPU*` | `voltage-states5-sram` |
| `MCPU*` | `voltage-states22-sram`, falling back to `voltage-states5-sram` |

A table is used only if its length equals the channel's state count after removing the `IDLE`, `DOWN` and `OFF` states. Otherwise the reading is N/A and `--sensors` reports the mismatch, so a wrong table never shows a plausible but wrong number.

The panel's frequency is the residency-weighted average over the last 2 s, and the load is the active residency. Several performance clusters (for example `PCPU` and `PCPU1`, or `MCPU` and `PCPU`) are merged into one "P" value, weighted by active residency.

## Verified so far

| Chip | Result |
| --- | --- |
| M4 Max (12P + 4E) | Temperature and frequency verified under idle, load and cooling: E 1020–2592 MHz (7 states), P 1260–4512 MHz (20 states). |
| M5, MacBook Air (4P + 6E) | Temperature and frequency shown correctly. E 972–3048 MHz (8 states), P 1308–4464 MHz (19 states). No `MCPU` channel or `voltage-states22` table, so the M5 split path was not exercised. |

Not verified: M1, M2, M3, M4 Pro, base M4, M5 Pro and M5 Max. No reading has yet been compared with Activity Monitor or `powermetrics`.

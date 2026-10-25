# conbench

A console speed benchmark for AmigaOS — CON:, CCON:, KingCON,
ViNCEd, CTerm, or any other DOS console handler. Fifteen workloads,
from plain `dir`-style line output to full-screen editor repaints,
timed from the client side of the packet interface, with the tooling
to tell an honestly fast console from one that is merely quick to say
"done".

- Timed with timer.device's EClock (microseconds), each test sized
  automatically to take at least a second — no guessing a `SCALE`.
- Best and median of the repeats, with a mark when they disagree.
- A **check** after each test whose end state is known: the console
  is asked where its cursor is, so a console that lost output shows
  `BAD` instead of looking fast.
- The setup written into every result: the console's handler and
  version, the screen, depth, mode and font, the CPU as exec reports
  it, free memory, and how busy the machine was.
- A geometric mean beside the total, CSV output, and a `BASE` run to
  compare against, row by row.
- Ctrl-C stops it; the tests done so far are still reported.

Born during the CCON 1.2.2 performance campaign, where it first
measured the problem (one ScrollRaster per scrolled row, 34ms each)
and then measured the fixes; kept as its own tool because the
questions it answers — *is my console fast, and is it telling the
truth about it?* — are not specific to any one handler.

## Usage

Run it **inside** the console you want to measure — it writes its
test output to stdout, so the console under test is whichever one
the shell is running in:

```
NewShell CCON:                        (then, in that window)
conbench CCON TO RAM:conbench.txt CSV RAM:ccon.csv

NewShell CON:                         (then, in that window)
conbench CON TO RAM:conbench.txt SYNC BASE RAM:ccon.csv
```

```
conbench NAME <label> [TO file] [REPS n] [SCALE n] [MINTIME n] [SYNC]
         [CSV file] [BASE file] [FORCE]
```

| Argument | Meaning |
|---|---|
| `NAME` | the label written into the result file — call it what you like |
| `TO file` | results **append** here (default `RAM:conbench.txt`), so runs from several consoles land side by side |
| `REPS n` | run the whole suite n times (default 3, at most 20); the best and the median are shown |
| `SCALE n` | a fixed size for every test instead of auto-scaling |
| `MINTIME n` | auto-scaling's target: each test takes at least n seconds (default 1) |
| `SYNC` | end every test with a `WaitForChar` barrier — see *Honesty*, below |
| `CSV file` | also append the run to file as one line per test (label, test, scale, bytes, best ms, median ms, bytes/s, check) |
| `BASE file` | an earlier run's CSV: each row gets a "vs base" ratio, and the summary a ratio of the geometric means |
| `FORCE` | allow a non-console stdout (smoke-testing under vamos); the numbers then mean nothing |

The window names each running test, so the deliberately blank ones
(`scroll-nl`, `insdel-line` — they scroll and blit *empty* rows by
design) don't read as a hang. **Ctrl-C** stops the run; the tests that
finished at least one repeat are reported and the file says it was
stopped.

**Auto-scale:** without `SCALE`, each test first runs once at size 1
(ended by a barrier, so a console that draws behind its replies
cannot make it look free), is grown tenfold until it takes 0.2 s, and
is then sized to take `MINTIME` seconds. The table shows each test's
scale and its bytes per second, which do not depend on the size.

## Sample output

CCON 1.3.1b3 in FS-UAE (A1200, 68020, 3.2.1), compared with an earlier
run:

```
==========================================================
console : ccon2   (conbench 0.4)
when    : 25-Oct-26 15:42:57
handler : CCON (L:ccon-handler, ccon-handler 1.3.1b3 (25.10.26) CCON: LTX console handler)
screen  : 640x256, depth 2, mode PAL:High Res ($8000)
font    : topaz.font 8 (8x8)
type    : DISK_INFO says "CCON"
machine : 68020, exec 47.8, chip 1977 KB / fast 6151 KB free
busy    : 0 other tasks ready to run at the start
window  : 77x30
WARNING : only 77 cols - the 78-char line tests WRAP
          (widen the window past 78 text columns to compare)
run     : reps 2, auto-scaled to 1 s or more a test, sync off
  (secs = the best of the reps, median beside it; ~ = reps differ
   by over 10%; ? = under 0.1 s; check = cursor where it must be)

  test          scale     bytes     secs   median    bytes/s check  vs base
  ------------------------------------------------------------------------
  plain-lines      1     64464    0.976    1.046      66049 ok       0.96
  block-4k         2    128928    1.297    1.343      99404 ok       1.00
  ...
  insdel-line      4      5200    0.845~   0.945       6153 -        1.07
  ...
  sync-line        2     31600    1.546    1.587      20439 ok       0.99
  ------------------------------------------------------------------------
  TOTAL                 848108   21.590                39282
  geometric mean of the rates                23551          1.01
```

## The tests

| Test | What it measures |
|---|---|
| `plain-lines` | 816 × 78-char lines, one `Write()` per line — the ordinary shape of command output, the number most people mean by "is my console fast" |
| `block-4k` | the same bytes in 4K writes — against `plain-lines`, separates per-packet cost from drawing cost |
| `block-32k` | 414 lines in **one** `Write()` — catches big-write slow paths (bounded copy buffers, synchronous fallbacks) |
| `bytewise` | one `Write()` per character — what unbuffered single-character output (More's echo) actually does; nearly pure packet round-trip |
| `scroll-nl` | 12000 bare newlines in 1000-byte writes — the scroll path with no glyphs and few packets. Visually blank by design |
| `wrap-long` | 300-char lines, no newlines — the console wraps them itself |
| `sgr-colour` | colour changes several times per line — the `ls` colours case |
| `sgr-perchar` | a colour change before **every** glyph — run length one, the worst case for run-batched rendering |
| `cursor-pos` | absolute positioning + short text, all over the probed window — the CSI parser and random grid access |
| `vt-frame` | position + erase-EOL + text for every row, repeatedly — the full-screen editor/pager repaint, sized to the probed window |
| `insdel-line` | CSI L/M insert/delete line — real region blits no console can defer past. Visually blank by design |
| `insdel-char` | CSI @/P open/close a mid-line gap — row-tail cell shifts |
| `clear-page` | form feed + a screenful of the probed window (rows less one), 40 pages — the More page-flip path |
| `erase-eol` | CR + text + erase-to-EOL — the progress-bar idiom |
| `sync-line` | `plain-lines` with a render barrier after **every** line — see below |

## Honesty — read this before believing a number

A console is a DOS handler: `Write()` blocks until the handler
replies. What conbench times is therefore *"how long the handler
takes to accept the output"* — and a console that replies first and
draws later looks faster here than it renders. That is not
hypothetical; it is how every fast console on the platform works
(stock con-handler, ViNCEd, and CCON from 1.2.2 on). Three tools to
see through it:

- **Every test starts after an untimed barrier** (0.4): the clear,
  the banner and anything the previous test left undrawn are finished
  before the clock starts, so rows do not leak into each other.
- **`SYNC`** ends each test with a `WaitForChar(fh, 0)` — a packet
  the handler must dequeue behind the writes it is holding. Not a
  guaranteed pixel barrier, but if a console's numbers move between
  a plain and a SYNC run, that console defers, and its plain numbers
  are optimistic.
- **`sync-line`** applies that barrier after *every line*, inside
  one test — the closest the packet interface gets to an honest
  per-line figure, on every console alike. The gap between
  `plain-lines` and `sync-line` *is* the deferral.
- The **check** column asks the console for its cursor (CSI `6n`)
  after the tests whose end state is known, outside the timing: `ok`,
  `BAD` (with where the cursor was and should be), `?` (no answer) or
  `-` (not checked: bytewise, wrap-long and insdel-line end where
  consoles may differ). The scrolling tests are only checked for
  column 1 inside the window, because a console that scrolls in jumps
  (CCON) leaves the cursor above the bottom row until it settles;
  clear-page only in a window of 79 columns or more.
- The **window probe** (CSI `0 SPACE q`, answered on the input
  stream) records the real text grid in the result file, and warns
  when the window is too narrow for the 78-column line tests —
  in a 77-column window every "line" silently becomes a
  wrap-plus-double-scroll, and the table measures something else.

For the record, the first full three-way SYNC run (A1200/030,
AmigaOS 3.2, 23.7.26): CCON 1.2.2 **18.46s**, stock CON: **74.16s**,
ViNCEd **111.68s** — and ViNCEd's sync-*off* total was 0.18s, which
is the whole honesty argument in two numbers.

Small-workload rows (`insdel-line`, `insdel-char`) fit easily
inside a deferring console's write-behind buffer, so their sync-off
timings swing with flush timing (0.3 measured identical work at
anywhere from 0.00 to 4.9 s; 0.4's auto-scale and barriers narrow it,
and `~` marks what is left). Use `SYNC` for those rows.

## Making the comparison fair

Every result records what makes runs comparable — check these lines
match before comparing:

- **window** — the text grid (the probe); 79 columns or more for the
  line tests.
- **screen** — size, depth and mode: more bitplanes is more blitting
  for everyone.
- **font** — cell size changes the grid (MicroKnight/8 gives 77×29 in a
  640×246 window; a 7-pixel font gives 91 columns).
- **busy** — tasks ready to run at the start; a busy Workbench steals
  from whoever is measured second.
- **machine** and **handler** — what ran, as the system reports it.
  Nothing here probes the hardware: the CPU is exec's AttnFlags, so on
  an accelerator or an emulator it is what the OS was told.

Rows under 0.1 s are flagged `?` (only with a small fixed `SCALE`;
auto-scale avoids them).

## Building

Written in [Amiga E](https://en.wikipedia.org/wiki/E_(programming_language)),
compiled with the E-VO compiler:

```
evo conbench.e
```

(On Linux: `ecompile conbench.e conbench`, the E-VO compiler under
vamos.) Runs on AmigaOS 2.0 and up.

A prebuilt binary is included.

## History

- **0.1** (23.7.26) — nine tests, written to measure CCON against
  CON: and ViNCEd; found CCON 11.6× slower than stock and started
  the ccon 1.2.2 performance campaign. Lived in `ccon/tests/` then.
- **0.2** — suite doubled, six new tests, and the window probe made
  to work: answers read from `Input()` (they never arrived on
  `Output()`), then the reply parser done right on the third try —
  3.2-family replies append pixel fields after cols, a CSI
  introducer must not count as a field; a field exists only where
  digits were seen. Result files from this arc are stamped 2.0–2.2,
  before the renumbering to house style.
- **0.3** — each test announces itself in the window (the blank-by-
  design tests no longer look like a hang), and conbench moved out
  of ccon's test drawer into a tool of its own.
- **0.4** (25.10.26) — the audit's fixes (`docs/audit.md`): EClock
  timing, auto-scale, an untimed barrier before every test, Ctrl-C,
  best and median with a spread mark, the check column, the setup
  recorded, a geometric mean, CSV and BASE, scroll-nl in big writes,
  clear-page and cursor-pos sized to the window, no divide by zero in a
  two-row window. Totals are not comparable with 0.3's.

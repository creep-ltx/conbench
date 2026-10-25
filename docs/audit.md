# conbench 0.3 - audit (2026-10-25)

**Status: every item in Bad and Meh is done in conbench 0.4 (2026-10-25)** except the one
that is a note, not a fault (CCON knowing sync-line's shape). Verified in FS-UAE 3.2.1 in CCON
1.3.1b3 and the stock CON:: all checks ok, auto-scale sensible (its first try scaled scroll-nl
125x on CCON because the trial had no barrier - fixed), Ctrl-C reports what was done, BASE ratios
and the geometric mean shown; the setup lines read right on Workbench 2.05 / 68000 too (A600). **The new tests are in 0.4 too** (the user chose all of the first group plus the full-screen,
responsiveness and robustness ones; CPU-left, key latency, resize and session replay left out):
sgr-styles, tabs, latin1, short-lines, scroll-cmd, cursor-hide, query-cursor, mode-switch,
garbage. Found while testing them: auto-scale needs a second, doubling step on the first real
rep (a deferring console took garbage in 0.017 s, then drew it at 29 KB/s), and E-VO's Mod is
wrong for divisors over 65535 (a 86 s row showed 21 bytes/s for 746) - rateof() avoids Mod.
First results in FS-UAE 3.2.1 (68020, 640x256x2): the stock CON: draws latin1 at 746 bytes/s,
3.4x slower than plain ASCII lines; CCON switches raw mode at 275/s against stock's 1012/s.
**Later, the user's idea:** a WhichAmiga-style machine section (CPU, chipset, board, expansion
cards) - only from what the system already knows (exec, expansion.library's ConfigDev list,
graphics' ChipRevBits), never by poking hardware: WhichAmiga's probes crash a PiStorm or a 060.


A read of `conbench.e` (706 lines, `$VER: conbench 0.3 (23.7.26)`), the README and the Aminet
readme, plus what the CCON work of October 2026 measured with it. Marks: *verified* (seen
running), *read* (from the source), *proposed* (an idea, not tried).

## Great

- **It knows what it cannot see, and says so.** A console answers a Write before it draws;
  the README's *Honesty* section, the `SYNC` barrier and the `sync-line` row exist because of
  that, and the ViNCEd example (0.18 s without SYNC, 111.68 s with it) makes the point in two
  numbers. Few benchmarks on any platform are this candid. *read*
- **Pairs of tests that isolate one cost each.** `plain-lines` vs `block-4k` (same bytes, same
  line breaks, different packet counts) separates per-packet cost from drawing; `block-32k`
  catches big-write slow paths; `bytewise` is nearly pure packet round trip; `scroll-nl` is the
  scroll path without glyphs; `sgr-perchar` is run-batching's worst case. The design is right.
  *read*
- **The window probe, done the way `dir` does it** (ask on Output, read the answer from Input
  in raw mode, give up after half a second a byte), and the warning when the window is
  narrower than the 78-column lines - the trap that once cost the CCON campaign a day. *read*
- **No disk I/O near the stopwatch:** results built in memory, the file opened only after the
  last test; a redirected stdout is refused (it would time the filesystem). *read*
- **Best of REPS** per test, and a `?` flag under half a second. *read*
- It has done real work: it found CCON 11.6x slower than CON:, then measured every fix, and on
  2026-10-25 showed CCON 1.3.1b2 costs nothing against 1.3.1b1 (18.10 s / 18.12 s). *verified*

## Good

- Varied filler (not one repeated glyph), so a console cannot win by batching identical cells.
- Each test starts from a cleared screen and default colours, and names itself in the window
  (the blank-by-design tests no longer look like a hang).
- `vt-frame` sizes itself to the probed window.
- Comments explain *why*, including the three probe parsers and what convicted each.

## Meh

- **1/50 s timing** (DateStamp ticks). Everything else follows from this: tests must run long,
  hence `SCALE`, hence the `?` flags. timer.device's `ReadEClock` gives about 1.4 us on every
  Amiga since 2.0. *read*
- **The default workload is far too small for a fast Amiga.** On the A1200 (PiStorm, 3.2.3)
  every row came back `?` at SCALE 1 - the whole suite took 0.82 s - and SCALE 20 was needed.
  The user has to discover that and guess a number. *verified 2026-10-25*
- **TOTAL is a plain sum of seconds**, so the slowest rows decide it (bytewise and sgr-colour
  were 7 of 18 s on the A1200) and a console that is great at what people do most can lose on a
  row nobody uses. A total is useful, but not as the only summary. *read*
- **Best-of only:** no spread is reported, so a noisy run and a steady one look the same. *read*
- **"Making the comparison fair" is a manual checklist** (window size, screen depth, font,
  nothing else running) when conbench could record most of it itself - the window, its
  screen, depth, mode and font are all reachable from the console's DISK_INFO window
  pointer. *read*
- **Comparing runs is by eye:** results append as text tables; there is no machine-readable
  form and no "this run against that one" view. *read*
- **scroll-nl's comment says "in one big write"; the code writes 10 bytes at a time** (1200
  packets at SCALE 1), so packet cost leaks into the "pure scroll" row. *read*
- **clear-page writes 20 lines a page whatever the window** - in a window under 21 rows each
  "page" also scrolls; in a tall window it is not a screenful. *read*
- **cursor-pos uses rows 1-20 and columns 1-60 regardless of the window** (clamped in a small
  one, a corner of a big one). *read*
- The version appears three times by hand (`$VER`, the report line, the header comment) and
  the header still lists "CCON:, CON: and ViNCEd" as if it were CCON's test. *read*
- The console under test can recognise the benchmark's shape: CCON jumps its scroll when
  WAIT_CHAR barriers come every few lines, which is exactly `sync-line`. It is also a real
  idiom (a progress loop polling for a key), so this is a note, not a fault. *read (CCON source)*

## Bad

- **No Ctrl-C.** Nothing checks for a break; at SCALE 20 on a slow console the suite runs for
  minutes and only a reset or closing the window stops it. *read*
- **A deferring console's work leaks into the next test when SYNC is off.** The clear, banner
  and stopwatch start come straight after the previous test's last Write; whatever the
  console still has to draw from that test (or from the clear) is drawn on the next test's
  clock. Rows are not independent without SYNC - one more reason the plain numbers mislead.
  An untimed barrier (WaitForChar) before every `DateStamp(t0)` fixes it for free. *read*
- **insdel-char divides by zero in a 2-row window:** `Mod(i, fr - 2)` with fr = 2 (the probe
  answered rows = 2). A guru, in a corner case. *read*
- **Nothing checks that the console drew what it was sent.** A console that drops output, or
  stops parsing a sequence half-way, is simply "fast". *read*
- **Overflow at large SCALE:** bytes/s is `bytes * 50 / ticks` in 32 bits; block-32k at SCALE
  700 passes 2^31 and prints nonsense. Unlikely, but SCALE is user input. *read*

## Suggestions for conbench itself

1. **timer.device EClock timing** (ReadEClock): microseconds instead of 20 ms, the `?` flags
   mostly gone, no SCALE needed for honest small tests.
2. **Auto-scale:** run each test once, then repeat it until it takes at least ~1 s (or a
   time budget); report bytes/s, which no longer depends on SCALE. Keep SCALE as an override.
3. **A barrier before every stopwatch start** (WaitForChar, untimed), so tests are independent
   with SYNC off too.
4. **Ctrl-C** between tests and every few hundred writes; the partial table is still written.
5. **Record the setup in the file:** OS and console versions (the handler's `$VER` via the
   DOS device entry), CPU (AttnFlags), the window's screen mode, depth and size, the font name
   and size, chip/fast memory, and whether Workbench backdrop/patterns are on. The "fair
   comparison" checklist becomes a list of facts in every result.
6. **A summary that suits comparisons:** keep TOTAL, add the geometric mean of bytes/s (no
   single row dominates) and, given a baseline file, a ratio per row (`1.3.1b2 vs 1.3.1b1:
   1.00x, 0.98x, ...`).
7. **Spread:** report min and median of the REPS (or min/max), and flag rows whose reps
   disagree by more than ~10%.
8. **CSV output** (`CSV` switch or a second file), one row per test, for spreadsheets and for a
   compare script on the PC.
9. **Correctness probes, cheap:** after the tests whose end state is known (wrap-long,
   cursor-pos, erase-eol, insdel-*), ask for the cursor position (CSI 6n, answered on Input like
   the size probe) and check it is where it must be. A console that drops or misparses output
   then fails visibly instead of winning.
10. **Run one test or a group:** `TEST plain-lines,vt-frame` / `GROUP scroll` - campaigns
    measure one path over and over, and the full suite is minutes at the right scale.
11. Small fixes: scroll-nl in big writes (or rename it and add the big-write form);
    clear-page and cursor-pos sized to the probed window; guard fr <= 2; 64-bit-safe rate
    maths; one version string.

## New tests - what a console does that conbench does not time yet

Everything below is something real programs send to an Amiga console. Grouped by what it
exercises; the first group matters most.

**Everyday output the suite misses**

- `sgr-styles`: bold, italic, underline, inverse, and background colours (40-47) with
  foreground changes - `ls --color`, Ed's marked block and every prompt use these; today only
  foreground 30-37 is timed. *(CCON draws bold and styles on separate paths.)*
- `tabs`: lines with TAB stops (`List` output, Makefiles) - TAB expansion is its own path.
- `latin1`: text with accented letters and other bytes 160-255 (a Swedish directory listing),
  and a variant with bytes 128-159 that must be dropped or shown - glyph lookup beyond ASCII.
- `backspace-overprint`: text with BS and CR overstrikes (old `more`/`man` bold, spinners).
- `short-lines`: many lines of 1-10 characters (a `List` of names, `echo` in a script) - per-line
  cost dominates instead of per-glyph.
- `prompt-cycle`: the shell's own shape - a prompt, a short command echo, a few lines of
  output, again - cheap, and what a user actually waits for.

**Full-screen programs**

- `scroll-region`: CSI S / CSI T (scroll up/down n lines) - what pagers and editors use
  instead of newline at the bottom.
- `page-size`: CSI t / u (set page length/width) and output inside a reduced page - Ed and
  some installers use them.
- `cursor-visibility`: CSI 0 p / CSI p (cursor off/on) around a repaint, the way editors
  hide the cursor while drawing.
- `alt-screen` (consoles that have it, CCON): `?47h` ... page ... `?47l` - More's bracket; the
  save and restore of the whole screen is the cost.
- `vt-diff`: a repaint that changes only a few cells per row (an editor moving one line) - a
  console with a model can skip unchanged cells; one without cannot.

**Round trips (latency, not throughput)**

- `query-cpr`: CSI 6n and read the answer, n times - `ls`, More and csh ask this at every
  prompt; the round trip is what a user feels.
- `query-bounds`: CSI 0 SPACE q, the same for the window-size report (`dir`'s columns).
- `raw-echo`: switch to raw (SetMode 1), write a key-sized byte and read nothing, back to
  cooked (SetMode 0) - the mode switch itself is a cost every full-screen program pays twice.
- `info-packet`: ACTION_DISK_INFO round trips (what Ed, More and csh do to find the window).

**Robustness under load** (not timed against each other, but worth a pass/fail line)

- `huge-write`: one 256 KB Write (a `Type` of a big file through a pipe).
- `garbage`: random bytes 0-255, including broken and unterminated escape sequences - the
  console must not hang, crash or leave the next test in a strange state.
- `long-line`: one 4000-character line without a newline (a minified file) - wrap and any
  per-line buffer limit.

**What a user feels besides speed** (needs a second task; an "extended" mode)

- `cpu-left`: a low-priority task counting in a loop during each test; the count tells how
  much of the machine the console leaves for everything else (a console that is fast by
  burning the CPU at priority 5 shows here).
- `key-latency`: a helper task injects a key with input.device and conbench times how long until
  it can Read it - typing feel, the one thing a user notices before throughput.
- `resize`: change the window size in the middle of output (ChangeWindowBox on the window from
  DISK_INFO) - re-wrap and redraw cost; CCON re-flows its scrollback here.

## Suggested order

1. The Bad list: Ctrl-C, the untimed barrier before each test, the 2-row guard, safe rate maths
   (one small version, 0.4).
2. EClock timing + auto-scale - after this the numbers are honest and the user never needs
   SCALE.
3. Setup recording + CSV + a geometric mean and baseline ratios - comparisons become facts.
4. New tests, first group first (styles, tabs, Latin-1, short lines, prompt cycle), then the
   round trips (`query-cpr` most of all), then full-screen, then robustness.
5. Correctness probes (CSI 6n after known end states).
6. The extended mode (cpu-left, key-latency, resize).

New tests change TOTAL, so a run of 0.4 is not comparable with 0.3 (as 0.2 was not with 0.1):
say so in the file header, as 0.2 did.

Audit by reading the source and from conbench runs on the A1200 and in FS-UAE on 2026-10-24/25.

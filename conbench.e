/* conbench.e -- a console speed benchmark for AmigaOS consoles
   (CON:, CCON:, KingCON, ViNCEd, CTerm, ...)
   usage: conbench NAME <label> [TO file] [REPS n] [SCALE n] [MINTIME n]
                   [SYNC] [CSV file] [BASE file] [FORCE]

   VERSION 0.4 (25.10.26) - the audit's fixes (docs/audit.md). Against
   0.3, which matters when comparing result files:
   - timed with timer.device's EClock (about 1.4 us) instead of 1/50 s
     DateStamp ticks; times are shown in milliseconds
   - AUTO-SCALE: without SCALE, each test is run once to see what it
     costs and then sized to take at least MINTIME seconds (default 1),
     so a fast Amiga gets honest numbers without guessing a SCALE. The
     table shows bytes per second, which does not depend on the size.
   - an untimed barrier (WaitForChar) before EVERY stopwatch start, so a
     console that draws behind its replies cannot leave one test's work
     on the next test's clock (0.3 did, with SYNC off)
   - Ctrl-C stops it between writes; the tests done so far are reported
   - best AND median of the REPS, '~' when they disagree by over 10%
   - a CHECK column: after the tests whose end state is known, the
     console is asked where its cursor is (CSI 6n, outside the timing);
     a console that lost or misparsed output shows BAD, not "fast"
   - the setup is recorded, not left to a checklist: the console's
     handler and version, its DISK_INFO type, the window's screen, depth,
     mode and font, the CPU as exec reports it, exec's version, free
     memory and how many other tasks were ready to run. All read from
     system structures - nothing probes the hardware.
   - a geometric mean of the rates beside TOTAL (no one row decides it)
   - CSV file: the run as one line per test, appended; BASE file: an
     earlier CSV whose rates are put beside this run's as ratios
   - scroll-nl writes its newlines in 1000-byte writes (0.3 sent 10 at a
     time, so packet cost leaked into the "pure scroll" row); clear-page
     and cursor-pos are sized to the probed window; insdel-char cannot
     divide by zero in a two-row window; rates cannot overflow
   - nine NEW tests: sgr-styles (bold/italic/underline/inverse and
     background colours), tabs, latin1 (letters 160-255), short-lines,
     scroll-cmd (CSI S/T), cursor-hide (CSI 0 SPACE p around a frame),
     query-cursor (CSI 6n round trips), mode-switch (SetMode on/off) and
     garbage (random bytes the console must survive)
   0.4 totals are NOT comparable with 0.3 ones (other sizes, scroll-nl,
   the new tests).

   Run it INSIDE the console you want to measure - it writes its test
   output to stdout, so the console under test is whichever one the
   shell is running in. Results APPEND to the file (RAM:conbench.txt by
   default), so several consoles' runs can be read side by side.

   What a console benchmark can and cannot see: README.md, "Honesty".
*/

MODULE 'dos/dos', 'dos/dosextens', 'dos/datetime', 'exec/nodes', 'exec/ports',
       'exec/execbase', 'exec/memory', 'devices/timer', 'timer', 'graphics/gfx',
       'graphics/displayinfo', 'intuition/intuition', 'intuition/screens',
       'graphics/rastport'

CONST BLKSZ=4096,           -> the big-write buffer
      BLKLINES=51,          -> whole 79-byte lines inside one 4K block
      BLKBYTES=4029,        -> BLKLINES * 79, the block test's write size
      BLKREPS=16,           -> so block-4k moves BLKREPS*BLKBYTES bytes
      NLINES=816,           -> = BLKREPS * BLKLINES: plain-lines moves the
                            -> SAME bytes and the same line count
      BIGSZ=32768,          -> the block-32k buffer...
      BIGBYTES=32706,       -> ...and its write size: 414 whole lines
      BIGREPS=2,
      LONGLINE=300,         -> the auto-wrap test's line length
      NLSZ=1000,            -> scroll-nl's newlines per write
      RESSZ=16384,          -> the results text accumulated in memory
      NTESTS=24,
      LATSZ=237,            -> latin1: three 79-byte lines of letters 160-255
      GSZ=4096,             -> garbage: the random bytes, made once (fixed seed)
      MAXREPS=20,
      MAXSCALE=2000,        -> auto-scale never goes past this
      SHORTMS=100           -> a result under this is flagged '?'

DEF out,                    -> the console under test (stdout)
    blk:PTR TO CHAR,        -> BLKSZ of printable filler
    big:PTR TO CHAR,        -> BIGSZ of the same filler
    longl:PTR TO CHAR,      -> LONGLINE printable chars, no newline
    nls:PTR TO CHAR,        -> NLSZ newlines
    lat:PTR TO CHAR,        -> LATSZ: latin1's lines
    gar:PTR TO CHAR,        -> GSZ: garbage's bytes
    qfail=FALSE,            -> query-cursor: the console stopped answering
    res:PTR TO CHAR,        -> results text, written at the very end
    scratch[400]:STRING,
    ms[480]:ARRAY OF LONG,  -> NTESTS * MAXREPS times, milliseconds
    sc[NTESTS]:ARRAY OF LONG,   -> each test's scale
    bytes[NTESTS]:ARRAY OF LONG,
    chk[NTESTS]:ARRAY OF LONG,  -> 0 not checked, 1 ok, 2 BAD, 3 no answer
    chkwant[NTESTS]:ARRAY OF LONG, chkgot[NTESTS]:ARRAY OF LONG,
    baserate[NTESTS]:ARRAY OF LONG,
    done=0,                 -> tests with at least one rep, for the report
    cnt[NTESTS]:ARRAY OF LONG,  -> reps finished per test
    sel[NTESTS]:ARRAY OF LONG,  -> TEST: the tests to run
    testsel=NIL:PTR TO CHAR,    -> TEST's list as given, NIL = all
    broke=FALSE,            -> Ctrl-C seen
    dosync=FALSE,
    cols=0, rows=0,
    probeskip=FALSE,        -> stdin not interactive: no probes at all
    tio=NIL:PTR TO timerequest,
    freqk=0,                -> EClock ticks per millisecond
    con[1200]:STRING        -> the setup lines, built before the tests

PROC main() HANDLE
  DEF rdargs=NIL, argarray:PTR TO LONG, label:PTR TO CHAR, fname:PTR TO CHAR,
      reps, scale, p:PTR TO LONG, i, r, t, k, fh, ds:datestamp, mintime,
      csvname:PTR TO CHAR, basename:PTR TO CHAR, ev[2]:ARRAY OF LONG

  argarray := [0,0,0,0,0,0,0,0,0,0]:LONG
  rdargs := ReadArgs('NAME/A,TO/K,REPS/K/N,SCALE/K/N,MINTIME/K/N,SYNC/S,CSV/K,BASE/K,FORCE/S,TEST/K',
                     argarray, NIL)
  IF rdargs = NIL
    Throw("ARG", 'usage: conbench NAME <label> [TO file] [REPS n] [SCALE n] [MINTIME n] [SYNC] [CSV file] [BASE file] [FORCE]')
  ENDIF
  label := argarray[0]
  fname := argarray[1]
  IF fname = NIL THEN fname := 'RAM:conbench.txt'
  reps := 3
  IF argarray[2]
    p := argarray[2]
    reps := p[0]
  ENDIF
  scale := 0                    -> 0 = auto-scale
  IF argarray[3]
    p := argarray[3]
    scale := Max(1, p[0])
  ENDIF
  mintime := 1
  IF argarray[4]
    p := argarray[4]
    mintime := Max(1, p[0])
  ENDIF
  IF reps < 1 THEN reps := 1
  IF reps > MAXREPS THEN reps := MAXREPS
  dosync := argarray[5]
  csvname := argarray[6]
  basename := argarray[7]

  out := Output()
  -> a redirected run would time the FILESYSTEM, not the console, and
  -> produce a confident nonsense number; FORCE is for smoke tests only
  IF (IsInteractive(out) = 0) AND (argarray[8] = 0)
    Throw("ARG", 'stdout is not a console - run conbench IN the console you want to measure (FORCE to override)')
  ENDIF

  -> the EClock: timer.device's free-running counter, ~0.7-1.4 us a tick
  tio := New(SIZEOF timerequest)
  IF tio = NIL THEN Throw("MEM", 'out of memory')
  IF OpenDevice('timer.device', UNIT_ECLOCK, tio, 0) <> 0
    Dispose(tio)
    tio := NIL
    Throw("ARG", 'cannot open timer.device')
  ENDIF
  timerbase := Long(tio + 20)        -> io_Device
  freqk := Div(ReadEClock(ev) + 500, 1000)
  IF freqk < 1 THEN freqk := 1

  blk := New(BLKSZ + 4)
  big := New(BIGSZ + 4)
  longl := New(LONGLINE + 4)
  nls := New(NLSZ + 4)
  lat := New(LATSZ + 4)
  gar := New(GSZ + 4)
  res := String(RESSZ)
  IF (blk = NIL) OR (big = NIL) OR (longl = NIL) OR (nls = NIL) OR (res = NIL) OR
     (lat = NIL) OR (gar = NIL)
    Throw("MEM", 'out of memory')
  ENDIF
  fillbuffers()

  -> the window size and the setup, asked ONCE before any timing, so
  -> whatever they cost is paid outside every measured region
  winsize()
  setup()
  FOR i := 0 TO NTESTS - 1
    sc[i] := IF scale THEN scale ELSE 1
    bytes[i] := 0
    chk[i] := 0
    cnt[i] := 0
    baserate[i] := 0
  ENDFOR
  IF basename THEN readbase(basename)
  -> TEST name,name,...: only these (a campaign measures one path over
  -> and over); the others are skipped and not reported
  testsel := argarray[9]
  FOR i := 0 TO NTESTS - 1 DO sel[i] := IF testsel THEN inlist(testsel, testname(i)) ELSE TRUE

  -> AUTO-SCALE: one run of each test at scale 1 says what it costs;
  -> it is then sized to take at least MINTIME seconds
  IF scale = 0
    FOR i := 0 TO NTESTS - 1 DO IF (broke = FALSE) AND sel[i] THEN sc[i] := calibrate(i, Mul(mintime, 1000))
  ENDIF

  -> the suite, REPS times; a test's row is complete when all its reps ran
  FOR r := 0 TO reps - 1
    FOR i := 0 TO NTESTS - 1
      IF (broke = FALSE) AND sel[i]
        t := timetest(i, sc[i])
        -> auto-scale's second step, on the first rep: the trial ended
        -> with a barrier, these reps do not (without SYNC) - a console
        -> that accepts bytes ahead of drawing them takes a small workload
        -> in no time (garbage: 0.017 s). Grow it until the work no
        -> longer fits its buffer and has to be drawn on the clock.
        IF (scale = 0) AND (r = 0)
          k := 0
          -> doubled, not multiplied: the time is near nothing until the
          -> buffer is full and then grows with the work, so a big step
          -> overshoots (ten times made garbage take 10 s) and scaling back
          -> lands inside the buffer again (0.017 s)
          WHILE (t < Mul(mintime, 500)) AND (sc[i] < MAXSCALE) AND (k < 7) AND (broke = FALSE)
            sc[i] := Min(MAXSCALE, Mul(sc[i], 2))
            t := timetest(i, sc[i])
            k++
          ENDWHILE
        ENDIF
        ms[Mul(i, MAXREPS) + r] := t
        IF broke = FALSE
          cnt[i] := r + 1
          IF r = 0 THEN done++
          IF r = (reps - 1) THEN check(i)   -> outside the timing, last rep
        ENDIF
      ENDIF
    ENDFOR
  ENDFOR

  -> back to a clean screen before the summary
  Write(out, [27,"[","0","m",12]:CHAR, 5)

  DateStamp(ds)
  report(label, reps, scale, mintime, ds)

  -> the files are opened and written only NOW: no disk I/O of ours
  -> happened between or during the timed regions
  appendto(fname, res)
  IF csvname THEN writecsv(csvname, label, ds)
  WriteF('\nconbench: appended to \s\n', fname)

EXCEPT DO
  IF exception = "DOS"
    PrintFault(exceptioninfo, 'conbench')
  ELSEIF exception <> 0
    WriteF('conbench: \s\n', exceptioninfo)
  ENDIF
  IF tio
    CloseDevice(tio)
    Dispose(tio)
  ENDIF
  IF rdargs THEN FreeArgs(rdargs)
ENDPROC

-> is word one of the comma-separated names in list (any case)?
PROC inlist(list:PTR TO CHAR, word:PTR TO CHAR)
  DEF i=0, j, n
  n := StrLen(word)
  WHILE list[i]
    j := i
    WHILE (list[j] <> 0) AND (list[j] <> ",") DO j++
    IF (j - i = n) AND (StrCmp(list + i, word, n) OR icmpn(list + i, word, n)) THEN RETURN TRUE
    i := IF list[j] THEN j + 1 ELSE j
  ENDWHILE
ENDPROC FALSE

PROC icmpn(a:PTR TO CHAR, b:PTR TO CHAR, n)
  DEF i, x, y
  FOR i := 0 TO n - 1
    x := a[i]
    y := b[i]
    IF (x >= "A") AND (x <= "Z") THEN x := x + 32
    IF (y >= "A") AND (y <= "Z") THEN y := y + 32
    IF x <> y THEN RETURN FALSE
  ENDFOR
ENDPROC TRUE

PROC appendto(name, text:PTR TO CHAR)
  DEF fh
  fh := Open(name, MODE_READWRITE)
  IF fh
    Seek(fh, 0, OFFSET_END)
  ELSE
    fh := Open(name, MODE_NEWFILE)
  ENDIF
  IF fh = NIL THEN Throw("DOS", IoErr())
  Write(fh, text, StrLen(text))
  Close(fh)
ENDPROC

-> printable filler. Deliberately VARIED, not one repeated character:
-> a console that batches identical glyphs is not doing a listing's work
PROC fillbuffers()
  DEF i, c
  c := 33
  FOR i := 0 TO BLKSZ - 1
    IF Mod(i, 79) = 78          -> 78-char lines, as the line test
      blk[i] := 10
    ELSE
      blk[i] := c
      c := c + 1
      IF c > 126 THEN c := 33
    ENDIF
  ENDFOR
  blk[BLKSZ] := 0
  c := 33
  FOR i := 0 TO BIGSZ - 1
    IF Mod(i, 79) = 78
      big[i] := 10
    ELSE
      big[i] := c
      c := c + 1
      IF c > 126 THEN c := 33
    ENDIF
  ENDFOR
  big[BIGSZ] := 0
  c := 33
  FOR i := 0 TO LONGLINE - 1
    longl[i] := c
    c := c + 1
    IF c > 126 THEN c := 33
  ENDFOR
  longl[LONGLINE] := 0
  FOR i := 0 TO NLSZ - 1 DO nls[i] := 10
  nls[NLSZ] := 0
  -> latin1: 78 letters from 160-255 (a Swedish listing's a-ring, a- and
  -> o-umlaut among them), a LF, three lines that differ
  c := 160
  FOR i := 0 TO LATSZ - 1
    IF Mod(i, 79) = 78
      lat[i] := 10
    ELSE
      lat[i] := c
      c := c + 1
      IF c > 255 THEN c := 160
    ENDIF
  ENDFOR
  lat[LATSZ] := 0
  -> garbage: the same "random" bytes every run (a fixed seed), mostly
  -> text and the insides of escape sequences. Left out on purpose: the
  -> bytes that would change the console for the REST of the run or ask
  -> it things - final bytes h l (modes), t u (page size), { } (input
  -> events), n q (reports), > (private: the window's background pen) -
  -> and BEL, whose flashes help nobody. The run resets the console after
  -> (garbagereset), so what is left is what a console must survive.
  c := 12345
  FOR i := 0 TO GSZ - 1
    c := Mul(c, 1103515245) + 12345
    gar[i] := garbagebyte(Shr(c, 16) AND $7FFF)
  ENDFOR
  gar[GSZ] := 0
ENDPROC

PROC garbagebyte(r)
  DEF k, b, ins:PTR TO CHAR, ctl:PTR TO CHAR
  ins := '0123456789;; ?['
  ctl := [8, 9, 10, 13, 12, 11, 14, 15, 0, 1]:CHAR
  k := Mod(r, 100)
  IF k < 50
    b := 32 + Mod(Shr(r, 7), 95)      -> printable ASCII
  ELSEIF k < 60
    b := 27                           -> ESC
  ELSEIF k < 65
    b := $9B                          -> CSI
  ELSEIF k < 78
    b := ins[Mod(Shr(r, 7), 15)]      -> sequence insides
  ELSEIF k < 86
    b := 128 + Mod(Shr(r, 7), 128)    -> 8-bit bytes
  ELSE
    b := ctl[Mod(Shr(r, 7), 10)]      -> controls
  ENDIF
  IF (b = "h") OR (b = "l") OR (b = "t") OR (b = "u") OR (b = "{") OR
     (b = "}") OR (b = "n") OR (b = "q") OR (b = ">") OR (b = 7) THEN b := "x"
ENDPROC b

-> after garbage: the console back to normal (reset, plain colours, the
-> normal character set, cursor on, a clear page) and anything it put in
-> the input queue read away, so the next test - and the shell after the
-> run - start clean
PROC garbagereset()
  DEF in, b[4]:ARRAY OF CHAR, k=0
  Write(out, [27,"c",27,"[","0","m",15,27,"[",32,"p",12]:CHAR, 12)
  IF probeskip THEN RETURN
  in := Input()
  SetMode(in, 1)
  WHILE (WaitForChar(in, 20000) <> 0) AND (k < 4096)
    Read(in, b, 1)
    k++
  ENDWHILE
  SetMode(in, 0)
ENDPROC

-> ---------------------------------------------------------------
-> timing: the EClock, read before and after; the low longword's
-> difference is exact for anything under ~50 minutes
-> ---------------------------------------------------------------
PROC nowticks()
  DEF ev[2]:ARRAY OF LONG
  ReadEClock(ev)
ENDPROC ev[1]

PROC brk()
  IF broke THEN RETURN TRUE
  IF CheckSignal(SIGBREAKF_CTRL_C) THEN broke := TRUE
ENDPROC broke

-> AUTO-SCALE: the scale that makes test id take target ms. Measured
-> WITH an end barrier even when SYNC is off: a console that answers
-> before it draws made 0.4's first try look almost free and scaled
-> scroll-nl 125 times (30 s). Scaled up tenfold until the trial is long
-> enough to extrapolate from (0.2 s), then to the target.
PROC calibrate(id, target)
  DEF s=1, t
  LOOP
    t := timetest(id, s, TRUE)
    IF broke THEN RETURN s
    IF (t >= 200) OR (s >= MAXSCALE) THEN RETURN Min(MAXSCALE, Max(1, Div(Mul(s, target) + t - 1, Max(t, 1))))
    s := Min(MAXSCALE, Mul(s, 10))
  ENDLOOP
ENDPROC

-> one test at one scale; milliseconds. bar: end with a barrier even
-> without SYNC (calibration)
PROC timetest(id, scale, bar=FALSE)
  DEF t0, t1, n, ban[48]:STRING
  -> every test starts from a cleared screen and default colours
  Write(out, [27,"[","0","m",12]:CHAR, 5)
  -> name the test IN the window, before the stopwatch (scroll-nl and
  -> insdel-line draw nothing visible by design)
  StringF(ban, 'conbench: \s ...\n', testname(id))
  Write(out, ban, StrLen(ban))
  -> 0.4: the untimed barrier. A console that answers writes before it
  -> draws must finish the clear, the banner and anything left from the
  -> previous test BEFORE the clock starts, or it lands on this test
  WaitForChar(out, 0)
  IF brk() THEN RETURN 0
  t0 := nowticks()
  n := dotest(id, scale)
  IF dosync OR bar THEN WaitForChar(out, 0)
  t1 := nowticks()
  bytes[id] := n
  IF id = 23 THEN garbagereset()    -> untimed, after every garbage run
ENDPROC Div(t1 - t0, freqk)

-> ---------------------------------------------------------------
-> the workloads. Each returns the number of bytes it wrote; each
-> stops at a Ctrl-C (checked every 256 writes).
-> ---------------------------------------------------------------
PROC dotest(id, scale)
  DEF i, j, n=0, s[80]:STRING, k, line2[280]:STRING, fr, fc, tmp[24]:STRING

  -> the window-sized tests use the PROBED window; a console that did
  -> not answer gets the classic 77x24
  fr := IF rows > 1 THEN rows ELSE 24
  fc := IF cols > 1 THEN cols ELSE 77
  IF fr > 50 THEN fr := 50
  IF fc > 79 THEN fc := 79

  SELECT id
  CASE 0
    -> PLAIN: 78-char lines, ONE Write() per line - ordinary command
    -> output, the number most people mean by "is my console fast"
    FOR i := 1 TO Mul(NLINES, scale)
      Write(out, blk, 79)
      n := n + 79
      IF (i AND 255) = 0 THEN IF brk() THEN RETURN n
    ENDFOR
  CASE 1
    -> BLOCK: the SAME bytes and line breaks in 4K writes - against
    -> PLAIN, per-packet cost apart from drawing cost
    FOR i := 1 TO Mul(BLKREPS, scale)
      Write(out, blk, BLKBYTES)
      n := n + BLKBYTES
      IF brk() THEN RETURN n
    ENDFOR
  CASE 2
    -> BLOCK-32K: 414 lines in ONE Write() - big-write slow paths
    FOR i := 1 TO Mul(BIGREPS, scale)
      Write(out, big, BIGBYTES)
      n := n + BIGBYTES
      IF brk() THEN RETURN n
    ENDFOR
  CASE 3
    -> BYTEWISE: one Write() per character - unbuffered output, More's
    -> echo; nearly pure packet round trip
    FOR i := 1 TO Mul(2400, scale)
      Write(out, blk + Mod(i, 78), 1)
      n := n + 1
      IF (i AND 255) = 0 THEN IF brk() THEN RETURN n
    ENDFOR
  CASE 4
    -> SCROLL: bare newlines in 1000-byte writes - the scroll path with
    -> no glyphs and few packets (0.3 wrote 10 at a time)
    FOR i := 1 TO Mul(12, scale)
      Write(out, nls, NLSZ)
      n := n + NLSZ
      IF brk() THEN RETURN n
    ENDFOR
  CASE 5
    -> WRAP: 300-character lines without newlines, wrapped by the console
    FOR i := 1 TO Mul(140, scale)
      Write(out, longl, LONGLINE)
      n := n + LONGLINE
      IF (i AND 63) = 0 THEN IF brk() THEN RETURN n
    ENDFOR
  CASE 6
    -> SGR: colour changes several times per line - the `ls` colours case
    FOR i := 1 TO Mul(300, scale)
      FOR k := 0 TO 7
        StringF(s, '\c[3\dm12345678', 27, k)
        Write(out, s, StrLen(s))
        n := n + StrLen(s)
      ENDFOR
      Write(out, '\n', 1)
      n := n + 1
      IF (i AND 31) = 0 THEN IF brk() THEN RETURN n
    ENDFOR
  CASE 7
    -> SGR-PERCHAR: a colour change before EVERY glyph - run length one
    FOR i := 1 TO Mul(60, scale)
      StrCopy(line2, '')
      FOR k := 0 TO 39
        StringF(tmp, '\c[3\dm\c', 27, Mod(k, 8), 65 + Mod(k + i, 26))
        StrAdd(line2, tmp)
      ENDFOR
      StrAdd(line2, '\n')
      Write(out, line2, StrLen(line2))
      n := n + StrLen(line2)
      IF (i AND 31) = 0 THEN IF brk() THEN RETURN n
    ENDFOR
  CASE 8
    -> CURSOR: absolute positioning then a short string, as an editor
    -> draws - sized to the window (0.4)
    FOR i := 1 TO Mul(700, scale)
      StringF(s, '\c[\d;\dH-cursor-', 27, Mod(i, fr) + 1, Mod(i, Max(1, fc - 8)) + 1)
      Write(out, s, StrLen(s))
      n := n + StrLen(s)
      IF (i AND 255) = 0 THEN IF brk() THEN RETURN n
    ENDFOR
  CASE 9
    -> VT-FRAME: a full-screen repaint - position, erase to EOL, a row of
    -> text, for every row; one Write() per row, then the next frame
    FOR i := 1 TO Mul(15, scale)
      FOR j := 1 TO fr
        StringF(s, '\c[\d;1H\c[K', 27, j, 27)
        k := StrLen(s)
        CopyMem(longl + Mod(Mul(j, 7) + i, 240), s + k, Min(60, fc - 1))
        SetStr(s, k + Min(60, fc - 1))
        Write(out, s, StrLen(s))
        n := n + StrLen(s)
      ENDFOR
      IF brk() THEN RETURN n
    ENDFOR
  CASE 10
    -> INSDEL-LINE: insert a line mid-screen, delete it again - region
    -> blits no console can defer past
    StringF(tmp, '\c[\d;1H', 27, Max(1, Div(fr, 2)))
    FOR i := 1 TO Mul(100, scale)
      StrCopy(line2, tmp)
      StringF(s, '\c[L\c[M', 27, 27)
      StrAdd(line2, s)
      Write(out, line2, StrLen(line2))
      n := n + StrLen(line2)
      IF (i AND 63) = 0 THEN IF brk() THEN RETURN n
    ENDFOR
  CASE 11
    -> INSDEL-CHAR: CSI @/P open and close a mid-line gap (0.4: a window
    -> of two rows no longer divides by zero)
    FOR i := 1 TO Mul(200, scale)
      StringF(line2, '\c[\d;5Habcdefgh\c[\d;5H\c[4@\c[4P', 27,
              Mod(i, Max(1, fr - 2)) + 2, 27, Mod(i, Max(1, fr - 2)) + 2, 27, 27)
      Write(out, line2, StrLen(line2))
      n := n + StrLen(line2)
      IF (i AND 63) = 0 THEN IF brk() THEN RETURN n
    ENDFOR
  CASE 12
    -> CLEAR: form feed then a screenful - the More page flip (0.4: a
    -> screenful of THIS window, rows less one, so it does not scroll)
    FOR i := 1 TO Mul(40, scale)
      Write(out, [12]:CHAR, 1)
      n := n + 1
      FOR j := 1 TO Max(1, fr - 1)
        Write(out, blk, 79)
        n := n + 79
      ENDFOR
      IF brk() THEN RETURN n
    ENDFOR
  CASE 13
    -> ERASE-EOL: CR, text, erase to end of line - the progress counter
    FOR i := 1 TO Mul(700, scale)
      StringF(s, '\cworking: \d%\c[K', 13, Mod(i, 100), 27)
      Write(out, s, StrLen(s))
      n := n + StrLen(s)
      IF (i AND 255) = 0 THEN IF brk() THEN RETURN n
    ENDFOR
    Write(out, '\n', 1)
    n := n + 1
  CASE 14
    -> SYNC-LINE: plain-lines with a WaitForChar barrier after EVERY
    -> line - the closest the packet interface gets to an honest
    -> per-line figure; the gap to plain-lines IS the deferral
    FOR i := 1 TO Mul(200, scale)
      Write(out, blk, 79)
      WaitForChar(out, 0)
      n := n + 79
      IF (i AND 63) = 0 THEN IF brk() THEN RETURN n
    ENDFOR
  CASE 15
    -> SGR-STYLES: bold, italic, underline, inverse and their "off" codes,
    -> with a text AND a background colour, 8 pieces a line - ls colours,
    -> prompts, Ed's marked block; sgr-colour only times text colours
    FOR i := 1 TO Mul(300, scale)
      StrCopy(line2, '')
      FOR k := 0 TO 7
        StringF(tmp, '\c[\d;3\d;4\dmabcdefgh', 27,
                ListItem([1, 3, 4, 7, 22, 23, 24, 27], k), k, Mod(k + 3, 8))
        StrAdd(line2, tmp)
      ENDFOR
      StringF(tmp, '\c[0m\n', 27)
      StrAdd(line2, tmp)
      Write(out, line2, StrLen(line2))
      n := n + StrLen(line2)
      IF (i AND 31) = 0 THEN IF brk() THEN RETURN n
    ENDFOR
  CASE 16
    -> TABS: List-like lines with three TABs - TAB expansion is its own path
    FOR i := 1 TO Mul(700, scale)
      StringF(s, 'file\d\t\d\t----rwed\t24-Oct-26\n', Mod(i, 1000), Mul(Mod(i, 97), 131))
      Write(out, s, StrLen(s))
      n := n + StrLen(s)
      IF (i AND 255) = 0 THEN IF brk() THEN RETURN n
    ENDFOR
  CASE 17
    -> LATIN1: plain-lines' shape with letters 160-255 - glyphs past ASCII
    FOR i := 1 TO Mul(NLINES, scale)
      Write(out, lat + Mul(Mod(i, 3), 79), 79)
      n := n + 79
      IF (i AND 255) = 0 THEN IF brk() THEN RETURN n
    ENDFOR
  CASE 18
    -> SHORT-LINES: a few characters a line, one Write() each - a list of
    -> names, echo in a script: the cost per line, not per glyph
    FOR i := 1 TO Mul(2000, scale)
      StringF(s, 'f\d\n', Mod(i, 1000))
      Write(out, s, StrLen(s))
      n := n + StrLen(s)
      IF (i AND 255) = 0 THEN IF brk() THEN RETURN n
    ENDFOR
  CASE 19
    -> SCROLL-CMD: a screenful, then CSI 2 S / CSI 2 T (scroll up/down two
    -> lines) in pairs - how pagers and editors move a page
    Write(out, [27,"[","H"]:CHAR, 3)
    FOR j := 1 TO Max(1, fr - 2)
      Write(out, blk, 79)
      n := n + 79
    ENDFOR
    FOR i := 1 TO Mul(150, scale)
      Write(out, [27,"[","2","S",27,"[","2","T"]:CHAR, 8)
      n := n + 8
      IF (i AND 63) = 0 THEN IF brk() THEN RETURN n
    ENDFOR
  CASE 20
    -> CURSOR-HIDE: vt-frame with the cursor off (CSI 0 SPACE p) while a
    -> frame is drawn and on again after, as editors draw
    FOR i := 1 TO Mul(15, scale)
      Write(out, [27,"[","0",32,"p"]:CHAR, 5)
      n := n + 5
      FOR j := 1 TO fr
        StringF(s, '\c[\d;1H\c[K', 27, j, 27)
        k := StrLen(s)
        CopyMem(longl + Mod(Mul(j, 7) + i, 240), s + k, Min(60, fc - 1))
        SetStr(s, k + Min(60, fc - 1))
        Write(out, s, StrLen(s))
        n := n + StrLen(s)
      ENDFOR
      Write(out, [27,"[",32,"p"]:CHAR, 4)
      n := n + 4
      IF brk() THEN RETURN n
    ENDFOR
  CASE 21
    -> QUERY-CURSOR: CSI 6n and its answer read back, again and again -
    -> ls, More and csh ask at every prompt. "bytes" counts round trips.
    n := querycursor(Mul(200, scale))
  CASE 22
    -> MODE-SWITCH: raw mode on, off - what every full-screen program pays
    -> starting and quitting. "bytes" counts switches (on and off = one).
    IF probeskip = FALSE
      j := Input()
      FOR i := 1 TO Mul(200, scale)
        SetMode(j, 1)
        SetMode(j, 0)
        n++
        IF (i AND 63) = 0 THEN IF brk() THEN RETURN n
      ENDFOR
    ENDIF
  CASE 23
    -> GARBAGE: random bytes and broken sequences, 512 bytes a write. The
    -> console must survive it: the check asks it where its cursor is
    -> after the reset (garbagereset), which a hung console cannot answer.
    FOR i := 1 TO Mul(4, scale)
      FOR j := 0 TO 7
        Write(out, gar + Mul(j, 512), 512)
        n := n + 512
      ENDFOR
      IF brk() THEN RETURN n
    ENDFOR
  ENDSELECT
ENDPROC n

-> query-cursor's loop: raw on Input once, CSI 6n, read to the final R;
-> a console that does not answer within half a second ends the test
PROC querycursor(count)
  DEF in, i, n=0, c[4]:ARRAY OF CHAR, ok
  qfail := FALSE
  IF probeskip THEN RETURN 0
  in := Input()
  SetMode(in, 1)
  FOR i := 1 TO count
    Write(out, [27,"[","6","n"]:CHAR, 4)
    ok := FALSE
    WHILE ok = FALSE
      IF WaitForChar(in, 500000) = 0
        qfail := TRUE
        ok := TRUE
      ELSEIF Read(in, c, 1) <> 1
        qfail := TRUE
        ok := TRUE
      ELSEIF c[0] = "R"
        ok := TRUE
      ENDIF
    ENDWHILE
    EXIT qfail
    n++
    IF (i AND 63) = 0 THEN IF brk() THEN i := count
  ENDFOR
  SetMode(in, 0)
ENDPROC n

PROC testname(id)
  DEF s
  SELECT id
  CASE 0;  s := 'plain-lines'
  CASE 1;  s := 'block-4k'
  CASE 2;  s := 'block-32k'
  CASE 3;  s := 'bytewise'
  CASE 4;  s := 'scroll-nl'
  CASE 5;  s := 'wrap-long'
  CASE 6;  s := 'sgr-colour'
  CASE 7;  s := 'sgr-perchar'
  CASE 8;  s := 'cursor-pos'
  CASE 9;  s := 'vt-frame'
  CASE 10; s := 'insdel-line'
  CASE 11; s := 'insdel-char'
  CASE 12; s := 'clear-page'
  CASE 13; s := 'erase-eol'
  CASE 14; s := 'sync-line'
  CASE 15; s := 'sgr-styles'
  CASE 16; s := 'tabs'
  CASE 17; s := 'latin1'
  CASE 18; s := 'short-lines'
  CASE 19; s := 'scroll-cmd'
  CASE 20; s := 'cursor-hide'
  CASE 21; s := 'query-cursor'
  CASE 22; s := 'mode-switch'
  CASE 23; s := 'garbage'
  DEFAULT; s := '?'
  ENDSELECT
ENDPROC s

-> ---------------------------------------------------------------
-> asking the console: a report request on Output(), the answer read
-> from Input() in raw mode (the dir idiom), every byte gated by a
-> half-second WaitForChar so a console that does not answer cannot
-> hang us. Returns the reply's length (0 = no answer), stops at the
-> final byte fin.
-> ---------------------------------------------------------------
PROC ask(req:PTR TO CHAR, reqlen, fin, b:PTR TO CHAR, max)
  DEF n=0, in, done=FALSE, got=FALSE
  in := Input()
  SetMode(in, 1)
  Write(out, req, reqlen)
  WHILE (done = FALSE) AND (n < max)
    IF WaitForChar(in, 500000) = 0
      done := TRUE
    ELSEIF Read(in, b + n, 1) <> 1
      done := TRUE
    ELSE
      n := n + 1
      IF b[n - 1] = fin
        done := TRUE
        got := TRUE
      ENDIF
    ENDIF
  ENDWHILE
  SetMode(in, 0)
ENDPROC IF got THEN n ELSE 0

-> the numeric fields of a reply, in order: a field exists only where
-> digits were seen (intro bytes and the final byte close nothing)
PROC fields(b:PTR TO CHAR, n, f:PTR TO LONG, maxf)
  DEF i, c, v=0, dig=FALSE, k=0
  FOR i := 0 TO n - 1
    c := b[i]
    IF (c >= "0") AND (c <= "9")
      v := Mul(v, 10) + (c - 48)
      dig := TRUE
    ELSE
      IF dig AND (k < maxf)
        f[k] := v
        k++
      ENDIF
      v := 0
      dig := FALSE
    ENDIF
  ENDFOR
ENDPROC k

-> the window size: CSI 0 SPACE q, answered CSI 1;1;rows;cols[;...] SPACE r
PROC winsize()
  DEF b[80]:ARRAY OF CHAR, n, f[6]:ARRAY OF LONG, k
  IF IsInteractive(Input()) = 0   -> redirected stdin: no probes, and the
    probeskip := TRUE             -> report says SKIPPED, not unanswered
    RETURN
  ENDIF
  n := ask([27,"[","0",32,"q"]:CHAR, 5, "r", b, 78)
  IF n = 0 THEN RETURN
  k := fields(b, n, f, 6)
  IF k >= 4
    rows := f[2]
    cols := f[3]
  ELSEIF k = 3
    rows := f[2]
  ENDIF
ENDPROC

-> the cursor: CSI 6n, answered CSI row;col R. Returns row*1000+col.
PROC cursorat()
  DEF b[40]:ARRAY OF CHAR, n, f[4]:ARRAY OF LONG
  n := ask([27,"[","6","n"]:CHAR, 4, "R", b, 38)
  IF n = 0 THEN RETURN 0
  IF fields(b, n, f, 4) < 2 THEN RETURN 0
ENDPROC Mul(f[0], 1000) + f[1]

-> ---------------------------------------------------------------
-> the CHECK column (0.4): tests whose end state is known are asked
-> where the cursor is. Only in a window the tests fit (the probe
-> answered, at most 50 rows - the tests size themselves to 50).
-> ---------------------------------------------------------------
PROC check(id)
  DEF fr, fc, want=0, n, got, loose=FALSE
  IF probeskip OR (rows < 4) OR (cols < 20) OR (rows > 50) THEN RETURN
  fr := rows
  fc := Min(cols, 79)
  n := sc[id]
  SELECT id
  CASE 0;  loose := TRUE    -> the scrolling tests end in column 1 on some
  CASE 1;  loose := TRUE    -> row of the window: a console that scrolls in
  CASE 2;  loose := TRUE    -> jumps (CCON) leaves the cursor above the
  CASE 4;  loose := TRUE    -> bottom row until it settles, so the row is
  CASE 6;  loose := TRUE    -> not checked
  CASE 7;  loose := TRUE
  CASE 14; loose := TRUE
  CASE 15; loose := TRUE
  CASE 16; loose := TRUE
  CASE 17; loose := TRUE
  CASE 18; loose := TRUE
  CASE 20; want := Mul(fr, 1000) + 1 + Min(60, fc - 1)   -> as vt-frame
  CASE 21
    chk[id] := IF qfail THEN 3 ELSE 1   -> every question answered
    RETURN
  CASE 23; loose := TRUE    -> after the reset: it answers at all
  CASE 8
    -> the last '-cursor-' was written at row/col of i = 700*scale
    want := Mul(Mod(Mul(700, n), fr) + 1, 1000) + Mod(Mul(700, n), Max(1, fc - 8)) + 1 + 8
  CASE 9;  want := Mul(fr, 1000) + 1 + Min(60, fc - 1)
  CASE 11; want := Mul(Mod(Mul(200, n), Max(1, fr - 2)) + 2, 1000) + 5
  CASE 12
    -> a page from row 1, a LF a line - only where the 78-char lines fit
    IF cols < 79 THEN RETURN
    want := Mul(Max(1, fr - 1) + 1, 1000) + 1
  CASE 13; want := 3001                -> the banner is row 1; row 2, then LF
  DEFAULT; RETURN                      -> bytewise, wrap-long, insdel-line:
  ENDSELECT                            -> end states consoles may differ on
  got := cursorat()
  chkwant[id] := want
  chkgot[id] := got
  IF got = 0
    chk[id] := 3
  ELSEIF loose
    chkwant[id] := 1        -> shown as "row 0;1" = any row, column 1
    chk[id] := IF (Mod(got, 1000) = 1) AND (Div(got, 1000) >= 1) AND
                  (Div(got, 1000) <= fr) THEN 1 ELSE 2
  ELSEIF got = want
    chk[id] := 1
  ELSE
    chk[id] := 2
  ENDIF
ENDPROC

-> ---------------------------------------------------------------
-> the setup (0.4), read from system structures only - nothing here
-> probes hardware: exec's AttnFlags and version, AvailMem, the DOS
-> device list, and the console's own DISK_INFO answer (whose
-> id_VolumeNode is the console's window, the stock convention)
-> ---------------------------------------------------------------
PROC setup()
  DEF fh:PTR TO filehandle, port:PTR TO mp, task:PTR TO ln, id:PTR TO infodata,
      win:PTR TO window, scr:PTR TO screen, font, af, cpu:PTR TO CHAR,
      dl:PTR TO doslist, hname[120]:STRING, hver[80]:STRING, dtype[8]:STRING,
      dev[40]:STRING, ni[56]:ARRAY OF CHAR, mid, depth, bm, rdy=0, n:PTR TO ln,
      i, c, s:PTR TO CHAR, mname[40]:STRING, fname[40]:STRING, line[120]:STRING
  StrCopy(con, '')
  -> the console's handler: the task behind Output()'s port, and the DOS
  -> device whose task that port is (its handler file, if it has one)
  fh := Shl(out, 2)
  port := fh.type
  StrCopy(dev, '?')
  StrCopy(hname, '')
  StrCopy(hver, '')
  IF port
    task := port.sigtask
    IF task THEN IF task.name THEN StrCopy(dev, task.name)
    dl := LockDosList(LDF_DEVICES OR LDF_READ)
    WHILE dl := NextDosEntry(dl, LDF_DEVICES)
      IF dl.task = port
        s := Shl(dl.handler, 2)
        IF s
          c := s[0]
          FOR i := 0 TO Min(c, 110) - 1 DO hname[i] := s[i + 1]
          SetStr(hname, Min(c, 110))
        ENDIF
      ENDIF
    ENDWHILE
    UnLockDosList(LDF_DEVICES OR LDF_READ)
  ENDIF
  IF StrLen(hname) THEN fileversion(hname, hver)
  StringF(line, 'handler : \s (\s\s\s)\n', dev,
          IF StrLen(hname) THEN hname ELSE 'in ROM or built in',
          IF StrLen(hver) THEN ', ' ELSE '', hver)
  StrAdd(con, line)
  -> its DISK_INFO: the type it claims and its window
  win := NIL
  StrCopy(dtype, '?')
  id := New(SIZEOF infodata)
  IF id AND (port <> NIL)
    IF DoPkt(port, ACTION_DISK_INFO, Shr(id, 2), 0, 0, 0, 0)
      FOR i := 0 TO 3
        c := Shr(id.disktype, Mul(3 - i, 8)) AND 255
        dtype[i] := IF (c >= 32) AND (c < 127) THEN c ELSE "."
      ENDFOR
      SetStr(dtype, 4)
      win := id.volumenode
    ENDIF
  ENDIF
  IF id THEN Dispose(id)
  StrCopy(mname, '?')
  StrCopy(fname, '?')
  IF win
    scr := win.wscreen
    IF scr
      bm := Long(scr + 84 + 4)        -> sc_RastPort (84) -> rp_BitMap
      -> GetBitMapAttr is graphics V39 (3.0); conbench runs from 2.0, where
      -> the planar BitMap's own Depth byte (offset 5) is the answer
      IF Int(gfxbase + 20) >= 39
        depth := GetBitMapAttr(bm, BMA_DEPTH)
      ELSE
        depth := Char(bm + 5)
      ENDIF
      mid := GetVPModeID(scr + 44)    -> sc_ViewPort (44): an embedded member
      IF GetDisplayInfoData(NIL, ni, 56, DTAG_NAME, mid) > 16
        StrCopy(mname, ni + 16)
      ENDIF
      StringF(line, 'screen  : \dx\d, depth \d, mode \s ($\h)\n',
              scr.width, scr.height, depth, mname, mid)
      StrAdd(con, line)
    ENDIF
    font := win.rport.font
    IF font
      s := Long(font + 10)            -> tf_Message.mn_Node.ln_Name
      IF s THEN StrCopy(fname, s)
      StringF(line, 'font    : \s \d (\dx\d)\n', fname, Int(font + 20),
              Int(font + 24), Int(font + 20))
      StrAdd(con, line)
    ENDIF
  ENDIF
  StringF(line, 'type    : DISK_INFO says "\s"\s\n', dtype,
          IF win THEN '' ELSE ' (no window given)')
  StrAdd(con, line)
  -> the machine as exec reports it (on an accelerator or an emulator this
  -> is what the OS was told, not a hardware probe)
  af := Int(execbase + 296)
  cpu := '68000'
  IF af AND 1 THEN cpu := '68010'
  IF af AND 2 THEN cpu := '68020'
  IF af AND 4 THEN cpu := '68030'
  IF af AND 8 THEN cpu := '68040'
  IF af AND $80 THEN cpu := '68060'
  StringF(line, 'machine : \s\s, exec \d.\d, chip \d KB / fast \d KB free\n', cpu,
          IF af AND $70 THEN '+FPU' ELSE '', Int(execbase + 20), Int(execbase + 22),
          Shr(AvailMem(MEMF_CHIP), 10), Shr(AvailMem(MEMF_FAST), 10))
  StrAdd(con, line)
  -> other tasks ready to run now: anything above 0 competes with the test
  Forbid()
  n := Long(execbase + 406)
  WHILE n.succ
    rdy++
    n := n.succ
  ENDWHILE
  Permit()
  StringF(line, 'busy    : \d other task\s ready to run at the start\n', rdy,
          IF rdy = 1 THEN '' ELSE 's')
  StrAdd(con, line)
ENDPROC

-> the $VER string in a handler file, if the file can be read (a ROM
-> handler has a name but no file)
PROC fileversion(name:PTR TO CHAR, dst:PTR TO CHAR)
  DEF fh, buf:PTR TO CHAR, n, i, j, total=0, keep=0
  buf := New(4100)
  IF buf = NIL THEN RETURN
  fh := Open(name, MODE_OLDFILE)
  IF fh
    -> read in 4K pieces; the last 5 bytes of a piece are kept in front of
    -> the next so a "$VER:" across the seam is still found
    WHILE (n := Read(fh, buf + keep, 4096 - keep)) > 0
      n := n + keep
      FOR i := 0 TO n - 6
        IF (buf[i] = "$") AND (buf[i + 1] = "V") AND (buf[i + 2] = "E") AND
           (buf[i + 3] = "R") AND (buf[i + 4] = ":")
          i := i + 5
          WHILE (i < n) AND (buf[i] = " ") DO i++
          j := 0
          WHILE (i < n) AND (buf[i] >= 32) AND (j < 70)
            dst[j] := buf[i]
            i++
            j++
          ENDWHILE
          SetStr(dst, j)
          Close(fh)
          Dispose(buf)
          RETURN
        ENDIF
      ENDFOR
      CopyMem(buf + n - 5, buf, 5)
      keep := 5
      total := total + n
      EXIT total > 400000
    ENDWHILE
    Close(fh)
  ENDIF
  Dispose(buf)
ENDPROC

-> ---------------------------------------------------------------
-> BASE: an earlier run's CSV - the last rate seen per test name
-> ---------------------------------------------------------------
PROC readbase(name:PTR TO CHAR)
  DEF fh, line[200]:STRING, f[8]:ARRAY OF LONG, i, k, p, q
  fh := Open(name, MODE_OLDFILE)
  IF fh = NIL
    WriteF('conbench: no BASE file \s\n', name)
    RETURN
  ENDIF
  WHILE Fgets(fh, line, 198)
    SetStr(line, StrLen(line))
    -> label,test,scale,bytes,best_ms,median_ms,bytes_per_s,check
    p := InStr(line, ',')
    IF p > 0
      q := InStr(line, ',', p + 1)
      IF q > p
        FOR i := 0 TO NTESTS - 1
          k := StrLen(testname(i))
          IF (q - p - 1 = k) AND StrCmp(line + p + 1, testname(i), k)
            -> the rate is the 7th field
            k := q
            FOR p := 1 TO 4 DO k := InStr(line, ',', k + 1)
            IF k > 0 THEN baserate[i] := Val(line + k + 1)
          ENDIF
        ENDFOR
      ENDIF
    ENDIF
  ENDWHILE
  Close(fh)
ENDPROC

PROC writecsv(name:PTR TO CHAR, label:PTR TO CHAR, ds:PTR TO datestamp)
  DEF t:PTR TO CHAR, i, line[200]:STRING, b, m
  t := String(4096)
  IF t = NIL THEN RETURN
  FOR i := 0 TO NTESTS - 1
    IF cnt[i] > 0
      b := bestms(i)
      m := medianms(i)
      StringF(line, '\s,\s,\d,\d,\d,\d,\d,\s\n', label, testname(i), sc[i], bytes[i],
              b, m, rateof(bytes[i], b), chkword(i))
      StrAdd(t, line)
    ENDIF
  ENDFOR
  appendto(name, t)
  DisposeLink(t)
ENDPROC

-> ---------------------------------------------------------------
-> the numbers
-> ---------------------------------------------------------------
PROC bestms(id)
  DEF r, b=-1, v
  FOR r := 0 TO cnt[id] - 1
    v := ms[Mul(id, MAXREPS) + r]
    IF (b < 0) OR (v < b) THEN b := v
  ENDFOR
ENDPROC Max(b, 0)

PROC medianms(id)
  DEF a[MAXREPS]:ARRAY OF LONG, r, i, v
  FOR r := 0 TO cnt[id] - 1
    v := ms[Mul(id, MAXREPS) + r]
    i := r
    WHILE (i > 0) AND (a[i - 1] > v)
      a[i] := a[i - 1]
      i--
    ENDWHILE
    a[i] := v
  ENDFOR
ENDPROC IF cnt[id] > 0 THEN a[Div(cnt[id], 2)] ELSE 0

PROC worstms(id)
  DEF r, w=0
  FOR r := 0 TO cnt[id] - 1 DO w := Max(w, ms[Mul(id, MAXREPS) + r])
ENDPROC w

-> bytes per second from bytes and milliseconds, without overflow. No
-> Mod here: E-VO's Mod divides by the divisor's LOW WORD only, so a test
-> over 65.5 s (stock CON:'s latin1, 86 s) gave 21 bytes/s for 746
PROC rateof(b, t)
  DEF q
  IF t <= 0 THEN RETURN 0
  q := Div(b, t)
ENDPROC Mul(q, 1000) + Div(Mul(b - Mul(q, t), 1000), t)

PROC chkword(id)
  SELECT chk[id]
  CASE 1; RETURN 'ok'
  CASE 2; RETURN 'BAD'
  CASE 3; RETURN '?'
  ENDSELECT
ENDPROC '-'

-> log2 of x in 1/256ths (x >= 1): the integer part from the highest bit,
-> the fraction by repeated squaring of the normalised mantissa
PROC log2fix(x)
  DEF p=0, m, i, r
  IF x < 1 THEN RETURN 0
  m := x
  WHILE m > 1
    m := Shr(m, 1)
    p++
  ENDWHILE
  -> the mantissa as 1.14 fixed point in [16384, 32768)
  IF p > 14 THEN m := Shr(x, p - 14) ELSE m := Shl(x, 14 - p)
  r := Shl(p, 8)
  FOR i := 7 TO 0 STEP -1
    m := Shr(Mul(m, m), 14)
    IF m >= 32768
      m := Shr(m, 1)
      r := r OR Shl(1, i)
    ENDIF
  ENDFOR
ENDPROC r

-> the x with log2fix(x) closest to y, by bisection
PROC exp2fix(y)
  DEF lo=1, hi=$7FFFFFFF, mid
  WHILE lo < hi
    mid := lo + Shr(hi - lo, 1)
    IF log2fix(mid) < y THEN lo := mid + 1 ELSE hi := mid
  ENDWHILE
ENDPROC lo

PROC addres(s:PTR TO CHAR)
  IF (StrLen(res) + StrLen(s)) < (RESSZ - 2) THEN StrAdd(res, s)
ENDPROC

-> milliseconds as "s.mmm"
PROC fmtms(dst:PTR TO CHAR, t)
  DEF f
  f := Mod(t, 1000)
  StringF(dst, '\d.\s\s\d', Div(t, 1000), IF f < 100 THEN '0' ELSE '',
          IF f < 10 THEN '0' ELSE '', f)
ENDPROC

-> a ratio as "x.xx"
PROC fmtratio(dst:PTR TO CHAR, a, b)
  DEF h
  IF b <= 0
    StrCopy(dst, '')
    RETURN
  ENDIF
  -> hundredths. Full precision below 20 million (a * 100 fits 32 bits);
  -> only above that both are cut by 100 first. (0.4's first form cut
  -> them always and showed 1012/275 as 5.00, 158/125 as 1.00.)
  IF a < 20000000
    h := Div(Mul(a, 100), b)
  ELSE
    h := Div(Mul(Div(a, 100), 100), Max(Div(b, 100), 1))
  ENDIF
  StringF(dst, '\d.\s\d', Div(h, 100), IF Mod(h, 100) < 10 THEN '0' ELSE '', Mod(h, 100))
ENDPROC

vers: CHAR '$VER: conbench 0.4 (25.10.26) console speed benchmark', 0

PROC report(label:PTR TO CHAR, reps, scale, mintime, ds:PTR TO datestamp)
  DEF i, t, tot=0, totb=0, d[LEN_DATSTRING]:ARRAY OF CHAR,
      tm[LEN_DATSTRING]:ARRAY OF CHAR, sz[64]:STRING, dt:datetime,
      secs[16]:STRING, med[16]:STRING, nb[20]:STRING, nr[20]:STRING,
      sx[12]:STRING, rt[12]:STRING, flag:PTR TO CHAR, lg=0, nlg=0, lgb=0, nb2=0,
      b, ver[40]:STRING, nsel

  StrCopy(res, '')
  CopyMem(ds, dt, SIZEOF datestamp)
  dt.format := FORMAT_DOS
  dt.flags := 0
  dt.strday := NIL
  dt.strdate := d
  dt.strtime := tm
  d[0] := 0
  tm[0] := 0
  IF DateToStr(dt) = 0
    d[0] := "?"
    d[1] := 0
    tm[0] := "?"
    tm[1] := 0
  ENDIF
  IF cols > 0
    StringF(sz, '\dx\d', cols, rows)
  ELSEIF probeskip
    StrCopy(sz, '?x? (stdin not interactive - probe skipped)')
  ELSEIF rows > 0
    StringF(sz, '?x\d (partial answer - report a bug)', rows)
  ELSE
    StrCopy(sz, '?x? (console did not answer)')
  ENDIF
  -> the version once: from the $VER string ("conbench 0.4")
  StrCopy(ver, {vers} + 6, 12)

  addres('==========================================================\n')
  StringF(scratch, 'console : \s   (\s)\n', label, ver)
  addres(scratch)
  StringF(scratch, 'when    : \s \s\n', d, tm)
  addres(scratch)
  addres(con)
  StringF(scratch, 'window  : \s\n', sz)
  addres(scratch)
  IF (cols > 1) AND (cols < 79)
    StringF(scratch, 'WARNING : only \d cols - the 78-char line tests WRAP\n', cols)
    addres(scratch)
    addres('          (widen the window past 78 text columns to compare)\n')
  ENDIF
  IF scale
    StringF(scratch, 'run     : reps \d, scale \d, sync \s\n', reps, scale,
            IF dosync THEN 'ON' ELSE 'off')
  ELSE
    StringF(scratch, 'run     : reps \d, auto-scaled to \d s or more a test, sync \s\n',
            reps, mintime, IF dosync THEN 'ON' ELSE 'off')
  ENDIF
  addres(scratch)
  IF testsel
    StringF(scratch, 'tests   : only \s (TOTAL and the mean are not comparable with a full run)\n', testsel)
    addres(scratch)
  ENDIF
  IF broke
    nsel := 0
    FOR i := 0 TO NTESTS - 1 DO IF sel[i] THEN nsel++
    StringF(scratch, 'STOPPED : Ctrl-C after \d of \d tests\n', done, nsel)
    addres(scratch)
  ENDIF
  addres('  (secs = the best of the reps, median beside it; ~ = reps differ\n')
  addres('   by over 10%; ? = under 0.1 s; check = cursor where it must be)\n')
  addres('  (query-cursor and mode-switch count round trips in "bytes")\n')
  addres('\n')
  addres('  test          scale     bytes     secs   median    bytes/s check  vs base\n')
  addres('  ------------------------------------------------------------------------\n')

  FOR i := 0 TO NTESTS - 1
    IF cnt[i] > 0
      b := bestms(i)
      t := worstms(i)
      flag := ' '
      IF Mul(t - b, 10) > b THEN flag := '~'
      IF b < SHORTMS THEN flag := '?'
      fmtms(secs, b)
      fmtms(med, medianms(i))
      StringF(sx, '\d', sc[i])
      StringF(nb, '\d', bytes[i])
      StringF(nr, '\d', rateof(bytes[i], b))
      fmtratio(rt, rateof(bytes[i], b), baserate[i])
      StringF(scratch, '  \l\s[12]\r\s[6]\r\s[10]\r\s[9]\s\r\s[8]\r\s[11] \l\s[5] \r\s[7]\n',
              testname(i), sx, nb, secs, flag, med, nr, chkword(i), rt)
      addres(scratch)
      IF chk[i] = 2
        StringF(scratch, '      cursor at \d;\d, should be \d;\d\n', Div(chkgot[i], 1000),
                Mod(chkgot[i], 1000), Div(chkwant[i], 1000), Mod(chkwant[i], 1000))
        addres(scratch)
      ENDIF
      tot := tot + b
      totb := totb + bytes[i]
      IF rateof(bytes[i], b) > 0
        lg := lg + log2fix(rateof(bytes[i], b))
        nlg++
        IF baserate[i] > 0
          lgb := lgb + log2fix(baserate[i])
          nb2++
        ENDIF
      ENDIF
    ENDIF
  ENDFOR

  addres('  ------------------------------------------------------------------------\n')
  fmtms(secs, tot)
  StringF(nb, '\d', totb)
  StringF(nr, '\d', rateof(totb, tot))
  StringF(scratch, '  \l\s[12]      \r\s[10]\r\s[9]          \r\s[11]\n', 'TOTAL', nb, secs, nr)
  addres(scratch)
  IF nlg > 0
    StringF(nr, '\d', exp2fix(Div(lg, nlg)))
    StrCopy(rt, '')
    IF nb2 = nlg THEN fmtratio(rt, exp2fix(Div(lg, nlg)), exp2fix(Div(lgb, nb2)))
    StringF(scratch, '  \l\s[37]\r\s[11]       \r\s[7]\n', 'geometric mean of the rates', nr, rt)
    addres(scratch)
  ENDIF
  addres('\n')
  WriteF('\s', res)
ENDPROC

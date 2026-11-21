# Weekly blocks policy - backend package: what each file does and the order to run them

Everything runs in the Supabase SQL editor (the same place you ran earlier
scripts). Each file is one script: open it, copy the whole thing, paste, Run.
No terminal, no tools, no code deploy needed for this part.

The 4-week block uses the series' existing `ends_on` (end date). Lesson
generation already stops after that date, so a block is simply
[anchor day, anchor day + 27 days] - always exactly 4 weekly lessons.

## The files, in order

**1. bmc-backend-01-weekly-blocks-policy.sql** - run FIRST, any time before go-live.
Safe to run more than once; changes nothing students can see yet.
- Adds two counters to each recurring series: current consecutive no-shows,
  and when the count first hit 2 (the "flag" moment).
- Adds a small automatic counter-keeper: whenever a lesson is marked
  attended / no-show / unmarked, or cancelled, the series' count updates.
  Past lessons and their attendance are never modified.
- Adds `renew_series_block()`: the function the teacher app will call to
  renew a block. Only the series' own teacher can call it. It sets the next
  4-week end date (starting the day after the old block, or today if the
  block already lapsed), restores any lessons the step-4 cleanup had
  auto-cancelled inside the new block, and restarts lesson generation.
- Adds one line to the notification function: a "quiet mode" that only the
  step-4 cleanup uses (for its own run only). Normal notifications unchanged.
- Adds a marker on bookings (`block_auto_cancelled`) so step 4's cancellations
  can be told apart from any other cancellation and safely restored on renewal.

**2. bmc-backend-02-activation-backfill.sql** - run ONCE, on go-live day.
- EDIT THE DATE FIRST: one marked line near the top - set it to the actual
  go-live day.
- Every existing open-ended ("forever") weekly series gets its first block:
  end date = go-live day + 27 days. Series that already have an end date are
  left alone, and running it again never rewinds an end date.
- Cancels nothing; generation simply stops after the block end.
- The no-show counters start at 0 for everyone = fresh count from go-live.

**3. bmc-backend-03-conversion-preview.sql** - READ-ONLY, run after step 2.
- Some "forever" series already have lessons generated beyond their new block
  end. This lists, per series, how many and their date range. Changes nothing.

**4. bmc-backend-04-conversion-apply.sql** - ONLY after reviewing step 3's list.
- Cancels exactly those beyond-block future lessons and marks them as
  auto-cancelled. Runs in quiet mode, so students/teachers get NO cancellation
  notifications for these.
- Compare the number of cancelled rows it reports with step 3's total before
  letting it finish (the script is one transaction: if the count looks wrong,
  run `rollback;` instead of letting it commit).
- Past lessons and attendance are untouched. If the teacher later renews the
  block, any auto-cancelled lessons falling inside the new block come back.

## Apply order summary

1. File 01 - any time before go-live (safe to re-run).
2. File 02 - once, on go-live day (set the date first).
3. File 03 - right after 02; read the list.
4. File 04 - only if you're happy with what 03 listed.

## What was tested (local mock database, real Postgres engine - not live Supabase)

32/32 checks passed on @electric-sql/pglite (real Postgres running locally),
with the actual `_bmc_extend_series` body from your backend export and the
four SQL files run verbatim:

- Open series generates lessons up to the horizon; fixed-count series behave
  exactly as today (future lessons = stays active; fully past = ends itself).
- Backfill sets the block end only on open-ended series; fixed series and
  already-ended series untouched; re-running never rewinds an end date.
- Preview lists exactly the beyond-block lessons and changes nothing.
- Apply cancels exactly those lessons, marked; sends zero notifications in
  quiet mode - and the same cancellation WITHOUT quiet mode does notify
  (proving the guard is what suppresses them, not a broken notification path).
- Generation adds nothing beyond the block end.
- Renewal: refused for anyone but the series' teacher (and when signed out);
  new block = day after old block end, +27 days, exactly 4 weekly lessons;
  auto-cancelled lessons inside the new block are restored; lessons beyond it
  stay cancelled; markers cleared on restored lessons.
- No-show counter: builds 1-2-3 on consecutive marked no-shows; flag timestamp
  set when it first reaches 2; attended or unmarked lessons break the run;
  cancelling the newest no-show recomputes correctly; past attendance rows
  are never modified.
- Files 01 and 02 are safe to run twice.

Not tested: anything against live Supabase, RLS policies as deployed, or the
real app's calls into `renew_series_block` (the frontend prototype does not
call it yet - wiring that is the next step after these are reviewed).

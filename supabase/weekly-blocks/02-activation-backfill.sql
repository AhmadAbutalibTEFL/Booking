-- ============================================================================
-- BookMyClass - Weekly blocks policy, part 2 of 4 (run ONCE, on go-live day)
-- Plain words: every existing open-ended ("forever") weekly series gets its
-- first 4-week block starting on go-live day. No lessons are cancelled here;
-- lesson generation simply stops after the block end until renewed.
-- !! SET THE DATE on the next line to the actual go-live day before running !!
-- ============================================================================
with params as (select date '2026-11-24' as go_live)   -- <-- SET GO-LIVE DATE HERE
update public.booking_series s
   set ends_on = (select go_live from params) + 27     -- 28-day block, inclusive
  from params
 where s.recurrence_mode = 'open'
   and s.status = 'active'
   and s.ends_on is null;          -- only true "forever" series; never rewinds a set end date
-- Series that already have an end date keep it.
-- The no-show count starts at 0 automatically (column default) = fresh count
-- from go-live, as approved.

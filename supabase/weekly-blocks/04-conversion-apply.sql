-- ============================================================================
-- BookMyClass - Weekly blocks policy, part 4 of 4 (ONLY after reviewing part 3)
-- Plain words: cancels the future lessons listed by part 3 - lessons that were
-- generated beyond a series' new block end. Past lessons and attendance are
-- untouched. Students and teachers do NOT get a cancellation notification for
-- these (part 1 installed the quiet-mode guard; it applies to this script's
-- own transaction only).
-- ============================================================================
begin;
set local bmc.skip_notify = '1';
update public.bookings b
   set status = 'cancelled', block_auto_cancelled = true
  from public.booking_series s
 where s.id = b.series_id
   and b.status = 'confirmed'
   and s.recurrence_mode = 'open'
   and s.status = 'active'
   and s.ends_on is not null
   and (b.starts_at at time zone s.timezone)::date > s.ends_on;
-- Re-check the row count against part 3's total before committing.
commit;

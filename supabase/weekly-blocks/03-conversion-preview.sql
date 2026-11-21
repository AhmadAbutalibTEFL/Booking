-- ============================================================================
-- BookMyClass - Weekly blocks policy, part 3 of 4 (READ-ONLY preview)
-- Plain words: some existing series may already have future lessons generated
-- beyond their new block end. This script ONLY COUNTS AND LISTS them, so you
-- can see exactly what part 4 would cancel. It changes nothing.
-- ============================================================================
select s.id as series_id, s.student_name, count(*) as lessons_beyond_block,
       min((b.starts_at at time zone s.timezone)::date) as first_beyond,
       max((b.starts_at at time zone s.timezone)::date) as last_beyond
  from public.bookings b
  join public.booking_series s on s.id = b.series_id
 where b.status = 'confirmed'
   and s.recurrence_mode = 'open'
   and s.status = 'active'
   and s.ends_on is not null
   and (b.starts_at at time zone s.timezone)::date > s.ends_on
 group by s.id, s.student_name
 order by s.student_name;

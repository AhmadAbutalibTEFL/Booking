-- Follow-up to 20261125140000_lesson_credits.sql (already merged and applied).
-- Rule change (Ahmed, 2026-11-25): only a lesson marked 'attended' uses a credit.
-- A no-show is treated as postponed: it neither uses a credit nor counts as booked.
-- Replaces two functions only; no table changes. Safe to run more than once.

create or replace function public.bmc_credit_lessons(p_teacher uuid)
returns table(booking_id uuid, student_key text, starts_at timestamptz, attendance text, rn integer, total integer)
language sql stable security definer set search_path to 'public','pg_temp' as $$
  with tz as (select coalesce((select timezone from public.teachers where id=p_teacher),'UTC') z),
  led as (
    select student_key, sum(lessons)::int total, min(paid_on) first_paid
    from public.credit_ledger where teacher_id=p_teacher group by 1),
  bk as (
    select b.id, public.bmc_student_key(b.contact_phone,b.student_name) k, b.starts_at, b.attendance
    from public.bookings b
    where b.teacher_id=p_teacher and b.status='confirmed' and (b.attendance is null or b.attendance = 'attended')),
  c as (
    select bk.id, bk.k, bk.starts_at, bk.attendance, led.total,
           row_number() over (partition by bk.k order by bk.starts_at) rn
    from bk join led on led.student_key=bk.k, tz
    where bk.starts_at >= (led.first_paid::timestamp at time zone tz.z))
  select id, k, starts_at, attendance, rn::int, total from c
$$;


revoke all on function public.bmc_credit_lessons(uuid) from public, anon, authenticated;

create or replace function public.get_teacher_credits()
returns jsonb language plpgsql stable security definer set search_path to 'public','pg_temp' as $$
declare u uuid:=auth.uid(); res jsonb;
begin
  if u is null then raise exception 'login required'; end if;
  if not exists(select 1 from public.teachers where id=u) then raise exception 'not a teacher'; end if;
  with led as (
    select student_key, sum(lessons)::int total, max(created_at) last_added,
           (array_agg(student_name order by created_at desc))[1] nm,
           (array_agg(contact_phone order by created_at desc) filter (where contact_phone is not null))[1] ph
    from public.credit_ledger where teacher_id=u group by 1),
  l as (select * from public.bmc_credit_lessons(u)),
  agg as (
    select student_key,
      count(*) filter (where attendance = 'attended')::int used,
      count(*) filter (where attendance is null)::int pending,
      count(*) filter (where rn>total)::int uncovered
    from l group by 1),
  rows as (
    select led.student_key k, led.nm, led.ph, led.total, coalesce(agg.used,0) used, coalesce(agg.pending,0) pending,
           coalesce(agg.uncovered,0) uncovered, led.last_added
    from led left join agg on agg.student_key=led.student_key),
  cand as (
    select distinct on (public.bmc_student_key(contact_phone,student_name))
      public.bmc_student_key(contact_phone,student_name) k, student_name nm, contact_phone ph
    from public.bookings where teacher_id=u and status='confirmed'
    order by public.bmc_student_key(contact_phone,student_name), starts_at desc)
  select jsonb_build_object(
    'students', coalesce((select jsonb_agg(jsonb_build_object('key',k,'name',nm,'phone',ph,'total',total,'used',used,'pending',pending,
        'remaining',total-used,'free',total-used-pending,'uncovered',uncovered,'last_added',last_added) order by (total-used-pending), nm) from rows),'[]'::jsonb),
    'known', coalesce((select jsonb_agg(jsonb_build_object('key',k,'name',nm,'phone',ph) order by nm) from cand where k not in (select k from rows)),'[]'::jsonb),
    'uncovered_ids', coalesce((select jsonb_agg(booking_id) from l where rn>total),'[]'::jsonb)
  ) into res;
  return res;
end $$;


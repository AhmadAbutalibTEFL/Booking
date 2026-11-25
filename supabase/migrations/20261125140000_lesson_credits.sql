-- Lesson credits (new tables and functions only; nothing existing is changed).
-- A student is "tracked" only after the teacher adds credits for them. Untracked students see no change.
-- Balance = lessons added - lessons taught. A lesson counts as taught when the teacher marked it
-- 'attended' or 'no_show' (rule: a no-show uses a credit; teacher_cancelled and cancelled never do).
-- Lessons are counted from the start of the first "paid on" date. Booking is never blocked.

create table if not exists public.credit_ledger (
  id uuid primary key default gen_random_uuid(),
  teacher_id uuid not null references public.teachers(id) on delete cascade,
  student_key text not null,
  student_name text not null check (char_length(student_name) between 1 and 120),
  contact_phone text check (contact_phone is null or char_length(contact_phone) <= 32),
  lessons integer not null check (lessons between -500 and 500 and lessons <> 0),
  paid_on date not null default current_date,
  note text check (note is null or char_length(note) <= 500),
  created_at timestamptz not null default now()
);
create index if not exists credit_ledger_teacher_key on public.credit_ledger(teacher_id, student_key);
alter table public.credit_ledger enable row level security;
revoke all on public.credit_ledger from anon, authenticated;

create or replace function public.bmc_student_key(p_phone text, p_name text)
returns text language sql immutable set search_path to 'public','pg_temp' as $$
  select coalesce(nullif(regexp_replace(coalesce(p_phone,''),'\D','','g'),''), 'n:'||lower(btrim(coalesce(p_name,''))))
$$;

-- Internal: every counted lesson of tracked students, in order, with its position vs the credits added.
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
    where b.teacher_id=p_teacher and b.status='confirmed' and (b.attendance is null or b.attendance in ('attended','no_show'))),
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
      count(*) filter (where attendance in ('attended','no_show'))::int used,
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

create or replace function public.get_credit_ledger(p_key text)
returns jsonb language plpgsql stable security definer set search_path to 'public','pg_temp' as $$
declare u uuid:=auth.uid();
begin
  if u is null then raise exception 'login required'; end if;
  if not exists(select 1 from public.teachers where id=u) then raise exception 'not a teacher'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id',id,'lessons',lessons,'paid_on',paid_on,'note',note,'created_at',created_at) order by paid_on desc, created_at desc)
    from public.credit_ledger where teacher_id=u and student_key=p_key),'[]'::jsonb);
end $$;

create or replace function public.add_student_credits(p_name text, p_phone text, p_lessons integer, p_paid_on date, p_note text)
returns jsonb language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare u uuid:=auth.uid(); k text; nm text:=btrim(coalesce(p_name,'')); ph text:=nullif(btrim(coalesce(p_phone,'')),''); id uuid;
begin
  if u is null then raise exception 'login required'; end if;
  if not exists(select 1 from public.teachers where teachers.id=u) then raise exception 'not a teacher'; end if;
  if nm='' or char_length(nm)>120 then raise exception 'invalid name'; end if;
  if p_lessons is null or p_lessons=0 or p_lessons<-500 or p_lessons>500 then raise exception 'invalid number of lessons'; end if;
  if p_paid_on is null or p_paid_on>current_date+1 or p_paid_on<current_date-1100 then raise exception 'invalid date'; end if;
  k:=public.bmc_student_key(ph,nm);
  insert into public.credit_ledger(teacher_id,student_key,student_name,contact_phone,lessons,paid_on,note)
    values(u,k,nm,ph,p_lessons,p_paid_on,nullif(btrim(coalesce(p_note,'')),'')) returning credit_ledger.id into id;
  return jsonb_build_object('id',id,'key',k);
end $$;

-- For students: only the ids of their own upcoming lessons that are not yet covered by credits.
-- Returns no numbers on purpose; the page shows a soft "being confirmed" cue.
create or replace function public.get_my_credit_flags()
returns jsonb language plpgsql stable security definer set search_path to 'public','pg_temp' as $$
declare u uuid:=auth.uid();
begin
  if u is null then raise exception 'login required'; end if;
  return coalesce((select jsonb_agg(l.booking_id)
    from (select distinct teacher_id from public.bookings where booker_id=u and status='confirmed') t,
         lateral public.bmc_credit_lessons(t.teacher_id) l
    join public.bookings b on b.id=l.booking_id and b.booker_id=u
    where l.rn>l.total and l.starts_at>=now()),'[]'::jsonb);
end $$;

revoke all on function public.get_teacher_credits(), public.get_credit_ledger(text), public.add_student_credits(text,text,integer,date,text), public.get_my_credit_flags() from public, anon;
grant execute on function public.get_teacher_credits(), public.get_credit_ledger(text), public.add_student_credits(text,text,integer,date,text), public.get_my_credit_flags() to authenticated;

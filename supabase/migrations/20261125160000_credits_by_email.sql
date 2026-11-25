-- Credits keyed by student email (Ahmed approved 2026-11-25 via the chat; additive and backward compatible).
-- A student's key is 'e:<email>' when we know their email, otherwise the phone/name key used until now.
-- Email comes from the booker's account, or from a link the teacher added for a student booked without an account.
-- Existing ledger rows (currently none) keep working. Safe to run more than once.

alter table public.credit_ledger add column if not exists student_email text;

create table if not exists public.credit_student_links (
  teacher_id uuid not null references public.teachers(id) on delete cascade,
  old_key text not null,
  email text not null check (email = lower(email) and char_length(email) <= 254),
  created_at timestamptz not null default now(),
  primary key (teacher_id, old_key)
);
alter table public.credit_student_links enable row level security;
revoke all on public.credit_student_links from anon, authenticated;

-- Canonical key of one booking's student.
create or replace function public.bmc_booking_key(p_teacher uuid, p_booker uuid, p_phone text, p_name text)
returns text language sql stable security definer set search_path to 'public','pg_temp' as $$
  select coalesce(
    (select 'e:'||lower(btrim(p.email)) from public.profiles p where p.id=p_booker and p_booker is not null and p_booker<>p_teacher and nullif(btrim(p.email),'') is not null),
    (select 'e:'||l.email from public.credit_student_links l where l.teacher_id=p_teacher and l.old_key=public.bmc_student_key(p_phone,p_name)),
    public.bmc_student_key(p_phone,p_name))
$$;
revoke all on function public.bmc_booking_key(uuid,uuid,text,text) from public, anon, authenticated;

create or replace function public.bmc_credit_lessons(p_teacher uuid)
returns table(booking_id uuid, student_key text, starts_at timestamptz, attendance text, rn integer, total integer)
language sql stable security definer set search_path to 'public','pg_temp' as $$
  with tz as (select coalesce((select timezone from public.teachers where id=p_teacher),'UTC') z),
  led as (
    select student_key, sum(lessons)::int total, min(paid_on) first_paid
    from public.credit_ledger where teacher_id=p_teacher group by 1),
  bk as (
    select b.id, public.bmc_booking_key(p_teacher,b.booker_id,b.contact_phone,b.student_name) k, b.starts_at, b.attendance
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
    select distinct on (k) k, student_name nm, contact_phone ph from (
      select public.bmc_booking_key(u,booker_id,contact_phone,student_name) k, student_name, contact_phone, starts_at
      from public.bookings where teacher_id=u and status='confirmed') s
    order by k, starts_at desc),
  sug as (
    select distinct on (c.k) c.k, lower(btrim(p.email)) email
    from cand c
    join public.bookings b on b.teacher_id=u and b.booker_id is not null and b.booker_id<>u and b.status='confirmed'
         and regexp_replace(coalesce(b.contact_phone,''),'\D','','g')=c.k
    join public.profiles p on p.id=b.booker_id and nullif(btrim(p.email),'') is not null
    where c.k !~ '^(e:|n:)')
  select jsonb_build_object(
    'students', coalesce((select jsonb_agg(jsonb_build_object('key',k,'name',nm,'phone',ph,'email',case when k like 'e:%' then substr(k,3) end,'total',total,'used',used,'pending',pending,
        'remaining',total-used,'free',total-used-pending,'uncovered',uncovered,'last_added',last_added) order by (total-used-pending), nm) from rows),'[]'::jsonb),
    'known', coalesce((select jsonb_agg(jsonb_build_object('key',c.k,'name',c.nm,'phone',c.ph,'email',case when c.k like 'e:%' then substr(c.k,3) end,'suggest',s.email) order by c.nm)
        from cand c left join sug s on s.k=c.k where c.k not in (select k from rows)),'[]'::jsonb),
    'uncovered_ids', coalesce((select jsonb_agg(booking_id) from l where rn>total),'[]'::jsonb)
  ) into res;
  return res;
end $$;

-- New entry point: p_key = existing student key (or null for someone new). p_email optional for linked students, required for new.
create or replace function public.add_credits_for(p_key text, p_name text, p_phone text, p_email text, p_lessons integer, p_paid_on date, p_note text)
returns jsonb language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare u uuid:=auth.uid(); k text; nm text:=btrim(coalesce(p_name,'')); ph text:=nullif(btrim(coalesce(p_phone,'')),'');
        em text:=lower(nullif(btrim(coalesce(p_email,'')),'')); ok text:=nullif(btrim(coalesce(p_key,'')),''); id uuid;
begin
  if u is null then raise exception 'login required'; end if;
  if not exists(select 1 from public.teachers where teachers.id=u) then raise exception 'not a teacher'; end if;
  if p_lessons is null or p_lessons=0 or p_lessons<-500 or p_lessons>500 then raise exception 'invalid number of lessons'; end if;
  if p_paid_on is null or p_paid_on>current_date+1 or p_paid_on<current_date-1100 then raise exception 'invalid date'; end if;
  if em is not null and (char_length(em)>254 or em !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$') then raise exception 'invalid email'; end if;
  if ok is not null and ok like 'e:%' then
    k:=ok; em:=substr(ok,3);
  elsif em is not null then
    k:='e:'||em;
    if ok is not null then  -- link an existing phone/name student to this email and move any earlier credits across
      insert into public.credit_student_links(teacher_id,old_key,email) values(u,ok,em)
        on conflict (teacher_id,old_key) do update set email=excluded.email;
      update public.credit_ledger set student_key=k, student_email=em where teacher_id=u and student_key=ok;
    end if;
  elsif ok is not null then
    k:=coalesce((select 'e:'||l.email from public.credit_student_links l where l.teacher_id=u and l.old_key=ok), ok);
  else
    raise exception 'email required';
  end if;
  if nm='' then nm:=coalesce((select b.student_name from public.bookings b where b.teacher_id=u and public.bmc_booking_key(u,b.booker_id,b.contact_phone,b.student_name)=k order by b.starts_at desc limit 1), split_part(coalesce(em,''),'@',1)); end if;
  if nm='' or char_length(nm)>120 then raise exception 'invalid name'; end if;
  insert into public.credit_ledger(teacher_id,student_key,student_name,contact_phone,student_email,lessons,paid_on,note)
    values(u,k,nm,ph,case when k like 'e:%' then substr(k,3) end,p_lessons,p_paid_on,nullif(btrim(coalesce(p_note,'')),'')) returning credit_ledger.id into id;
  return jsonb_build_object('id',id,'key',k);
end $$;

revoke all on function public.add_credits_for(text,text,text,text,integer,date,text) from public, anon;
grant execute on function public.add_credits_for(text,text,text,text,integer,date,text) to authenticated;

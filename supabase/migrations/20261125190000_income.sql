-- Income B (approved by Ahmed 2026-11-25): paid marks on lessons, optional "charge for no-shows" (default OFF), income view.
-- Additive. With charge_noshow = false (default) credit counting is identical to before: bmc_credit_lessons only returns
-- no_show rows when the flag is on, so 'attended or no_show' in get_teacher_credits changes nothing while it is off.
alter table public.teachers add column if not exists charge_noshow boolean not null default false;
alter table public.bookings add column if not exists paid_at timestamptz;
alter table public.bookings add column if not exists paid_amount numeric(10,2) check (paid_amount is null or (paid_amount>=0 and paid_amount<=100000));
alter table public.bookings add column if not exists paid_currency text check (paid_currency is null or char_length(paid_currency) between 1 and 8);

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
    where b.teacher_id=p_teacher and b.status='confirmed' and (b.attendance is null or b.attendance = 'attended' or (b.attendance = 'no_show' and coalesce((select charge_noshow from public.teachers where id=p_teacher),false)))),
  c as (
    select bk.id, bk.k, bk.starts_at, bk.attendance, led.total,
           row_number() over (partition by bk.k order by bk.starts_at) rn
    from bk join led on led.student_key=bk.k, tz
    where bk.starts_at >= (led.first_paid::timestamp at time zone tz.z))
  select id, k, starts_at, attendance, rn::int, total from c
$$;

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
      count(*) filter (where attendance = 'attended' or attendance = 'no_show')::int used,
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

create or replace function public.set_charge_noshow(p_on boolean)
returns void language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare u uuid:=auth.uid();
begin
  if u is null then raise exception 'login required'; end if;
  if not exists(select 1 from public.teachers where id=u) then raise exception 'not a teacher'; end if;
  update public.teachers set charge_noshow=coalesce(p_on,false) where id=u;
end $$;

create or replace function public.get_pay_context()
returns jsonb language plpgsql stable security definer set search_path to 'public','pg_temp' as $$
declare u uuid:=auth.uid(); res jsonb;
begin
  if u is null then raise exception 'login required'; end if;
  if not exists(select 1 from public.teachers where id=u) then raise exception 'not a teacher'; end if;
  select jsonb_build_object(
    'price',(select lesson_price from public.teachers where id=u),
    'currency',(select currency from public.teachers where id=u),
    'charge_noshow',(select charge_noshow from public.teachers where id=u),
    'modes',coalesce((select jsonb_object_agg(student_key,pay_mode) from public.student_pay where teacher_id=u),'{}'::jsonb),
    'terms',coalesce((select jsonb_object_agg(student_key,jsonb_build_object('price',price,'currency',currency)) from public.student_pay where teacher_id=u and (price is not null or currency is not null)),'{}'::jsonb),
    'bk',coalesce((select jsonb_agg(jsonb_build_object('id',b.id,'name',b.student_name,'key',public.bmc_booking_key(u,b.booker_id,b.contact_phone,b.student_name),'by_teacher',(b.booker_id is null or b.booker_id=u)))
         from public.bookings b where b.teacher_id=u and b.status='confirmed' and b.starts_at >= now() - interval '90 days'),'[]'::jsonb)
  ) into res;
  return res;
end $$;

-- Income data for the teacher's own view. Price/currency: the student's own terms, else the teacher default.
create or replace function public.get_income()
returns jsonb language plpgsql stable security definer set search_path to 'public','pg_temp' as $$
declare u uuid:=auth.uid(); res jsonb; ns boolean;
begin
  if u is null then raise exception 'login required'; end if;
  if not exists(select 1 from public.teachers where id=u) then raise exception 'not a teacher'; end if;
  select charge_noshow into ns from public.teachers where id=u;
  with t as (select lesson_price p, currency c from public.teachers where id=u),
  cov as (select booking_id from public.bmc_credit_lessons(u) where rn<=total),
  ls as (
    select b.id, b.student_name nm, b.starts_at, b.attendance, b.paid_at, b.paid_amount, b.paid_currency,
           public.bmc_booking_key(u,b.booker_id,b.contact_phone,b.student_name) k
    from public.bookings b
    where b.teacher_id=u and b.status='confirmed' and b.starts_at >= now() - interval '400 days'
      and (b.attendance='attended' or (b.attendance='no_show' and ns))),
  full_ as (
    select ls.*, coalesce(sp.price,t.p) price, coalesce(sp.currency,t.c) cur, coalesce(sp.pay_mode,'after') mode,
           (ls.id in (select booking_id from cov)) covered
    from ls cross join t left join public.student_pay sp on sp.teacher_id=u and sp.student_key=ls.k)
  select jsonb_build_object(
    'charge_noshow',ns,
    'lessons',coalesce((select jsonb_agg(jsonb_build_object('id',id,'name',nm,'key',k,'starts_at',starts_at,'att',attendance,'price',price,'cur',cur,'mode',mode,'covered',covered,'paid_at',paid_at,'paid_amount',paid_amount,'paid_cur',paid_currency) order by starts_at desc) from full_),'[]'::jsonb),
    'received',coalesce((select jsonb_agg(jsonb_build_object('id',l.id,'name',l.student_name,'key',l.student_key,'amount',l.amount,'cur',coalesce(sp.currency,t.c),'paid_on',l.paid_on) order by l.paid_on desc)
        from public.credit_ledger l cross join t left join public.student_pay sp on sp.teacher_id=u and sp.student_key=l.student_key
        where l.teacher_id=u and l.amount is not null and l.lessons>0 and l.paid_on >= current_date - 400),'[]'::jsonb)
  ) into res;
  return res;
end $$;

-- Marks one of the teacher's own lessons paid, snapshotting the amount and currency at that moment (default: the lesson's current price).
create or replace function public.mark_lesson_paid(p_booking uuid, p_paid boolean default true)
returns void language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare u uuid:=auth.uid(); k text; pr numeric; cu text; b record;
begin
  if u is null then raise exception 'login required'; end if;
  if not exists(select 1 from public.teachers where id=u) then raise exception 'not a teacher'; end if;
  select * into b from public.bookings where id=p_booking and teacher_id=u;
  if b.id is null then raise exception 'booking not found'; end if;
  if not coalesce(p_paid,true) then
    update public.bookings set paid_at=null, paid_amount=null, paid_currency=null where id=p_booking and teacher_id=u; return;
  end if;
  k:=public.bmc_booking_key(u,b.booker_id,b.contact_phone,b.student_name);
  select coalesce(sp.price,t.lesson_price), coalesce(sp.currency,t.currency) into pr,cu
    from public.teachers t left join public.student_pay sp on sp.teacher_id=t.id and sp.student_key=k where t.id=u;
  update public.bookings set paid_at=now(), paid_amount=pr, paid_currency=cu where id=p_booking and teacher_id=u;
end $$;

revoke all on function public.set_charge_noshow(boolean) from public, anon;
revoke all on function public.get_income() from public, anon;
revoke all on function public.mark_lesson_paid(uuid,boolean) from public, anon;
grant execute on function public.set_charge_noshow(boolean) to authenticated;
grant execute on function public.get_income() to authenticated;
grant execute on function public.mark_lesson_paid(uuid,boolean) to authenticated;

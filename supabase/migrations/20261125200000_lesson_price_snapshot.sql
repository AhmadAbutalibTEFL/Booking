-- Income B follow-up (Ahmed approved 2026-11-25 7:54pm: a price change applies to future lessons only).
-- Each lesson stores the price and currency it was taught at. It is stamped the first time the lesson is marked
-- attended (or no-show) and kept after that, so changing a student's price never changes past earnings.
-- Existing attended/no-show lessons get the student's current price at migration time (a no-op while no price is set).
-- Additive and safe to run more than once.
alter table public.bookings add column if not exists price numeric(10,2) check (price is null or (price>=0 and price<=100000));
alter table public.bookings add column if not exists currency text check (currency is null or char_length(currency) between 1 and 8);

create or replace function public.bmc_stamp_lesson_price()
returns trigger language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare k text; pr numeric; cu text;
begin
  if new.attendance is distinct from old.attendance then
    if new.attendance in ('attended','no_show') then
      if new.price is null then
        k:=public.bmc_booking_key(new.teacher_id,new.booker_id,new.contact_phone,new.student_name);
        select coalesce(sp.price,t.lesson_price), coalesce(sp.currency,t.currency) into pr,cu
          from public.teachers t left join public.student_pay sp on sp.teacher_id=t.id and sp.student_key=k where t.id=new.teacher_id;
        new.price:=pr; new.currency:=case when pr is null then null else cu end;
      end if;
    else
      new.price:=null; new.currency:=null;
    end if;
  end if;
  return new;
end $$;
revoke all on function public.bmc_stamp_lesson_price() from public, anon, authenticated;
drop trigger if exists bmc_stamp_lesson_price on public.bookings;
create trigger bmc_stamp_lesson_price before update of attendance on public.bookings
  for each row execute function public.bmc_stamp_lesson_price();

-- Backfill: existing marked lessons get the student's current price (null when none is set).
update public.bookings b set price=x.pr, currency=x.cu
from (
  select b2.id, coalesce(sp.price,t.lesson_price) pr, coalesce(sp.currency,t.currency) cu
  from public.bookings b2 join public.teachers t on t.id=b2.teacher_id
  left join public.student_pay sp on sp.teacher_id=b2.teacher_id and sp.student_key=public.bmc_booking_key(b2.teacher_id,b2.booker_id,b2.contact_phone,b2.student_name)
  where b2.attendance in ('attended','no_show') and b2.price is null) x
where b.id=x.id and x.pr is not null;

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
    select b.id, b.student_name nm, b.starts_at, b.attendance, b.paid_at, b.paid_amount, b.paid_currency, b.price l_price, b.currency l_cur,
           public.bmc_booking_key(u,b.booker_id,b.contact_phone,b.student_name) k
    from public.bookings b
    where b.teacher_id=u and b.status='confirmed' and b.starts_at >= now() - interval '400 days'
      and (b.attendance='attended' or (b.attendance='no_show' and ns))),
  full_ as (
    select ls.*, ls.l_price price, ls.l_cur cur, coalesce(sp.pay_mode,'after') mode,
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
  pr:=b.price; cu:=b.currency;
  if pr is null then
    select coalesce(sp.price,t.lesson_price), coalesce(sp.currency,t.currency) into pr,cu
      from public.teachers t left join public.student_pay sp on sp.teacher_id=t.id and sp.student_key=k where t.id=u;
  end if;
  update public.bookings set paid_at=now(), paid_amount=pr, paid_currency=cu where id=p_booking and teacher_id=u;
end $$;

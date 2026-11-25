-- Income: "Apply this price to past lessons" (Ahmed approved 2026-11-25 9:28pm). Per student, with preview and undo.
-- Additive. Never overwrites a lesson that already has a price. Undo clears only the lessons stamped by that one apply.
alter table public.bookings add column if not exists price_batch uuid;

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
        new.price:=pr; new.currency:=case when pr is null then null else cu end; new.price_batch:=null;
      end if;
    else
      new.price:=null; new.currency:=null; new.price_batch:=null;
    end if;
  end if;
  return new;
end $$;

-- Read-only preview: the student's unpriced taught lessons in the date range, at the student's current price.
create or replace function public.preview_past_price(p_key text, p_from date, p_to date)
returns jsonb language plpgsql stable security definer set search_path to 'public','pg_temp' as $$
declare u uuid:=auth.uid(); pr numeric; cu text; ns boolean; tz text; n int; fst date;
begin
  if u is null then raise exception 'login required'; end if;
  if not exists(select 1 from public.teachers where id=u) then raise exception 'not a teacher'; end if;
  select coalesce(sp.price,t.lesson_price), coalesce(sp.currency,t.currency), t.charge_noshow, coalesce(t.timezone,'UTC') into pr,cu,ns,tz
    from public.teachers t left join public.student_pay sp on sp.teacher_id=t.id and sp.student_key=p_key where t.id=u;
  select count(*) filter (where (b.starts_at at time zone tz)::date >= coalesce(p_from,'0001-01-01') and (b.starts_at at time zone tz)::date <= coalesce(p_to,'9999-12-31')),
         min((b.starts_at at time zone tz)::date)
    into n,fst
    from public.bookings b
    where b.teacher_id=u and b.status='confirmed' and b.price is null
      and (b.attendance='attended' or (b.attendance='no_show' and ns))
      and public.bmc_booking_key(u,b.booker_id,b.contact_phone,b.student_name)=p_key;
  return jsonb_build_object('count',coalesce(n,0),'price',pr,'currency',cu,'total',case when pr is null then null else coalesce(n,0)*pr end,'first',fst);
end $$;

create or replace function public.apply_past_price(p_key text, p_from date, p_to date)
returns jsonb language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare u uuid:=auth.uid(); pr numeric; cu text; ns boolean; tz text; n int; bt uuid:=gen_random_uuid();
begin
  if u is null then raise exception 'login required'; end if;
  if not exists(select 1 from public.teachers where id=u) then raise exception 'not a teacher'; end if;
  select coalesce(sp.price,t.lesson_price), coalesce(sp.currency,t.currency), t.charge_noshow, coalesce(t.timezone,'UTC') into pr,cu,ns,tz
    from public.teachers t left join public.student_pay sp on sp.teacher_id=t.id and sp.student_key=p_key where t.id=u;
  if pr is null then raise exception 'no price set'; end if;
  update public.bookings b set price=pr, currency=cu, price_batch=bt
    where b.teacher_id=u and b.status='confirmed' and b.price is null
      and (b.attendance='attended' or (b.attendance='no_show' and ns))
      and (b.starts_at at time zone tz)::date >= coalesce(p_from,'0001-01-01') and (b.starts_at at time zone tz)::date <= coalesce(p_to,'9999-12-31')
      and public.bmc_booking_key(u,b.booker_id,b.contact_phone,b.student_name)=p_key;
  get diagnostics n = row_count;
  return jsonb_build_object('batch',bt,'count',n,'price',pr,'currency',cu,'total',n*pr);
end $$;

create or replace function public.undo_past_price(p_batch uuid)
returns integer language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare u uuid:=auth.uid(); n int;
begin
  if u is null then raise exception 'login required'; end if;
  if not exists(select 1 from public.teachers where id=u) then raise exception 'not a teacher'; end if;
  if p_batch is null then raise exception 'invalid batch'; end if;
  update public.bookings set price=null, currency=null, price_batch=null where teacher_id=u and price_batch=p_batch;
  get diagnostics n = row_count;
  return n;
end $$;

revoke all on function public.preview_past_price(text,date,date) from public, anon;
revoke all on function public.apply_past_price(text,date,date) from public, anon;
revoke all on function public.undo_past_price(uuid) from public, anon;
grant execute on function public.preview_past_price(text,date,date) to authenticated;
grant execute on function public.apply_past_price(text,date,date) to authenticated;
grant execute on function public.undo_past_price(uuid) to authenticated;

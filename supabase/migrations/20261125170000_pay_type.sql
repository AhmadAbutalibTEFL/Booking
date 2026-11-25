-- Income, step A (Ahmed approved 2026-11-25 via the chat; additive only, safe to run more than once).
-- 1) Per-teacher price and currency (price empty until the teacher sets it).
-- 2) Per-student pay type ('after' = pays after the lesson, 'before' = prepaid lesson balance), keyed like the credits.
-- 3) Optional amount paid on a credit ledger row.
-- Nothing existing changes: students without a row behave as 'after'; credits are not touched.

alter table public.teachers add column if not exists lesson_price numeric(10,2) check (lesson_price is null or (lesson_price >= 0 and lesson_price <= 100000));
alter table public.teachers add column if not exists currency text not null default 'SAR' check (char_length(currency) between 1 and 8);
alter table public.credit_ledger add column if not exists amount numeric(12,2) check (amount is null or (amount >= 0 and amount <= 10000000));

create table if not exists public.student_pay (
  teacher_id uuid not null references public.teachers(id) on delete cascade,
  student_key text not null check (char_length(student_key) between 1 and 300),
  pay_mode text not null check (pay_mode in ('after','before')),
  updated_at timestamptz not null default now(),
  primary key (teacher_id, student_key)
);
alter table public.student_pay enable row level security;
revoke all on public.student_pay from anon, authenticated;

create or replace function public.get_pay_context()
returns jsonb language plpgsql stable security definer set search_path to 'public','pg_temp' as $$
declare u uuid:=auth.uid(); res jsonb;
begin
  if u is null then raise exception 'login required'; end if;
  if not exists(select 1 from public.teachers where id=u) then raise exception 'not a teacher'; end if;
  select jsonb_build_object(
    'price',(select lesson_price from public.teachers where id=u),
    'currency',(select currency from public.teachers where id=u),
    'modes',coalesce((select jsonb_object_agg(student_key,pay_mode) from public.student_pay where teacher_id=u),'{}'::jsonb),
    'bk',coalesce((select jsonb_agg(jsonb_build_object('id',b.id,'name',b.student_name,'key',public.bmc_booking_key(u,b.booker_id,b.contact_phone,b.student_name),'by_teacher',(b.booker_id is null or b.booker_id=u)))
         from public.bookings b where b.teacher_id=u and b.status='confirmed' and b.starts_at >= now() - interval '90 days'),'[]'::jsonb)
  ) into res;
  return res;
end $$;

create or replace function public.set_student_pay(p_key text, p_mode text)
returns void language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare u uuid:=auth.uid(); k text:=nullif(btrim(coalesce(p_key,'')),'');
begin
  if u is null then raise exception 'login required'; end if;
  if not exists(select 1 from public.teachers where id=u) then raise exception 'not a teacher'; end if;
  if k is null or char_length(k)>300 then raise exception 'invalid student'; end if;
  if p_mode is null or p_mode not in ('after','before') then raise exception 'invalid pay type'; end if;
  insert into public.student_pay(teacher_id,student_key,pay_mode) values(u,k,p_mode)
    on conflict (teacher_id,student_key) do update set pay_mode=excluded.pay_mode, updated_at=now();
end $$;

-- Sets the pay type for the student of one of the teacher's own bookings; returns the student key.
create or replace function public.set_booking_pay(p_booking uuid, p_mode text)
returns text language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare u uuid:=auth.uid(); k text;
begin
  if u is null then raise exception 'login required'; end if;
  if not exists(select 1 from public.teachers where id=u) then raise exception 'not a teacher'; end if;
  if p_mode is null or p_mode not in ('after','before') then raise exception 'invalid pay type'; end if;
  select public.bmc_booking_key(u,b.booker_id,b.contact_phone,b.student_name) into k
    from public.bookings b where b.id=p_booking and b.teacher_id=u;
  if k is null then raise exception 'booking not found'; end if;
  insert into public.student_pay(teacher_id,student_key,pay_mode) values(u,k,p_mode)
    on conflict (teacher_id,student_key) do update set pay_mode=excluded.pay_mode, updated_at=now();
  return k;
end $$;

create or replace function public.set_pay_settings(p_price numeric, p_currency text)
returns void language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare u uuid:=auth.uid(); c text:=upper(btrim(coalesce(p_currency,'')));
begin
  if u is null then raise exception 'login required'; end if;
  if not exists(select 1 from public.teachers where id=u) then raise exception 'not a teacher'; end if;
  if p_price is not null and (p_price<0 or p_price>100000) then raise exception 'invalid price'; end if;
  if c='' or char_length(c)>8 then raise exception 'invalid currency'; end if;
  update public.teachers set lesson_price=p_price, currency=c where id=u;
end $$;

create or replace function public.set_credit_amount(p_id uuid, p_amount numeric)
returns void language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare u uuid:=auth.uid();
begin
  if u is null then raise exception 'login required'; end if;
  if not exists(select 1 from public.teachers where id=u) then raise exception 'not a teacher'; end if;
  if p_amount is not null and (p_amount<0 or p_amount>10000000) then raise exception 'invalid amount'; end if;
  update public.credit_ledger set amount=p_amount where id=p_id and teacher_id=u;
end $$;

revoke all on function public.get_pay_context() from public, anon;
revoke all on function public.set_student_pay(text,text) from public, anon;
revoke all on function public.set_booking_pay(uuid,text) from public, anon;
revoke all on function public.set_pay_settings(numeric,text) from public, anon;
revoke all on function public.set_credit_amount(uuid,numeric) from public, anon;
grant execute on function public.get_pay_context() to authenticated;
grant execute on function public.set_student_pay(text,text) to authenticated;
grant execute on function public.set_booking_pay(uuid,text) to authenticated;
grant execute on function public.set_pay_settings(numeric,text) to authenticated;
grant execute on function public.set_credit_amount(uuid,numeric) to authenticated;

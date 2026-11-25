-- Income A (rework, approved by Ahmed 2026-11-25): price and currency per student, stored with the pay type.
-- Additive and safe to run more than once. teachers.lesson_price/currency stay as the default for new students.
alter table public.student_pay add column if not exists price numeric(10,2) check (price is null or (price >= 0 and price <= 100000));
alter table public.student_pay add column if not exists currency text check (currency is null or char_length(currency) between 1 and 8);

create or replace function public.set_student_terms(p_key text, p_price numeric, p_currency text)
returns void language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare u uuid:=auth.uid(); k text:=nullif(btrim(coalesce(p_key,'')),''); c text:=nullif(upper(btrim(coalesce(p_currency,''))),'');
begin
  if u is null then raise exception 'login required'; end if;
  if not exists(select 1 from public.teachers where id=u) then raise exception 'not a teacher'; end if;
  if k is null or char_length(k)>300 then raise exception 'invalid student'; end if;
  if p_price is not null and (p_price<0 or p_price>100000) then raise exception 'invalid price'; end if;
  if c is not null and char_length(c)>8 then raise exception 'invalid currency'; end if;
  insert into public.student_pay(teacher_id,student_key,pay_mode,price,currency) values(u,k,'after',p_price,c)
    on conflict (teacher_id,student_key) do update set price=excluded.price, currency=excluded.currency, updated_at=now();
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
    'modes',coalesce((select jsonb_object_agg(student_key,pay_mode) from public.student_pay where teacher_id=u),'{}'::jsonb),
    'terms',coalesce((select jsonb_object_agg(student_key,jsonb_build_object('price',price,'currency',currency)) from public.student_pay where teacher_id=u and (price is not null or currency is not null)),'{}'::jsonb),
    'bk',coalesce((select jsonb_agg(jsonb_build_object('id',b.id,'name',b.student_name,'key',public.bmc_booking_key(u,b.booker_id,b.contact_phone,b.student_name),'by_teacher',(b.booker_id is null or b.booker_id=u)))
         from public.bookings b where b.teacher_id=u and b.status='confirmed' and b.starts_at >= now() - interval '90 days'),'[]'::jsonb)
  ) into res;
  return res;
end $$;

revoke all on function public.set_student_terms(text,numeric,text) from public, anon;
grant execute on function public.set_student_terms(text,numeric,text) to authenticated;

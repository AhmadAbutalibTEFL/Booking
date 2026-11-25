-- Additive. Linked student emails now also cover (a) the weekly series record, so next weeks come out linked, and
-- (b) lessons the teacher books later for an already-linked student. (c) one-time repair of existing series is at the end.
-- Rollback notes are at the bottom. No student data is changed except the series records named in (c).

alter table public.booking_series add column if not exists link_email text;
alter table public.booking_series add column if not exists linked_from_booker uuid;

-- (a) link / unlink / claim also handle the series record
create or replace function public.link_student_email(p_old_key text, p_email text)
returns jsonb language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare u uuid:=auth.uid(); em text:=lower(btrim(coalesce(p_email,''))); n int; pid uuid;
begin
if u is null then raise exception 'login required'; end if;
if not exists(select 1 from public.teachers where id=u) then raise exception 'not a teacher'; end if;
if em='' or char_length(em)>254 or em !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'invalid email'; end if;
if p_old_key is null or p_old_key like 'e:%' then raise exception 'invalid student'; end if;
if exists(select 1 from public.profiles where id=u and lower(btrim(email))=em) then raise exception 'use the student email'; end if;
select count(*) into n from public.bookings where teacher_id=u and status='confirmed' and (booker_id=u or booker_id is null)
and public.bmc_student_key(contact_phone,student_name)=p_old_key;
if n=0 then raise exception 'no lessons to link'; end if;
insert into public.credit_student_links(teacher_id,old_key,email) values(u,p_old_key,em)
on conflict (teacher_id,old_key) do update set email=excluded.email;
select id into pid from public.profiles where lower(btrim(email))=em and deleted_at is null and id<>u order by created_at limit 1;
update public.bookings set link_email=em, linked_from_booker=coalesce(booker_id,u), booker_id=coalesce(pid,booker_id)
where teacher_id=u and status='confirmed' and (booker_id=u or booker_id is null)
and public.bmc_student_key(contact_phone,student_name)=p_old_key;
update public.booking_series set link_email=em, linked_from_booker=coalesce(booker_id,u), booker_id=coalesce(pid,booker_id)
where teacher_id=u and status='active' and (booker_id=u or booker_id is null)
and public.bmc_student_key(contact_phone,student_name)=p_old_key;
return jsonb_build_object('linked',n,'email',em,'claimed',pid is not null);
end $$;

create or replace function public.unlink_student_email(p_old_key text)
returns jsonb language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare u uuid:=auth.uid(); n int;
begin
if u is null then raise exception 'login required'; end if;
if not exists(select 1 from public.teachers where id=u) then raise exception 'not a teacher'; end if;
delete from public.credit_student_links where teacher_id=u and old_key=p_old_key;
update public.bookings set booker_id=coalesce(linked_from_booker,teacher_id), link_email=null, linked_from_booker=null
where teacher_id=u and link_email is not null and public.bmc_student_key(contact_phone,student_name)=p_old_key;
get diagnostics n=row_count;
update public.booking_series set booker_id=coalesce(linked_from_booker,teacher_id), link_email=null, linked_from_booker=null
where teacher_id=u and link_email is not null and public.bmc_student_key(contact_phone,student_name)=p_old_key;
return jsonb_build_object('restored',n);
end $$;

create or replace function public.bmc_claim_linked_bookings()
returns trigger language plpgsql security definer set search_path to 'public','pg_temp' as $$
begin
  if nullif(btrim(coalesce(new.email,'')),'') is not null and new.deleted_at is null then
    update public.bookings set booker_id=new.id where link_email=lower(btrim(new.email)) and booker_id=teacher_id and teacher_id<>new.id;
    update public.booking_series set booker_id=new.id where link_email=lower(btrim(new.email)) and booker_id=teacher_id and teacher_id<>new.id;
  end if;
  return new;
end $$;

-- (b) every new lesson (one-off or next week of a series) for a student the teacher has linked is created linked
create or replace function public.bmc_link_new_booking()
returns trigger language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare em text; fb uuid; pid uuid;
begin
  if new.link_email is not null then return new; end if;
  if new.series_id is not null then
    select s.link_email, s.linked_from_booker into em, fb from public.booking_series s where s.id=new.series_id;
  end if;
  if em is null and new.booker_id=new.teacher_id then
    select l.email into em from public.credit_student_links l
    where l.teacher_id=new.teacher_id and l.old_key not like 'e:%' and l.old_key=public.bmc_student_key(new.contact_phone,new.student_name);
  end if;
  if em is null then return new; end if;
  new.link_email:=em; new.linked_from_booker:=coalesce(fb,new.teacher_id);
  if new.booker_id=new.teacher_id then
    select id into pid from public.profiles where lower(btrim(email))=em and deleted_at is null and id<>new.teacher_id order by created_at limit 1;
    if pid is not null then new.booker_id:=pid; end if;
  end if;
  return new;
end $$;
drop trigger if exists bmc_link_new_booking on public.bookings;
create trigger bmc_link_new_booking before insert on public.bookings for each row execute function public.bmc_link_new_booking();

-- (c) one-time repair: series that still point at the teacher although some of their upcoming lessons are already linked
update public.booking_series s set link_email=x.link_email, linked_from_booker=s.booker_id, booker_id=x.booker_id
from (select distinct on (b.series_id) b.series_id, b.link_email, b.booker_id from public.bookings b
      where b.series_id is not null and b.link_email is not null and b.status='confirmed' and b.starts_at>now()
      order by b.series_id, b.starts_at) x
where s.id=x.series_id and s.booker_id=s.teacher_id and s.link_email is null;

-- ROLLBACK (manual, if ever needed):
--  drop trigger bmc_link_new_booking on public.bookings; drop function public.bmc_link_new_booking();
--  re-create link_student_email / unlink_student_email / bmc_claim_linked_bookings from 20261125220000_correct_balance_link_email.sql
--  repair undo: update public.booking_series set booker_id=linked_from_booker, link_email=null, linked_from_booker=null where link_email is not null;
--  columns booking_series.link_email / linked_from_booker can stay (unused) or be dropped.

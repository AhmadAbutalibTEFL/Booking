-- Correct balance + teacher-chosen student email link. Additive. Safe to run more than once.
-- 1) A correction is one visible ledger row (kind 'correction'). Past rows are never edited or deleted.
alter table public.credit_ledger add column if not exists kind text not null default 'payment';
-- 2) Email link bookkeeping on bookings so a link can be undone and a not-yet-registered student can claim later.
alter table public.bookings add column if not exists link_email text;
alter table public.bookings add column if not exists linked_from_booker uuid;

create or replace function public.get_credit_ledger(p_key text)
returns jsonb language plpgsql stable security definer set search_path to 'public','pg_temp' as $$
declare u uuid:=auth.uid();
begin
  if u is null then raise exception 'login required'; end if;
  if not exists(select 1 from public.teachers where id=u) then raise exception 'not a teacher'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id',id,'lessons',lessons,'paid_on',paid_on,'note',note,'created_at',created_at,'kind',kind) order by paid_on desc, created_at desc)
    from public.credit_ledger where teacher_id=u and student_key=p_key),'[]'::jsonb);
end $$;

-- Names of the students whose lessons share one balance key (so the teacher sees who a shared balance covers).
create or replace function public.get_credit_key_names(p_key text)
returns jsonb language plpgsql stable security definer set search_path to 'public','pg_temp' as $$
declare u uuid:=auth.uid();
begin
  if u is null then raise exception 'login required'; end if;
  if not exists(select 1 from public.teachers where id=u) then raise exception 'not a teacher'; end if;
  return coalesce((select jsonb_agg(distinct b.student_name) from public.bookings b
    where b.teacher_id=u and b.status='confirmed' and public.bmc_booking_key(u,b.booker_id,b.contact_phone,b.student_name)=p_key),'[]'::jsonb);
end $$;

create or replace function public.correct_credit_balance(p_key text, p_expected integer, p_target integer, p_note text)
returns jsonb language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare u uuid:=auth.uid(); cur int; d int; r record; nt text;
begin
  if u is null then raise exception 'login required'; end if;
  if not exists(select 1 from public.teachers where id=u) then raise exception 'not a teacher'; end if;
  if p_key is null or p_expected is null or p_target is null then raise exception 'missing value'; end if;
  if p_target<0 or p_target>500 then raise exception 'lessons left must be between 0 and 500'; end if;
  select (e->>'remaining')::int into cur from jsonb_array_elements(public.get_teacher_credits()->'students') e where e->>'key'=p_key;
  if cur is null then raise exception 'no credits for this student'; end if;
  if cur<>p_expected then raise exception 'balance changed, reload'; end if;
  d:=p_target-cur;
  if d=0 then raise exception 'no change'; end if;
  if d<-500 or d>500 then raise exception 'change too large'; end if;
  select student_name,contact_phone,student_email into r from public.credit_ledger where teacher_id=u and student_key=p_key order by created_at desc limit 1;
  nt:='Correction: '||cur||' → '||p_target||case when nullif(btrim(coalesce(p_note,'')),'') is not null then ' · '||btrim(p_note) else '' end;
  insert into public.credit_ledger(teacher_id,student_key,student_name,contact_phone,student_email,lessons,paid_on,note,kind)
    values(u,p_key,r.student_name,r.contact_phone,r.student_email,d,current_date,left(nt,500),'correction');
  return jsonb_build_object('old',cur,'new',p_target,'delta',d);
end $$;
revoke all on function public.correct_credit_balance(text,integer,integer,text) from public, anon;
grant execute on function public.correct_credit_balance(text,integer,integer,text) to authenticated;
revoke all on function public.get_credit_key_names(text) from public, anon;
grant execute on function public.get_credit_key_names(text) to authenticated;

-- Count what a link would cover, without changing anything.
create or replace function public.preview_link_student(p_old_key text)
returns jsonb language plpgsql stable security definer set search_path to 'public','pg_temp' as $$
declare u uuid:=auth.uid(); past int; up int;
begin
  if u is null then raise exception 'login required'; end if;
  if not exists(select 1 from public.teachers where id=u) then raise exception 'not a teacher'; end if;
  select count(*) filter (where starts_at<now()), count(*) filter (where starts_at>=now()) into past,up
    from public.bookings where teacher_id=u and status='confirmed' and (booker_id=u or booker_id is null)
     and public.bmc_student_key(contact_phone,student_name)=p_old_key;
  return jsonb_build_object('past',past,'upcoming',up,'total',past+up);
end $$;

-- The teacher chooses the email. Applies to that student's lessons booked by the teacher (no student account on them).
-- If a student account with that email exists, those lessons move to it (the student can then edit, cancel and book more).
-- Otherwise they are held for that email and move when the student first signs in.
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
  return jsonb_build_object('restored',n);
end $$;
revoke all on function public.preview_link_student(text) from public, anon;
grant execute on function public.preview_link_student(text) to authenticated;
revoke all on function public.link_student_email(text,text) from public, anon;
grant execute on function public.link_student_email(text,text) to authenticated;
revoke all on function public.unlink_student_email(text) from public, anon;
grant execute on function public.unlink_student_email(text) to authenticated;

-- A student who signs up later receives the lessons the teacher linked to their email.
create or replace function public.bmc_claim_linked_bookings()
returns trigger language plpgsql security definer set search_path to 'public','pg_temp' as $$
begin
  if nullif(btrim(coalesce(new.email,'')),'') is not null and new.deleted_at is null then
    update public.bookings set booker_id=new.id where link_email=lower(btrim(new.email)) and booker_id=teacher_id and teacher_id<>new.id;
  end if;
  return new;
end $$;
revoke all on function public.bmc_claim_linked_bookings() from public, anon, authenticated;
drop trigger if exists bmc_claim_linked on public.profiles;
create trigger bmc_claim_linked after insert or update of email on public.profiles
  for each row execute function public.bmc_claim_linked_bookings();

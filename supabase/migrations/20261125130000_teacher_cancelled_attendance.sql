-- Adds a third attendance status: 'teacher_cancelled' (cancelled by the teacher after the lesson time).
-- Effects (agreed): no points for the student, not a no-show, no notification.
-- Existing rows are untouched; the old values stay valid.

alter table public.bookings drop constraint if exists bookings_attendance_check;
alter table public.bookings add constraint bookings_attendance_check
  check (attendance = any (array['attended'::text, 'no_show'::text, 'teacher_cancelled'::text]));

CREATE OR REPLACE FUNCTION public.mark_attendance(p_booking uuid, p_status text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare b public.bookings;
begin
  if auth.uid() is null then raise exception 'login required'; end if;
  if p_status is not null and p_status not in ('attended','no_show','teacher_cancelled') then raise exception 'invalid status'; end if;
  select * into b from public.bookings where id=p_booking for update;
  if b.id is null then raise exception 'booking not found'; end if;
  if b.teacher_id<>auth.uid() and not public.is_admin() then raise exception 'not allowed'; end if;
  if b.status<>'confirmed' then raise exception 'booking is not active'; end if;
  if b.starts_at>now() then raise exception 'lesson has not started yet'; end if;
  update public.bookings set attendance=p_status,attendance_at=case when p_status is null then null else now() end where id=p_booking;
  if p_status='attended' and b.booker_id<>b.teacher_id then
    delete from public.reward_events where booking_id=p_booking and kind='attended_revoked';
    insert into public.reward_events(user_id,booking_id,kind,points) values(b.booker_id,p_booking,'attended',20) on conflict do nothing;
  else
    insert into public.reward_events(user_id,booking_id,kind,points)
      select e.user_id,e.booking_id,'attended_revoked',-e.points from public.reward_events e where e.booking_id=p_booking and e.kind='attended' on conflict do nothing;
  end if;
  return jsonb_build_object('booking_id',p_booking,'attendance',p_status);
end $function$;

-- ============================================================================
-- BookMyClass - Weekly blocks policy, part 1 of 4 (structural)
-- Safe to run more than once. Makes no live booking changes.
-- What this adds, in plain words:
--   1. Two new columns on booking_series: a running count of consecutive
--      marked no-shows, and when the count first reached 2.
--   2. A small function + trigger that keeps that count correct whenever a
--      lesson's attendance is marked or changed (attended / no-show / unset),
--      or a lesson is cancelled. Past records are never modified.
--   3. A renew_series_block() function the teacher's app will call to renew a
--      4-week block (sets the new end date, restarts lesson generation).
--   4. One line in the notification trigger that lets the LATER conversion
--      step (part 4) run quietly, only when explicitly asked. Normal
--      notifications are unchanged.
-- The 4-week block itself uses the EXISTING ends_on column: lesson generation
-- already stops after ends_on. Block = [anchor, anchor+27 days] inclusive,
-- which always contains exactly 4 weekly lessons.
-- ============================================================================

-- (1) streak columns ----------------------------------------------------------
alter table public.booking_series
  add column if not exists consecutive_no_shows integer not null default 0;
alter table public.booking_series
  add column if not exists no_show_flagged_at timestamptz;
-- Marker so a later renewal can restore exactly the lessons the conversion
-- step (part 4) cancelled, without touching lessons cancelled for any other
-- reason.
alter table public.bookings
  add column if not exists block_auto_cancelled boolean not null default false;

-- (2) streak recompute + trigger ----------------------------------------------
create or replace function public._bmc_refresh_no_show_streak(p_series uuid)
returns integer
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare v_streak int := 0; r record;
begin
  -- Walk the series' past confirmed lessons newest-first. Count consecutive
  -- MARKED no-shows; an attended or unmarked lesson breaks the run.
  for r in
    select attendance from public.bookings
     where series_id = p_series and status = 'confirmed' and starts_at < now()
     order by starts_at desc
  loop
    if r.attendance = 'no_show' then v_streak := v_streak + 1; else exit; end if;
  end loop;
  update public.booking_series
     set consecutive_no_shows = v_streak,
         no_show_flagged_at = case
           when v_streak >= 2 and consecutive_no_shows < 2 then now()
           else no_show_flagged_at end
   where id = p_series;
  return v_streak;
end
$function$;

create or replace function public._bmc_no_show_streak_trigger()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
begin
  if new.series_id is null then return new; end if;
  if tg_op = 'INSERT'
     or new.attendance is distinct from old.attendance
     or new.status     is distinct from old.status then
    perform public._bmc_refresh_no_show_streak(new.series_id);
  end if;
  return new;
end
$function$;

drop trigger if exists bmc_no_show_streak on public.bookings;
create trigger bmc_no_show_streak
  after insert or update on public.bookings
  for each row execute function public._bmc_no_show_streak_trigger();

-- (3) renewal ------------------------------------------------------------------
-- Renews a series' 4-week block. Only the series' own teacher may call it.
-- New block starts the day after the old block ends (contiguous renewal), or
-- today if the old block already lapsed. Exactly 4 weekly lessons per block.
create or replace function public.renew_series_block(p_series uuid)
returns date
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare s public.booking_series; v_start date; v_end date;
begin
  select * into s from public.booking_series where id = p_series;
  if s.id is null then raise exception 'series not found'; end if;
  if auth.uid() is null or auth.uid() <> s.teacher_id then
    raise exception 'not allowed';
  end if;
  v_start := greatest((now() at time zone s.timezone)::date, coalesce(s.ends_on + 1, (now() at time zone s.timezone)::date));
  v_end   := v_start + 27;
  update public.booking_series
     set ends_on = v_end, status = 'active', ended_at = null
   where id = p_series;
  -- Restore lessons the conversion step auto-cancelled that fall inside the
  -- new block. (Generation cannot recreate them: it skips occupied slots.)
  -- Lessons cancelled for any other reason stay cancelled.
  update public.bookings
     set status = 'confirmed', block_auto_cancelled = false
   where series_id = p_series and status = 'cancelled' and block_auto_cancelled
     and (starts_at at time zone s.timezone)::date <= v_end;
  perform public._bmc_extend_series(p_series);
  return v_end;
end
$function$;

-- (4) quiet-mode guard for the notification trigger ---------------------------
-- Identical to the live function except the two marked lines. Normal traffic
-- is unaffected: the setting is absent everywhere except inside the part-4
-- conversion script, which sets it for its own transaction only.
create or replace function public._bmc_notify_booking()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare actor uuid:=auth.uid(); rec uuid; k text; chg text[]:='{}'; tn text; an text;
begin
  if current_setting('bmc.skip_notify', true) = '1' then return new; end if; -- NEW LINE (conversion quiet mode)
  if actor is null then return new; end if;
    if tg_op='INSERT' then
        if new.status<>'confirmed' then return new; end if;
            if new.series_id is not null and exists(select 1 from public.bookings b where b.series_id=new.series_id and b.id<>new.id) then return new; end if;
                k:='booking_new';
      else
          if new.starts_at<now() then return new; end if;
              if old.status='confirmed' and new.status='cancelled' then k:='booking_cancelled';
                  elsif old.status='confirmed' and new.status='confirmed' then
                        if new.starts_at is distinct from old.starts_at then chg:=array_append(chg,'time'); end if;
                              if new.session_type_id is distinct from old.session_type_id then chg:=array_append(chg,'type'); end if;
                                    if new.student_name is distinct from old.student_name or new.contact_phone is distinct from old.contact_phone or new.notes is distinct from old.notes then chg:=array_append(chg,'details'); end if;
                                          if array_length(chg,1) is null then return new; end if;
                                                k:='booking_changed';
                    else return new; end if;
      end if;
        select display_name into tn from public.teachers where id=new.teacher_id;
          select coalesce(full_name,email) into an from public.profiles where id=actor;
            for rec in select distinct x from unnest(array[new.teacher_id,new.booker_id]) x where x is not null and x<>actor loop
                if new.series_id is not null and exists(select 1 from public.notifications n where n.user_id=rec and n.kind=k and n.series_id=new.series_id and n.created_at=now()) then continue; end if;
                    insert into public.notifications(user_id,kind,booking_id,series_id,actor_id,data)
                        values(rec,k,new.id,new.series_id,actor,jsonb_build_object('student_name',new.student_name,'starts_at',new.starts_at,'teacher_name',tn,'actor_name',an,
                              'series',new.series_id is not null,'changes',to_jsonb(chg),'actor_is_teacher',actor=new.teacher_id));
              end loop;
                return new;
end $function$;

-- Optional teacher setting: "Only allow regular session times".
-- When on, students can only book start times that line up with the start of the teacher's availability window
-- and the lesson length plus buffer (e.g. 4:00, 5:00, 6:00 for 50 min + 10 min buffer), never in-between times
-- like 4:30 that would split the day. Off by default: behaviour is unchanged. The teacher can still book any time.
alter table public.teachers add column if not exists clean_session_times boolean not null default false;

CREATE OR REPLACE FUNCTION public._bmc_window_start(p_teacher uuid, p_day date, p_time time)
 RETURNS time
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
-- Start of the merged availability window (same merge rule as get_available_slots) that contains p_time on p_day.
declare w record; cs time; ce time; res time;
begin
  for w in select x.s, x.e from (
      select r.start_time s, r.end_time e from public.availability_rules r where r.teacher_id=p_teacher and r.weekday=extract(dow from p_day)::int
        and not exists(select 1 from public.availability_exceptions x where x.teacher_id=p_teacher and x.on_date=p_day)
      union all select x.start_time, x.end_time from public.availability_exceptions x
        where x.teacher_id=p_teacher and x.on_date=p_day and x.is_available and x.start_time is not null and x.end_time is not null) x order by 1 loop
    if cs is null then cs:=w.s; ce:=w.e;
    elsif w.s > ce then
      if p_time>=cs and p_time<=ce then res:=cs; end if;
      cs:=w.s; ce:=w.e;
    else ce:=greatest(ce,w.e); end if;
  end loop;
  if cs is not null and p_time>=cs and p_time<=ce then res:=cs; end if;
  return res;
end $function$;

CREATE OR REPLACE FUNCTION public._bmc_check_slot(t teachers, st session_types, p_start timestamp with time zone, p_uid uuid, p_notice boolean)
 RETURNS text
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_local timestamp; v_end_local timestamp; v_day date; v_ov text; v_ok boolean;
begin
  if p_start < now() then return 'too soon'; end if;
  v_local := p_start at time zone t.timezone; v_day := v_local::date;
  v_end_local := (p_start + make_interval(mins=>st.duration_min)) at time zone t.timezone;
  if v_day <> v_end_local::date then return 'lesson crosses local day boundary'; end if;
  select case when exists(select 1 from public.booking_slot_overrides o where o.teacher_id=t.id and o.action='closed' and o.slot_start < p_start+make_interval(mins=>st.duration_min) and o.slot_start+interval '30 minutes' > p_start) then 'closed' when exists(select 1 from public.booking_slot_overrides o where o.teacher_id=t.id and o.action='jit' and p_start>=o.slot_start and p_start<o.slot_start+interval '30 minutes') then 'jit' end into v_ov; /* cells */
  if v_ov='closed' and p_uid is distinct from t.id then return 'slot closed'; end if;
  if p_notice and p_uid is distinct from t.id and v_ov is distinct from 'jit' and not t.on_the_spot_booking
     and p_start < now()+interval '8 hours' then return 'too soon'; end if;
  if exists(select 1 from public.availability_exceptions x where x.teacher_id=t.id and x.on_date=v_day) then
    select exists(select 1 from public.availability_exceptions x where x.teacher_id=t.id and x.on_date=v_day and x.is_available
      and x.start_time<=v_local::time and x.end_time>=v_end_local::time) into v_ok;
  else
    select exists(select 1 from public.availability_rules r where r.teacher_id=t.id and r.weekday=extract(dow from v_local)::int
      and r.start_time<=v_local::time and r.end_time>=v_end_local::time) into v_ok;
  end if;
  if not v_ok then return 'outside availability'; end if;
  if coalesce(t.clean_session_times,false) and p_uid is distinct from t.id then
    declare v_ws time; v_off numeric;
    begin
      v_ws := public._bmc_window_start(t.id, v_day, v_local::time);
      v_off := extract(epoch from (v_local::time - v_ws))/60;
      if v_ws is null or mod(v_off, st.duration_min+st.buffer_min) <> 0 then return 'not a regular session time'; end if;
    end;
  end if;
  return null;
end $function$
;

CREATE OR REPLACE FUNCTION public.get_available_slots(p_teacher uuid, p_session_type uuid, p_from date DEFAULT NULL::date, p_days integer DEFAULT 28)
 RETURNS TABLE(slot_start timestamp with time zone, slot_end timestamp with time zone, state text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare t public.teachers; st public.session_types; v_owner boolean; d date; w record; ws timestamp[]; we timestamp[]; k int;
  c timestamptz; wend timestamptz; dur interval; stp interval; busy_end timestamptz; ov text;
begin
  if auth.uid() is null then raise exception 'login required'; end if;
  select * into t from public.teachers where id=p_teacher;
  select * into st from public.session_types where id=p_session_type and teacher_id=p_teacher and is_active;
  v_owner := t.id=auth.uid() or public.is_admin();
  if t.id is null or st.id is null or (not t.is_active and not v_owner) then raise exception 'invalid session'; end if;
  p_days := least(greatest(coalesce(p_days,28),1),60);
  p_from := coalesce(p_from,(now() at time zone t.timezone)::date);
  dur := make_interval(mins=>st.duration_min); stp := make_interval(mins=>st.duration_min+st.buffer_min);
  for d in select g::date from generate_series(p_from,p_from+p_days-1,interval '1 day') g loop
    ws:=array[]::timestamp[]; we:=array[]::timestamp[];
    for w in select (d+x.s) as a,(d+x.e) as b from (
        select r.start_time s,r.end_time e from public.availability_rules r where r.teacher_id=p_teacher and r.weekday=extract(dow from d)::int
          and not exists(select 1 from public.availability_exceptions x where x.teacher_id=p_teacher and x.on_date=d)
        union all select x.start_time,x.end_time from public.availability_exceptions x
          where x.teacher_id=p_teacher and x.on_date=d and x.is_available and x.start_time is not null and x.end_time is not null) x order by 1 loop
      if array_length(ws,1) is null or w.a > we[array_length(we,1)] then ws:=ws||w.a; we:=we||w.b;
      else we[array_length(we,1)] := greatest(we[array_length(we,1)],w.b); end if;
    end loop;
    for k in 1..coalesce(array_length(ws,1),0) loop
      c := ws[k] at time zone t.timezone; wend := we[k] at time zone t.timezone;
      while c+dur <= wend loop
        select max(b.blocked_until) into busy_end from public.bookings b
          where b.teacher_id=p_teacher and b.status='confirmed' and b.starts_at < c+stp and b.blocked_until > c;
        if busy_end is not null then
          if coalesce(t.clean_session_times,false) and not v_owner then c := c + stp; else c := busy_end; end if;
          continue;
        end if;
        select case when exists(select 1 from public.booking_slot_overrides o where o.teacher_id=p_teacher and o.action='closed' and o.slot_start < c+dur and o.slot_start+interval '30 minutes' > c) then 'closed' when exists(select 1 from public.booking_slot_overrides o where o.teacher_id=p_teacher and o.action='jit' and c>=o.slot_start and c<o.slot_start+interval '30 minutes') then 'jit' end into ov; /* cells */
        if c >= now() then
          if ov='closed' then
            if v_owner then slot_start:=c; slot_end:=c+dur; state:='closed'; return next; end if;
          elsif v_owner or ov='jit' or t.on_the_spot_booking or c >= now()+interval '8 hours' then
            slot_start:=c; slot_end:=c+dur; state:=case when ov='jit' then 'jit' else 'available' end; return next;
          end if;
        end if;
        c := c + stp;
      end loop;
    end loop;
  end loop;
end $function$
;

-- Students can book at most 20 weekly lessons at once (the teacher can still book up to 52 for a student).
CREATE OR REPLACE FUNCTION public.book_lesson(p_teacher uuid, p_session_type uuid, p_starts timestamp with time zone, p_student text, p_phone text, p_notes text, p_mode text DEFAULT 'weekly'::text, p_count integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare st public.session_types; t public.teachers; v_series uuid; v_first uuid; v_id uuid; v_local timestamp; v_start timestamptz;
  v_day date; v_time time; n int; i int; v_reason text; v_created int:=0; v_skipped jsonb:='[]'::jsonb; v_name text; v_phone text; v_notes text;
begin
  if auth.uid() is null then raise exception 'login required'; end if;
  if p_mode is null or p_mode not in ('once','weekly','fixed') then raise exception 'invalid booking mode'; end if;
  if p_mode='fixed' and (p_count is null or p_count not between 2 and 52) then raise exception 'recurrence count must be between 2 and 52'; end if;
  if p_mode='fixed' and p_count>20 and auth.uid() is distinct from p_teacher then raise exception 'recurrence count must be between 2 and 20'; end if;
  if p_starts is null then raise exception 'start time required'; end if;
  v_name:=trim(coalesce(p_student,'')); v_phone:=nullif(trim(coalesce(p_phone,'')),''); v_notes:=nullif(trim(coalesce(p_notes,'')),'');
  perform public._bmc_valid_text(v_name,v_phone,v_notes);
  select * into st from public.session_types where id=p_session_type and teacher_id=p_teacher and is_active;
  select * into t from public.teachers where id=p_teacher and is_active;
  if st.id is null or t.id is null then raise exception 'invalid session'; end if;
  if p_mode='weekly' and not coalesce(t.allow_forever_booking,false) then
    raise exception 'Ongoing weekly bookings are turned off for this teacher. Choose a fixed number of lessons.';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(p_teacher::text,0));
  v_reason := public._bmc_check_slot(t,st,p_starts,auth.uid(),true);
  if v_reason is not null then raise exception '%', v_reason; end if;
  v_local := p_starts at time zone t.timezone; v_day := v_local::date; v_time := v_local::time;
  n := case p_mode when 'once' then 1 when 'fixed' then p_count
       else greatest(1, (((now() at time zone t.timezone)::date + 84) - v_day)/7 + 1) end;
  if p_mode<>'once' then
    insert into public.booking_series(teacher_id,booker_id,session_type_id,student_name,contact_phone,notes,timezone,weekday,local_time,starts_on,
      occurrence_count,occurrences_created,recurrence_mode)
    values(p_teacher,auth.uid(),p_session_type,v_name,v_phone,v_notes,t.timezone,extract(dow from v_local)::int,v_time,v_day,
      case when p_mode='fixed' then p_count else 0 end,0,case when p_mode='fixed' then 'fixed' else 'open' end) returning id into v_series;
  end if;
  for i in 0..n-1 loop
    v_start := ((v_day + i*7) + v_time) at time zone t.timezone;
    if i>0 then
      v_reason := public._bmc_check_slot(t,st,v_start,auth.uid(),false);
      if v_reason is not null then
        v_skipped := v_skipped || jsonb_build_array(jsonb_build_object('starts_at',v_start,'reason',v_reason));
        insert into public.booking_series_exceptions(series_id,original_starts_at) values(v_series,v_start) on conflict do nothing;
        continue;
      end if;
    end if;
    begin
      insert into public.bookings(teacher_id,session_type_id,booker_id,student_name,contact_phone,notes,starts_at,ends_at,blocked_until,meeting_url,price_cents,series_id,booking_source)
      values(p_teacher,p_session_type,auth.uid(),v_name,v_phone,v_notes,v_start,v_start+make_interval(mins=>st.duration_min),
        v_start+make_interval(mins=>st.duration_min+st.buffer_min),t.meeting_url,st.price_cents,v_series,case when p_teacher=auth.uid() then 'teacher' else 'self' end)
      returning id into v_id;
      v_created:=v_created+1; if v_first is null then v_first:=v_id; end if;
    exception when exclusion_violation or unique_violation then
      if i=0 then raise exception 'slot already taken'; end if;
      v_skipped := v_skipped || jsonb_build_array(jsonb_build_object('starts_at',v_start,'reason','slot already taken'));
      insert into public.booking_series_exceptions(series_id,original_starts_at) values(v_series,v_start) on conflict do nothing;
    end;
  end loop;
  if v_series is not null then update public.booking_series set occurrences_created=v_created where id=v_series; end if;
  return jsonb_build_object('booking_id',v_first,'series_id',v_series,'created',v_created,'requested',n,'skipped',v_skipped);
end $function$;

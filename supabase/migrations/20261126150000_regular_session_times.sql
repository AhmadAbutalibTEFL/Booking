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

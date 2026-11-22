-- Teacher-gated ongoing weekly bookings (off by default).
-- Preserves: all fixed-count (1-52) choices, one-off bookings, and every existing
-- booking/series row. Nothing is rewritten. Existing series keep their stored counts.
-- Server enforcement: book_lesson rejects NEW 'weekly' (ongoing) bookings unless the
-- teacher has turned on "Allow ongoing weekly bookings" in settings.

alter table public.teachers
  add column if not exists allow_forever_booking boolean not null default false;

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
end $function$


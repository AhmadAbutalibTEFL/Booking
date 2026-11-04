-- BookMyClass: admin dashboard data endpoint
-- Run AFTER the supplied master database upgrade and existing base schema.
-- Exposes aggregate platform metrics and public teacher profile fields only.

begin;

create or replace function public.admin_platform_overview()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_result jsonb;
begin
  if auth.uid() is null then
    raise exception 'login required';
  end if;

  if not public.is_admin() then
    raise exception 'admin access required';
  end if;

  select jsonb_build_object(
    'stats', (
      select jsonb_build_object(
        'total_teachers', count(*)::int,
        'active_teachers', (count(*) filter (where t.is_active))::int,
        'total_bookings', (select count(*)::int from public.bookings b),
        'confirmed_bookings', (select count(*)::int from public.bookings b where b.status = 'confirmed'),
        'cancelled_bookings', (select count(*)::int from public.bookings b where b.status = 'cancelled'),
        'teacher_created_bookings', (
          select count(*)::int
          from public.bookings b
          where b.booker_id = b.teacher_id
        )
      )
      from public.teachers t
    ),
    'teachers', (
      select coalesce(
        jsonb_agg(
          jsonb_build_object(
            'id', t.id,
            'slug', t.slug,
            'display_name', t.display_name,
            'timezone', t.timezone,
            'is_active', t.is_active,
            'created_at', t.created_at
          ) order by t.created_at desc nulls last
        ),
        '[]'::jsonb
      )
      from public.teachers t
    )
  ) into v_result;

  return v_result;
end;
$$;

revoke all on function public.admin_platform_overview() from public, anon;
grant execute on function public.admin_platform_overview() to authenticated;

notify pgrst, 'reload schema';
commit;

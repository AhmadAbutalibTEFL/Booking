# Supabase backup notes

The database schema is NOT stored in this repo yet. Do this once and keep it up to date:

1. Supabase dashboard > SQL Editor > run `select * from pg_policies where schemaname='public';` and save the result here as `policies.txt`.
2. Dashboard > Database > Backups: confirm daily backups are on.
3. Export the table and function definitions into `schema.sql` (Dashboard > Database > Schema, or the Supabase CLI: `supabase db dump -f supabase/schema.sql`).

Tables the app uses: profiles, teachers, session_types, availability_rules, availability_exceptions, bookings, notifications.
Functions it calls: register_teacher, book_lesson, edit_booking, cancel_booking, reschedule_booking, get_available_slots, get_busy_times, get_booking_contact, get_my_teacher, restore_my_profile, maintain_my_recurring_bookings, get_booking_slot_overrides, get_teacher_booking_bookers, admin_platform_overview, admin_get_audit.
Never commit passwords, service_role keys or database connection strings.

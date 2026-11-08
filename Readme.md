# BookMyClass

A bilingual (English / Arabic, with right-to-left layout) lesson booking platform. Teachers publish their availability, and students or parents book one-off, weekly or fixed-count lessons through the teacher's own booking page.

- Live site: https://booking-kappa-amber.vercel.app/
- Hosting: Vercel (static site)
- Backend: Supabase (PostgreSQL, Auth, Realtime)
- Sign-in: Google

## Features

**Booking**
- Public teacher pages (`/t/<teacher-slug>`)
- One-off, weekly-until-ended and fixed-count (1–52) bookings
- Conflict-free slot generation (duration, buffer time, existing bookings, date exceptions)
- Per-slot closing and Just-in-Time (JIT) booking
- Edit or cancel a single lesson, or this and all future lessons
- Add to calendar (.ics)

**Teacher tools**
- Weekly schedule grid with 30-minute cells, search by student name or phone, and jump-to-date
- Availability, lesson types, booking link sharing
- Mark attendance (attended / no-show)
- Notification centre (new bookings, edits, cancellations) with live updates
- Pause or delete the account

**Students and parents**
- My lessons, rewards, badges, levels and a cosmetic points store
- Profile avatar, frames, titles and confetti styles

**Admin**
- Teacher directory, activate or deactivate teachers, platform statistics, audit log, invites
- Admin actions are enforced in the database, not only in the page

**General**
- Light, dark and system theme, collapsible sidebar, Arabic and English
- Accessibility basics: labelled controls, keyboard focus handling, skip link, reduced-motion support
- On-screen error box if the page fails to load

## Tech stack

| Part | Technology |
|---|---|
| Frontend | A single `index.html` (plain JavaScript, no build step) |
| Database and auth | Supabase (PostgreSQL, Row Level Security, Realtime) |
| Hosting | Vercel |
| Libraries (CDN, pinned) | supabase-js, canvas-confetti |

## Repository structure

```
index.html            The whole web app
privacy.html          Privacy policy
terms.html            Terms of service
sql/                  Database migrations (run in order, see below)
tests/                Optional test scripts (not used by the website)
README.md
```

## Database setup (Supabase)

Run the files in the Supabase **SQL Editor**, one at a time, in this order. Each is safe to run twice. Take a backup first (Database → Backups).

| Order | File | Purpose |
|---|---|---|
| 0 | Original base schema and earlier migrations | Tables, policies, base functions |
| 1 | `sql/10_bookmyclass_v2.sql` | Booking engine, slot generator, edit/cancel, security |
| 2 | `sql/12_accounts_admin.sql` | Pause/delete account, admin controls, audit log |
| 3 | `sql/14_rewards.sql` | Points, badges, store, attendance |
| 4 | `sql/16_notifications_and_cells.sql` | Notification centre, 30-minute closed/JIT cells |

Rollback scripts: `11_rollback.sql`, `13_rollback_accounts.sql`, `15_rollback_rewards.sql`, `17_rollback_notifications.sql`. Each removes only what its migration added and does not delete booking data.

Test scripts (`20_`–`23_tests*.sql`) abort at the end and keep nothing. Run them only on a test project.

## Configuration

1. In `index.html`, set the Supabase project URL and the public anon key (search for `createClient`). The anon key is meant to be public. Security comes from Row Level Security and the database functions, so **never put the `service_role` key in this repository**.
2. Supabase → Authentication → Providers: enable **Google**.
3. Supabase → Authentication → URL Configuration: add your site address and, for preview deployments, `https://*.vercel.app/**` under Redirect URLs.
4. Realtime (live notifications): the migration adds the `notifications` table to the `supabase_realtime` publication automatically.

## Deployment

- `main` is production. Vercel deploys it automatically.
- Never commit straight to `main`. Work on a branch such as `dev-feature-name`. Vercel creates a private preview link for every branch.
- Preview links use the same database as production, so take a backup before running any SQL.
- Merge to `main` only after testing on the preview.

## Testing

The `tests/` folder is optional and not part of the website:

- `sql/20_`–`23_` run in the SQL editor and report PASS/FAIL.
- The JavaScript tests run in Node with `jsdom` (a simulated browser).

These tests do not replace checking the site by hand in a real browser, especially on a phone and in Arabic.

## Third-party components

| Component | Licence | Use |
|---|---|---|
| supabase-js | MIT | Database, auth and realtime client |
| canvas-confetti | ISC | Confetti animation |

The scripts are loaded from a CDN at pinned versions. Adding Subresource Integrity (`integrity=`) hashes is recommended.

## Known limitations

- Notifications arrive only while the site is open in a browser. Email, WhatsApp or push alerts when the site is closed need an email or messaging service to be connected.
- Reward points are per account, so a parent booking for several children shares one profile.
- The store is cosmetic only.
- Not yet built: installable app (PWA), "download my data", bulk closing of dates, drag-and-drop rescheduling.

## Security notes

- Row Level Security is enabled on all tables. Booking, cancellation, editing, attendance and admin actions are database functions that check who is calling.
- Teachers can see account details only for their own bookings.
- Deleting an account cancels upcoming lessons and removes personal data. Past lesson records stay for the other people involved.
- Report security problems privately to AhmedAbutalib97@Gmail.com .

## Licence

All rights reserved.

# BookMyClass (Booking)

A single-file web app where students and parents book one-off or weekly lessons with independent teachers. English and Arabic. Google sign-in, teacher dashboards, availability, rewards and leaderboard, notifications, WhatsApp and Google Calendar links.

## How it works
- Everything is in `index.html` (HTML, CSS, JavaScript).
- Backend: Supabase (database, Google sign-in, server-side functions).
- Hosting: any static host. To try locally, open `index.html` in a browser.

## Configuration
The Supabase URL and the publishable (anon) key sit near the top of the script in `index.html`. The anon key is designed to be public. **Never put a `service_role` key in this repo.** Security comes from Row Level Security in Supabase, see `supabase/README.md`.

## Security notes
- CDN scripts are pinned to exact versions with Subresource Integrity hashes. If you upgrade one, regenerate its hash.
- A Content-Security-Policy meta tag limits where scripts and connections can go. If you add a new external service, add its domain to the policy in `index.html`.
- If you change the Supabase project URL, update the `connect-src` entry in the policy too.

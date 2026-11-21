# Booking-notifications edge function: source + auth guard

This directory puts the booking-notifications Edge Function under version
control for the first time (the repo previously had no function source; see
supabase/README.md). `index.ts` is the live function's code with ONE change:
a WEBHOOK_SECRET header check at the top. Today the function answers any
unauthenticated call; after this deploy it only answers calls carrying the
secret header.

If the dashboard function has a different name than this directory, rename
the directory to match - the code is identical either way.

## Deploy order (safe: the live function tolerates the new header at every step)

1. Generate the shared secret (stored in a password manager, never in chat,
   never in this repo).
2. Supabase dashboard > Edge Functions > Secrets: add `WEBHOOK_SECRET`
   with that value.
3. Add the same value as an HTTP header on the database webhook that calls
   this function (Dashboard > Database > Webhooks > Edit > HTTP Headers).
   The current no-auth function ignores extra headers, so nothing breaks yet.
4. Deploy this `index.ts` to the function. From now on, calls without the
   header get HTTP 401 and change nothing.
5. Make a test booking and confirm notifications still arrive.

Rollback: re-deploy the previous function code (preserved separately by
Instinct; the only difference is the header check).

Note: the webhook's header value is stored inside the webhook's trigger
definition in the database. Do not share trigger-definition exports after
step 3 - they will contain the secret in plain text.

## Test status

Tested locally with Deno and fully-local mocks (no live Supabase, no live
Brevo): wrong/missing token -> 401 with zero downstream calls; correct
token -> 200 with notification claims kept; downstream failure -> 502 with
claims released; missing env -> 401. `deno check` clean.
Not yet tested against the live project.

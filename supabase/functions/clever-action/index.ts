import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// ---------------------------------------------------------------------------
// Supabase client (unchanged behaviour: service_role var first, JSON fallback)
// ---------------------------------------------------------------------------
function getSupabaseKey(): string {
  const single = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (single) return single;
  const raw = Deno.env.get("SUPABASE_SECRET_KEYS");
  if (raw) {
    try {
      const parsed = JSON.parse(raw);
      if (typeof parsed === "string") return parsed;
      if (parsed?.default) return parsed.default;
      const first = Object.values(parsed)[0];
      if (typeof first === "string") return first;
    } catch {
      return raw;
    }
  }
  throw new Error("No Supabase secret key found in environment");
}

const supabase = createClient(Deno.env.get("SUPABASE_URL")!, getSupabaseKey());

const BREVO_API_KEY = Deno.env.get("BREVO_API_KEY")!;
const SENDER_EMAIL = "bookmyclass.notifications@gmail.com";

// <helpers>
// ---------------------------------------------------------------------------
// Branding. EDIT THESE to match the website (colours from your :root CSS).
// ---------------------------------------------------------------------------
const SITE_URL = "https://booking-kappa-amber.vercel.app";
const BRAND = {
  primary: "#5B5BF0",
  accent: "#2FC4B2",
  gradient: "linear-gradient(135deg, #5b5bf0, #2fc4b2)",
  pageBg: "#F4F5FB",
  card: "#FFFFFF",
  soft: "#EEF0FF",
  text: "#1F2937",
  muted: "#6B7280",
  border: "#E5E7EB",
  onAccent: "#0F172A",
  radius: "14px",
  font: "system-ui, -apple-system, 'Segoe UI', Tahoma, sans-serif",
};

// ---------------------------------------------------------------------------
// Small utilities
// ---------------------------------------------------------------------------
function esc(v: unknown): string {
  return String(v ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

function isEmail(v: unknown): v is string {
  return typeof v === "string" && /^[^\s@<>]+@[^\s@<>]+\.[^\s@<>]+$/.test(v.trim());
}

function httpUrl(v: unknown): string | null {
  if (typeof v !== "string") return null;
  try {
    const u = new URL(v.trim());
    return u.protocol === "https:" || u.protocol === "http:" ? u.toString() : null;
  } catch {
    return null;
  }
}

// Returns the IANA zone if the runtime accepts it, otherwise null.
function safeTz(tz: unknown): string | null {
  if (typeof tz !== "string" || !tz.trim()) return null;
  try {
    new Intl.DateTimeFormat("en", { timeZone: tz.trim() });
    return tz.trim();
  } catch {
    return null;
  }
}

// ---------------------------------------------------------------------------
// Timezone formatting: one UTC instant -> the recipient's own local time.
// ---------------------------------------------------------------------------
type Fmt = {
  date: string;
  start: string;
  end: string;
  tzLabel: string;
  duration: number;
};

function formatSession(startIso: string, endIso: string, tz: string, lang: string): Fmt {
  const s = new Date(startIso);
  const e = new Date(endIso);
  const locale = lang === "ar" ? "ar-u-ca-gregory-nu-latn" : "en-GB";

  const date = new Intl.DateTimeFormat(locale, {
    timeZone: tz, weekday: "long", year: "numeric", month: "long", day: "numeric",
  }).format(s);

  const timeFmt = new Intl.DateTimeFormat("en-GB", {
    timeZone: tz, hour: "2-digit", minute: "2-digit", hour12: false,
  });

  // Abbreviation (CET/CEST/GMT+3...) comes from the IANA zone, so DST is automatic.
  const abbr = new Intl.DateTimeFormat("en-GB", { timeZone: tz, timeZoneName: "short" })
    .formatToParts(s).find((p) => p.type === "timeZoneName")?.value ?? "";

  return {
    date,
    start: timeFmt.format(s),
    end: timeFmt.format(e),
    tzLabel: abbr ? `${abbr} (${tz})` : tz,
    duration: Math.max(0, Math.round((e.getTime() - s.getTime()) / 60000)),
  };
}

// ---------------------------------------------------------------------------
// Copy (English / Arabic)
// ---------------------------------------------------------------------------
const STR = {
  en: {
    studentSubject: "Your BookMyClass session is confirmed!",
    teacherSubject: "New booking received — BookMyClass",
    studentHeading: "Your session is confirmed!",
    teacherHeading: "New Booking Received",
    hello: (n: string) => `Hello ${n},`,
    studentIntro: (t: string) => `Your session with ${t} is booked. Here are the details:`,
    teacherIntro: (s: string) => `${s} has booked a session with you.`,
    date: "Date", time: "Time", tz: "Timezone", duration: "Duration",
    minutes: (n: number) => `${n} min`,
    teacher: "Teacher", student: "Student", notes: "Student notes",
    meeting: "Meeting link", join: "Join session", ref: "Booking reference",
    studentCta: "View my booking", teacherCta: "Open my dashboard",
    footer: "This is an automatic message from BookMyClass.",
    yourTime: "Times shown in your local timezone",
  },
  ar: {
    studentSubject: "تم تأكيد حصتك على BookMyClass!",
    teacherSubject: "حجز جديد — BookMyClass",
    studentHeading: "تم تأكيد حصتك!",
    teacherHeading: "تم استلام حجز جديد",
    hello: (n: string) => `مرحباً ${n}،`,
    studentIntro: (t: string) => `تم حجز حصتك مع ${t}. إليك التفاصيل:`,
    teacherIntro: (s: string) => `قام ${s} بحجز حصة معك.`,
    date: "التاريخ", time: "الوقت", tz: "المنطقة الزمنية", duration: "المدة",
    minutes: (n: number) => `${n} دقيقة`,
    teacher: "المعلم", student: "الطالب", notes: "ملاحظات الطالب",
    meeting: "رابط الاجتماع", join: "انضم إلى الحصة", ref: "رقم الحجز",
    studentCta: "عرض حجزي", teacherCta: "فتح لوحة التحكم",
    footer: "هذه رسالة تلقائية من BookMyClass.",
    yourTime: "الأوقات معروضة بتوقيتك المحلي",
  },
};

// ---------------------------------------------------------------------------
// Email builder (table layout + inline CSS: Gmail/Outlook safe, no JS)
// ---------------------------------------------------------------------------
type Ctx = {
  role: "student" | "teacher";
  lang: string;
  name: string;
  otherName: string;
  f: Fmt;
  meetingUrl: string | null;
  ref: string | null;
  notes: string | null;
  ctaUrl: string;
};

function buildEmail(c: Ctx): { subject: string; html: string; text: string } {
  const L = c.lang === "ar" ? STR.ar : STR.en;
  const rtl = c.lang === "ar";
  const dir = rtl ? "rtl" : "ltr";
  const align = rtl ? "right" : "left";
  const isStudent = c.role === "student";

  const subject = isStudent ? L.studentSubject : L.teacherSubject;
  const heading = isStudent ? L.studentHeading : L.teacherHeading;
  const intro = isStudent ? L.studentIntro(c.otherName) : L.teacherIntro(c.otherName);
  const cta = isStudent ? L.studentCta : L.teacherCta;
  const durationText = c.f.duration > 0 ? L.minutes(c.f.duration) : "";

  const row = (label: string, value: string) =>
    `<tr>
      <td style="padding:10px 0;border-bottom:1px solid ${BRAND.border};font-size:13px;color:${BRAND.muted};text-align:${align};width:38%;vertical-align:top;">${esc(label)}</td>
      <td style="padding:10px 0;border-bottom:1px solid ${BRAND.border};font-size:15px;color:${BRAND.text};text-align:${align};font-weight:600;vertical-align:top;">${value}</td>
    </tr>`;

  const rows: string[] = [];
  rows.push(row(isStudent ? L.teacher : L.student, esc(c.otherName)));
  if (durationText) rows.push(row(L.duration, esc(durationText)));
  rows.push(row(L.tz, esc(c.f.tzLabel)));
  if (c.ref) rows.push(row(L.ref, esc(c.ref)));
  if (c.notes) {
    rows.push(row(L.notes, `<span style="font-weight:400;">${esc(c.notes).replace(/\n/g, "<br>")}</span>`));
  }

  const brand = `<table role="presentation" cellpadding="0" cellspacing="0" style="margin:0 auto;"><tr>
      <td width="40" height="40" align="center" valign="middle" bgcolor="${BRAND.primary}" style="width:40px;height:40px;border-radius:10px;background:${BRAND.primary};font-family:${BRAND.font};font-size:22px;font-weight:800;color:#FFFFFF;line-height:40px;">B</td>
      <td style="padding:0 0 0 10px;font-family:${BRAND.font};font-size:22px;font-weight:800;color:${BRAND.primary};">BookMyClass</td>
    </tr></table>`;

  const button = (href: string, label: string, bg: string, fg = "#FFFFFF") =>
    `<table role="presentation" cellpadding="0" cellspacing="0" style="margin:0 auto;"><tr>
      <td align="center" bgcolor="${bg}" style="border-radius:999px;">
        <a href="${esc(href)}" target="_blank" style="display:inline-block;padding:14px 32px;font-family:${BRAND.font};font-size:16px;font-weight:700;color:${fg};text-decoration:none;border-radius:999px;">${esc(label)}</a>
      </td></tr></table>`;

  const joinBlock = c.meetingUrl
    ? `<tr><td style="padding:0 0 12px 0;">${button(c.meetingUrl, L.join, BRAND.accent, BRAND.onAccent)}</td></tr>`
    : "";

  const html = `<!DOCTYPE html>
<html lang="${rtl ? "ar" : "en"}" dir="${dir}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="color-scheme" content="light only">
<meta name="supported-color-schemes" content="light">
<title>${esc(subject)}</title>
</head>
<body style="margin:0;padding:0;background:${BRAND.pageBg};font-family:${BRAND.font};">
<div style="display:none;max-height:0;overflow:hidden;opacity:0;color:transparent;">${esc(`${c.f.date}, ${c.f.start}–${c.f.end} (${c.f.tzLabel})`)}</div>
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:${BRAND.pageBg};">
<tr><td align="center" style="padding:24px 12px;">
  <table role="presentation" width="600" cellpadding="0" cellspacing="0" style="width:100%;max-width:600px;">
    <tr><td align="center" style="padding:8px 0 20px 0;">${brand}</td></tr>
    <tr><td style="background:${BRAND.card};border-radius:${BRAND.radius};padding:0;overflow:hidden;border:1px solid ${BRAND.border};">
      <table role="presentation" width="100%" cellpadding="0" cellspacing="0">
        <tr><td bgcolor="${BRAND.primary}" style="background:${BRAND.primary};background-image:${BRAND.gradient};padding:28px 24px;text-align:center;border-radius:${BRAND.radius} ${BRAND.radius} 0 0;">
          <h1 style="margin:0;font-family:${BRAND.font};font-size:26px;line-height:1.25;color:#FFFFFF;">${esc(heading)}</h1>
        </td></tr>
        <tr><td style="padding:28px 24px 8px 24px;font-family:${BRAND.font};color:${BRAND.text};text-align:${align};">
          <p style="margin:0 0 6px 0;font-size:17px;font-weight:600;">${esc(L.hello(c.name))}</p>
          <p style="margin:0;font-size:15px;line-height:1.55;color:${BRAND.muted};">${esc(intro)}</p>
        </td></tr>
        <tr><td style="padding:16px 24px;">
          <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:${BRAND.soft};border-radius:${BRAND.radius};">
            <tr><td align="center" style="padding:22px 16px;font-family:${BRAND.font};">
              <div style="font-size:13px;font-weight:700;letter-spacing:1px;text-transform:uppercase;color:${BRAND.primary};">${esc(L.date)}</div>
              <div style="font-size:20px;font-weight:700;color:${BRAND.text};margin:4px 0 14px 0;">${esc(c.f.date)}</div>
              <div style="font-size:13px;font-weight:700;letter-spacing:1px;text-transform:uppercase;color:${BRAND.primary};">${esc(L.time)}</div>
              <div style="font-size:34px;font-weight:800;color:${BRAND.primary};margin:4px 0 4px 0;direction:ltr;">${esc(c.f.start)} – ${esc(c.f.end)}</div>
              <div style="font-size:13px;color:${BRAND.muted};">${esc(c.f.tzLabel)}</div>
            </td></tr>
          </table>
        </td></tr>
        <tr><td style="padding:4px 24px 12px 24px;font-family:${BRAND.font};">
          <table role="presentation" width="100%" cellpadding="0" cellspacing="0">${rows.join("")}</table>
        </td></tr>
        <tr><td style="padding:12px 24px 28px 24px;">
          <table role="presentation" width="100%" cellpadding="0" cellspacing="0">
            ${joinBlock}
            <tr><td>${button(c.ctaUrl, cta, BRAND.primary)}</td></tr>
          </table>
        </td></tr>
      </table>
    </td></tr>
    <tr><td align="center" style="padding:18px 12px;font-family:${BRAND.font};font-size:12px;line-height:1.5;color:${BRAND.muted};">
      ${esc(L.yourTime)}<br>${esc(L.footer)}
    </td></tr>
  </table>
</td></tr>
</table>
</body>
</html>`;

  const text = [
    heading,
    "",
    L.hello(c.name),
    intro,
    "",
    `${L.date}: ${c.f.date}`,
    `${L.time}: ${c.f.start} - ${c.f.end} (${c.f.tzLabel})`,
    durationText ? `${L.duration}: ${durationText}` : "",
    `${isStudent ? L.teacher : L.student}: ${c.otherName}`,
    c.ref ? `${L.ref}: ${c.ref}` : "",
    c.notes ? `${L.notes}: ${c.notes}` : "",
    c.meetingUrl ? `${L.meeting}: ${c.meetingUrl}` : "",
    "",
    `${cta}: ${c.ctaUrl}`,
    "",
    L.footer,
  ].filter((l, i, a) => l !== "" || a[i - 1] !== "").join("\n");

  return { subject, html, text };
}
// </helpers>

// ---------------------------------------------------------------------------
// Brevo
// ---------------------------------------------------------------------------
function errText(e: unknown): string {
  if (e instanceof Error) return e.message;
  if (e && typeof e === "object") {
    const o = e as { code?: string; message?: string };
    return o.message ? `${o.code ?? ""} ${o.message}`.trim() : JSON.stringify(e);
  }
  return String(e);
}

async function sendBrevo(to: string, name: string, mail: { subject: string; html: string; text: string }) {
  const response = await fetch("https://api.brevo.com/v3/smtp/email", {
    method: "POST",
    headers: {
      "api-key": BREVO_API_KEY,
      "Content-Type": "application/json",
      "Accept": "application/json",
    },
    body: JSON.stringify({
      sender: { name: "BookMyClass", email: SENDER_EMAIL },
      to: [{ email: to, name }],
      subject: mail.subject,
      htmlContent: mail.html,
      textContent: mail.text,
    }),
  });

  if (!response.ok) {
    const body = (await response.text()).slice(0, 300); // never log keys or addresses we don't need
    throw new Error(`Brevo ${response.status}: ${body}`);
  }
  await response.text();
}

// ---------------------------------------------------------------------------
// Handler
// ---------------------------------------------------------------------------
// ---------------------------------------------------------------------------
// Caller check: the database webhook authenticates with a DEDICATED random token
// sent on a CUSTOM header, x-bmc-webhook-secret. The webhook's existing apikey
// header (the project key the gateway already accepts) is deliberately left
// untouched by this design, so activation never moves a working credential.
// Verify JWT stays OFF for this function (the webhook sends no user JWT), so
// this check is the endpoint's only gate - do not remove it.
// The token exists in exactly two places: this function's WEBHOOK_SECRET env var
// (Project Settings > Edge Functions > Secrets) and the webhook's
// x-bmc-webhook-secret header (Integrations > Webhooks). No project API key is
// accepted here, so a leaked project key cannot be used to trigger emails.
// Fail closed: missing env or header -> 401.
// Compared via SHA-256 digests so the comparison is constant-time.
async function isWebhookCaller(k: string): Promise<boolean> {
  try {
    const expected = Deno.env.get("WEBHOOK_SECRET");
    if (!expected || !k) return false;
    const enc = new TextEncoder();
    const [a, b] = await Promise.all([
      crypto.subtle.digest("SHA-256", enc.encode(k)),
      crypto.subtle.digest("SHA-256", enc.encode(expected)),
    ]);
    const va = new Uint8Array(a);
    const vb = new Uint8Array(b);
    if (va.length !== vb.length) return false;
    let diff = 0;
    for (let i = 0; i < va.length; i++) diff |= va[i] ^ vb[i];
    return diff === 0;
  } catch {
    return false;
  }
}

Deno.serve(async (req) => {
  const presentedKey = req.headers.get("x-bmc-webhook-secret") ?? "";
  if (!presentedKey || !(await isWebhookCaller(presentedKey))) {
    return Response.json({ error: "Unauthorized" }, { status: 401 });
  }

  try {
    const payload = await req.json();
    const notification = payload.record;

    if (!notification?.booking_id) {
      return Response.json({ error: "Missing booking_id" }, { status: 400 });
    }
    if (notification.kind !== "booking_new") {
      return Response.json({ success: true, skipped: true });
    }

    const { data: booking, error: bookingError } = await supabase
      .from("bookings").select("*").eq("id", notification.booking_id).single();
    if (bookingError || !booking) {
      throw new Error(`Booking: ${bookingError?.message ?? "Not found"}`);
    }

    const { data: teacherRow, error: teacherError } = await supabase
      .from("teachers").select("id, display_name, timezone, meeting_url")
      .eq("id", booking.teacher_id).single();
    if (teacherError || !teacherRow) {
      throw new Error(`Teacher: ${teacherError?.message ?? "Not found"}`);
    }

    const { data: profiles, error: profilesError } = await supabase
      .from("profiles").select("id, full_name, email, language, timezone, site_language")
      .in("id", [booking.booker_id, booking.teacher_id]);
    if (profilesError) throw profilesError;

    const studentProfile = profiles?.find((p) => p.id === booking.booker_id);
    const teacherProfile = profiles?.find((p) => p.id === booking.teacher_id);

    const studentName = booking.student_name || studentProfile?.full_name || "Student";
    const teacherName = teacherRow.display_name || teacherProfile?.full_name || "Teacher";

    // Each recipient gets their OWN timezone. Fallback is explicit UTC, never the other
    // person's zone.
    const studentTz = safeTz(studentProfile?.timezone) ?? "UTC";
    const teacherTz = safeTz(teacherRow.timezone) ?? "UTC";

    const ref = String(booking.id).slice(0, 8).toUpperCase();
    const meetingUrl = httpUrl(booking.meeting_url) ?? httpUrl(teacherRow.meeting_url);
    const notes = typeof booking.notes === "string" && booking.notes.trim()
      ? booking.notes.trim().slice(0, 500)
      : null;

    const recipients = [
      {
        role: "student" as const,
        col: "student_email_sent_at",
        email: studentProfile?.email,
        name: studentName,
        lang: (studentProfile?.site_language ?? studentProfile?.language) === "ar" ? "ar" : "en",
        tz: studentTz,
        otherName: teacherName,
        notes: null as string | null, // students don't need their own notes echoed
      },
      {
        role: "teacher" as const,
        col: "teacher_email_sent_at",
        email: teacherProfile?.email,
        name: teacherName,
        lang: (teacherProfile?.site_language ?? teacherProfile?.language) === "ar" ? "ar" : "en",
        tz: teacherTz,
        otherName: studentName,
        notes,
      },
    ];

    async function deliver(r: (typeof recipients)[number]) {
      if (!isEmail(r.email)) return "skipped_no_valid_email";

      // Atomic claim: only one webhook delivery can flip the column from NULL.
      const { data: claimed, error: claimError } = await supabase
        .from("bookings")
        .update({ [r.col]: new Date().toISOString() })
        .eq("id", booking.id)
        .is(r.col, null)
        .select("id");
      if (claimError) throw new Error(`Claim: ${claimError.code ?? ""} ${claimError.message}`);
      if (!claimed || claimed.length === 0) return "skipped_duplicate";

      console.log("notify-email context:", JSON.stringify({ role: r.role, tz: r.tz, lang: r.lang }));
      try {
        const mail = buildEmail({
          role: r.role,
          lang: r.lang,
          name: r.name,
          otherName: r.otherName,
          f: formatSession(booking.starts_at, booking.ends_at, r.tz, r.lang),
          meetingUrl,
          ref,
          notes: r.notes,
          ctaUrl: SITE_URL,
        });
        await sendBrevo(r.email.trim(), r.name, mail);
        return "sent";
      } catch (err) {
        // Release the claim so a retry can try again.
        await supabase.from("bookings").update({ [r.col]: null }).eq("id", booking.id);
        throw err;
      }
    }

    const results = await Promise.allSettled(recipients.map(deliver));

    const report = results.map((res, i) => ({
      recipient: recipients[i].role,
      status: res.status === "fulfilled" ? res.value : "failed",
      error: res.status === "rejected"
        ? errText(res.reason)
        : undefined,
    }));

    for (const item of report) {
      if (item.status === "failed") {
        console.error(`notify-email ${item.recipient} failed:`, item.error);
      }
    }
    console.log("Email results:", JSON.stringify(report.map(({ recipient, status }) => ({ recipient, status }))));

    const success = report.every((r) => r.status !== "failed");
    return Response.json({ success, emails: report }, { status: success ? 200 : 502 });
  } catch (error) {
    console.error("notify-email error:", error);
    return Response.json(
      { error: error instanceof Error ? error.message : "Unknown error" },
      { status: 500 },
    );
  }
});
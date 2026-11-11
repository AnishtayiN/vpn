// VoidrauVPN License Bot + API — Cloudflare Worker (single file). v2.1.0
//
// Deploy: wrangler deploy (or paste in the dashboard). Needs a KV namespace
// bound as LICENSES and the secret BOT_TOKEN (from @BotFather).
//
//   wrangler kv namespace create LICENSES
//   wrangler secret put BOT_TOKEN
//   wrangler secret put ADMIN_ID   (your numeric telegram id)
//
// Features (v2.0):
//   • /start            → unified Home v2 (rich status card, progress bar,
//                          licence key copy-on-tap, quick actions)
//   • تست رایگان        → 24h trial key (once per telegram id)
//   • خرید لایسنس       → plans, payment details → admin approves or rejects
//                          (+ receipt status tracking: receiptStatus:{tid})
//   • 🎁 هدیه دادن      → gift days from stored credit only (credit:{tid})
//   • ✅ چک‌این روزانه  → 1 point/day (Asia/Tehran), streak; 7 points = 1 credit day
//   • 👥 دعوت دوستان    → personal referral link; 1 week credit per 3 joins
//                          + referral leaderboard (top 10, first names only)
//   • ⏰ یادآوری انقضا  → scheduled() daily + opportunistic check on /start & status
//   • 🆘 پشتیبانی واقعی → FAQ menu + write-to-support with admin reply mode
//   • 📖 راهنما         → per-platform guides (Android / Windows / iOS)
//   • 📱 نشست‌ها        → sessions inside the licence object (lic.sessions,
//                          lic.maxUsers): device registration on /api/license,
//                          409 session-limit, revoke / revoke-all, bot
//                          sessions page, per-plan maxUsers (admin)
//   • 📥 دانلود         → latest GitHub release files sent directly in-chat
//                          (1h cache + stale fallback + direct release link;
//                          per-platform list; over-limit files get a direct
//                          download link instead of a dead end)
//   • /panel            → interactive admin panel + live stat cards + expiring list
//   • /setusers <key> <1..5> → admin: set a licence's maxUsers
//   • /find <id|key>    → search any user or license key details
//                          (+ maxUsers, session count, change buttons)
//   • /gen <days> [tid] → admin: mint a key
//   • /ok <tid> <days>  → admin: approve a pending purchase
//   • /adddays <id> <d> → admin: add bonus days to existing license
//   • /revoke <id|key>  → admin: revoke an abusive or refunded license
//   • /fix <tid>        → admin: upgrade user plan to paid
//   • /id               → show numeric telegram ID
//
// HTTP API (used by the app):
//   GET  /api/license?key=...[&deviceId=...&deviceName=...&platform=...&appVersion=...]
//        → { ok, plan, expiresAt, serverTime, remainingSeconds, isPaid,
//            maxUsers, activeSessions, sessionId, sessions }
//        → 409 { ok:false, error:'session-limit', maxUsers, activeCount, sessions }
//          when the licence is at its device limit and this device is new
//   GET  /api/status?key=...[&deviceId=...]
//        → same shape as /license + sessionActive (this device's session
//          still exists) when deviceId is given
//   POST /api/sessions/revoke     { key, sessionId, deviceId } → { ok, sessions }
//   POST /api/sessions/revoke-all { key, deviceId, keepSessionId? } → { ok, sessions }
//   GET  /api/health            → { ok, service, time, version }
//   POST /api/trial             → { ok, key, expiresAt, serverTime }

const BOT_VERSION = '2.1.0';

const DEFAULT_PLANS = [
  { id: 'm1', label: '۱ ماهه — ۱۰۰ هزار تومان', days: 30, maxUsers: 1 },
  { id: 'm3', label: '۳ ماهه — ۲۵۰ هزار تومان', days: 90, maxUsers: 2 },
  { id: 'm12', label: 'یک‌ساله — ۸۰۰ هزار تومان', days: 365, maxUsers: 3 },
];
const TRIAL_DAYS = 1;

const plansOf = async (env) => {
  try {
    const p = JSON.parse((await env.LICENSES.get('setting:plans')) || 'null');
    if (Array.isArray(p) && p.length) return p;
  } catch (_) {}
  return DEFAULT_PLANS;
};

const trialDaysOf = async (env) => {
  const d = parseInt((await env.LICENSES.get('setting:trialDays')) || '');
  return d && d > 0 ? d : TRIAL_DAYS;
};

const REFERRAL_REWARD_JOINS = 3; // every N joins
const REFERRAL_REWARD_DAYS = 7; // → N days credit

function keygen() {
  const seg = () =>
    crypto.randomUUID().replace(/-/g, '').slice(0, 4).toUpperCase();
  return `VDRV-${seg()}-${seg()}-${seg()}`;
}

function json(data, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { 'content-type': 'application/json; charset=utf-8' },
  });
}

function formatJalali(sec) {
  if (!sec) return '—';
  try {
    return new Date(sec * 1000).toLocaleDateString('fa-IR', {
      year: 'numeric',
      month: '2-digit',
      day: '2-digit',
      timeZone: 'Asia/Tehran',
    });
  } catch (_) {
    return new Date(sec * 1000).toISOString().slice(0, 10);
  }
}

function formatDuration(sec) {
  if (!sec || sec <= 0) return 'منقضی شده';
  const days = Math.floor(sec / 86400);
  const hours = Math.floor((sec % 86400) / 3600);
  if (days > 0) {
    return hours > 0 ? `${days} روز و ${hours} ساعت` : `${days} روز`;
  }
  const mins = Math.floor((sec % 3600) / 60);
  return `${hours} ساعت و ${mins} دقیقه`;
}

// ── v2.0 helpers ────────────────────────────────────────────────────────
// Calendar date (YYYY-MM-DD) in Asia/Tehran — the single source of truth
// for daily check-ins and once-a-day expiry reminders.
function tehranDate(d = new Date()) {
  try {
    return d.toLocaleDateString('en-CA', { timeZone: 'Asia/Tehran' });
  } catch (_) {
    return d.toISOString().slice(0, 10);
  }
}

function tehranYesterday() {
  return tehranDate(new Date(Date.now() - 86400000));
}

// Text progress bar: days left vs total plan days (10 cells).
function progressBar(daysLeft, totalDays) {
  const total = Math.max(0, totalDays || 0);
  const left = Math.max(0, daysLeft || 0);
  const N = 10;
  const filled = total > 0 ? Math.round((left / total) * N) : 0;
  const f = Math.max(0, Math.min(N, filled));
  return '█'.repeat(f) + '░'.repeat(N - f);
}

// Pure check-in math (also unit-tested in /tmp): given yesterday's stored
// state and today's date, compute the new streak / points / bonus day.
function checkinNext(last, streak, points, today, yesterday) {
  if (last === today) return { already: true, streak, points, bonus: false };
  const s = last === yesterday ? streak + 1 : 1;
  let p = points + 1;
  let bonus = false;
  if (p >= 7) {
    p = 0;
    bonus = true;
  }
  return { already: false, streak: s, points: p, bonus };
}

// Pure gift validation (also unit-tested in /tmp).
function giftValidate(me, friendId, days, credit) {
  if (!/^\d{3,}$/.test(String(friendId || '').trim())) return 'bad-id';
  if (String(friendId).trim() === String(me)) return 'self';
  const d = parseInt(days, 10);
  if (!Number.isFinite(d) || d < 1) return 'bad-days';
  if (d > credit) return 'over-credit';
  return null;
}

// Pure leaderboard ranking (also unit-tested in /tmp): sort desc by joins,
// keep first 10, and find the requesting user's 1-based rank (0 = none).
function leaderboardRank(rows, me) {
  const sorted = [...rows].sort((a, b) => b.joins - a.joins || String(a.tid).localeCompare(String(b.tid)));
  const top = sorted.slice(0, 10);
  const idx = sorted.findIndex((r) => String(r.tid) === String(me));
  return { top, rank: idx >= 0 ? idx + 1 : 0, total: sorted.length };
}

// Escape user-controlled text before interpolating it into a legacy-
// Markdown message (H2). Telegram treats * _ [ ` as entities; one unescaped
// character aborts the whole send with HTTP 400, and the failure used to be
// silent (H1). Only mainMenu escaped before; every other interpolation does now.
function escMd(s) {
  return String(s ?? '').replace(/([_*\[`])/g, '\\$1');
}

// ── v2.1: sessions + multi-user plans (pure helpers, unit-tested) ───────
// Sessions live inside the licence object in KV: lic.sessions (array) and
// lic.maxUsers. No new KV key is needed for sessions themselves.
// A session older than 30 days without a lastSeen touch counts as inactive
// for the limit and is marked so in the bot — it is never auto-deleted;
// only the owner (app with key+deviceId, bot with telegramId) removes it.
const STALE_SESSION_SECS = 30 * 86400;
const PLATFORM_FA = { android: 'اندروید', windows: 'ویندوز', ios: 'آیفون', unknown: 'ناشناس' };
const PLATFORM_EMOJI = { android: '🤖', windows: '🪟', ios: '🍎', unknown: '❓' };

function newSessionId() {
  const b = new Uint8Array(8);
  crypto.getRandomValues(b);
  return 'ses_' + [...b].map((x) => x.toString(16).padStart(2, '0')).join('');
}

function normalizePlatform(p) {
  const v = String(p || '').toLowerCase().trim();
  return ['android', 'windows', 'ios'].includes(v) ? v : 'unknown';
}

// Sessions as stored, keeping only well-formed entries.
function normalizeSessions(lic) {
  const arr = Array.isArray(lic?.sessions) ? lic.sessions : [];
  return arr.filter((s) => s && typeof s.id === 'string' && typeof s.deviceId === 'string');
}

function sessionIsActive(s, nowSec) {
  return !!s && Number.isFinite(s.lastSeen) && nowSec - s.lastSeen <= STALE_SESSION_SECS;
}

function activeSessionsOf(lic, nowSec) {
  return normalizeSessions(lic).filter((s) => sessionIsActive(s, nowSec));
}

function sessionSummary(s) {
  return {
    id: s.id,
    name: s.name || '',
    platform: s.platform || 'unknown',
    appVersion: s.appVersion || '',
    lastSeen: s.lastSeen || 0,
  };
}

// Effective device limit for a licence. Existing licences default to 1
// (multi-user is never granted silently); trial is always 1.
function maxUsersOf(lic) {
  if (!lic) return 1;
  if (lic.plan === 'trial') return 1;
  const n = parseInt(lic.maxUsers, 10);
  return Number.isFinite(n) && n >= 1 && n <= 5 ? n : 1;
}

// Effective device limit for a plan object: stored maxUsers wins, else the
// built-in default for the plan id (m1:1, m3:2, m12:3), else 1.
function planMaxUsers(plan) {
  if (!plan) return 1;
  const n = parseInt(plan.maxUsers, 10);
  if (Number.isFinite(n) && n >= 1 && n <= 5) return n;
  return { m1: 1, m3: 2, m12: 3 }[plan.id] || 1;
}

// Register (or touch) a device session on a licence.
// Returns { ok:true, sessionId, sessions, activeCount, maxUsers } or
// { ok:false, limited:true, maxUsers, activeCount, sessions } when the
// licence is at its limit and this deviceId is not registered yet.
// Upgrade migration: an unidentified legacy seat belongs to no known
// device, so the first identified device takes it over instead of being
// blocked by a seat the owner can never name (old apps never enforce
// sessions, so nothing keeps working on the legacy seat is lost).
function registerSession(lic, info, nowSec) {
  const sessions = normalizeSessions(lic);
  const maxUsers = maxUsersOf(lic);
  const devId = String(info.deviceId || '');
  const existing = sessions.find((s) => s.deviceId === devId);
  if (existing) {
    existing.lastSeen = nowSec;
    if (info.name) existing.name = String(info.name).slice(0, 64);
    if (info.platform) existing.platform = info.platform;
    if (info.appVersion) existing.appVersion = String(info.appVersion).slice(0, 32);
    lic.sessions = sessions;
    return { ok: true, sessionId: existing.id, sessions: sessions.map(sessionSummary), activeCount: activeSessionsOf(lic, nowSec).length, maxUsers };
  }
  const active = sessions.filter((s) => sessionIsActive(s, nowSec));
  const legacy = active.find((s) => s.deviceId === 'legacy');
  if (active.length >= maxUsers && !legacy) {
    return { ok: false, limited: true, maxUsers, activeCount: active.length, sessions: active.map(sessionSummary) };
  }
  const ns = {
    id: newSessionId(),
    deviceId: devId,
    name: info.name || `دستگاه ${PLATFORM_FA[info.platform] || 'ناشناس'}`,
    platform: info.platform || 'unknown',
    appVersion: info.appVersion || '',
    firstSeen: nowSec,
    lastSeen: nowSec,
  };
  if (legacy) {
    // Take over the legacy seat (same id, so bot links stay valid).
    ns.id = legacy.id;
    ns.firstSeen = legacy.firstSeen || nowSec;
    sessions[sessions.indexOf(legacy)] = ns;
  } else {
    sessions.push(ns);
  }
  lic.sessions = sessions;
  return { ok: true, sessionId: ns.id, replacedLegacy: !!legacy, sessions: sessions.map(sessionSummary), activeCount: activeSessionsOf(lic, nowSec).length, maxUsers };
}

// Legacy apps never send a deviceId: the licence keeps working, and a
// single anonymous legacy seat is created once (only when the licence has
// no sessions at all) so the owner can see it in the bot and revoke it.
// Returns true when a session was created or touched (caller should save).
function ensureLegacySession(lic, nowSec) {
  const sessions = normalizeSessions(lic);
  if (!sessions.length) {
    lic.sessions = [{
      id: newSessionId(),
      deviceId: 'legacy',
      name: 'دستگاه ناشناس',
      platform: 'unknown',
      appVersion: '',
      firstSeen: nowSec,
      lastSeen: nowSec,
    }];
    return true;
  }
  const legacy = sessions.find((s) => s.deviceId === 'legacy');
  if (legacy && legacy.lastSeen !== nowSec) {
    legacy.lastSeen = nowSec;
    lic.sessions = sessions;
    return true;
  }
  return false;
}

function revokeSessionFrom(lic, sessionId) {
  const sessions = normalizeSessions(lic);
  const kept = sessions.filter((s) => s.id !== sessionId);
  const removed = kept.length !== sessions.length;
  lic.sessions = kept;
  return removed;
}

function revokeAllSessionsFrom(lic, keepSessionId) {
  const sessions = normalizeSessions(lic);
  lic.sessions = keepSessionId ? sessions.filter((s) => s.id === keepSessionId) : [];
  return sessions.length - lic.sessions.length;
}

// ── v2.1: download file selection (pure, unit-tested) ───────────────────
const RELEASE_PAGE_URL = 'https://github.com/AnishtayiN/vpn/releases/latest';
// Telegram's bot-API sendDocument limit (the worker also enforces it).
const TG_SEND_LIMIT = 48 * 1024 * 1024;

// Per-platform download list, in display order: Android arm64-v8a,
// Android armeabi-v7a, Legacy arm64-v8a, Windows Installer, Windows
// Portable. The old [...apk, ...exe, ...other].slice(0, 8) never reached
// the Windows files because there are 8 APKs. If no slot matches (an
// unexpected asset layout), fall back to any downloadable files, capped.
function pickDownloadFiles(files) {
  const list = Array.isArray(files) ? files : [];
  const isApk = (f) => f.name.toLowerCase().endsWith('.apk');
  const arm64 = list.find((f) => isApk(f) && /arm64-v8a/i.test(f.name) && !/legacy/i.test(f.name));
  const armeabi = list.find((f) => isApk(f) && /armeabi-v7a/i.test(f.name) && !/legacy/i.test(f.name));
  const legacyArm64 = list.find((f) => isApk(f) && /legacy/i.test(f.name) && /arm64-v8a/i.test(f.name));
  const installer = list.find((f) => f.name.toLowerCase().endsWith('.exe') && /installer/i.test(f.name));
  const portable = list.find((f) => f.name.toLowerCase().endsWith('.zip') && /portable/i.test(f.name));
  const pick = [arm64, armeabi, legacyArm64, installer, portable].filter(Boolean);
  if (pick.length) return pick;
  return list.filter((f) => /\.(apk|exe|zip)$/i.test(f.name)).slice(0, 5);
}

// Shared guide copy (L6): defined once, reused by every platform guide
// instead of three divergent copies.
const GUIDE_NO_CODE = '💡 کد ندارید؟ از خانه، «🎁 تست رایگان» را بزنید یا لایسنس بخرید.';

// Run async jobs over a list in bounded parallel batches (M7): a sequential
// scan of hundreds of users risks the ~10 s Telegram webhook timeout, while
// unbounded parallelism would spike subrequests. 25 at a time is the balance.
async function mapLimit(items, limit, fn) {
  const out = [];
  for (let i = 0; i < items.length; i += limit) {
    const batch = items.slice(i, i + limit);
    out.push(...(await Promise.all(batch.map(fn))));
  }
  return out;
}

const homeRow = () => [[{ text: '🏠 خانه', callback_data: 'home' }]];
const withHome = (rows) => [...(rows || []), ...homeRow()];

// v2.1: 1h cache + stale fallback. If GitHub fails (rate limit without
// GITHUB_TOKEN, transient error), the last cached list is returned even
// after expiry, so a transient GitHub failure no longer shows "no file
// found" while the release exists. Returns { files, stale }.
async function getReleaseFilesInfo(env) {
  let files = null;
  try {
    files = JSON.parse((await env.LICENSES.get('cache:relfiles')) || 'null');
  } catch (_) {}
  if (Array.isArray(files) && files.length) return { files, stale: false };
  const fresh = await releaseFiles(env);
  if (Array.isArray(fresh) && fresh.length) {
    try {
      await env.LICENSES.put('cache:relfiles', JSON.stringify(fresh), { expirationTtl: 3600 });
      await env.LICENSES.put('cache:relfiles:stale', JSON.stringify(fresh));
    } catch (_) {}
    return { files: fresh, stale: false };
  }
  let old = null;
  try {
    old = JSON.parse((await env.LICENSES.get('cache:relfiles:stale')) || 'null');
  } catch (_) {}
  if (Array.isArray(old) && old.length) return { files: old, stale: true };
  return { files: [], stale: false };
}

async function getReleaseFiles(env) {
  return (await getReleaseFilesInfo(env)).files;
}

async function setReceiptStatus(env, tid, status, planId) {
  await env.LICENSES.put(
    `receiptStatus:${tid}`,
    JSON.stringify({ status, at: Date.now(), planId: planId || null })
  );
}

async function getLic(env, key) {
  if (!key) return null;
  const raw = await env.LICENSES.get(`lic:${key}`);
  if (raw == null) return null;
  const lic = typeof raw === 'string' ? JSON.parse(raw) : raw;
  // v2.1: licences minted before sessions existed have no sessions /
  // maxUsers fields — default them in memory (maxUsers 1, never silently
  // multi-user; trial is always 1). The defaults are persisted on the
  // next write of the licence object.
  if (lic && typeof lic === 'object') {
    if (!Array.isArray(lic.sessions)) lic.sessions = [];
    const n = parseInt(lic.maxUsers, 10);
    lic.maxUsers = Number.isFinite(n) && n >= 1 && n <= 5 ? n : 1;
    if (lic.plan === 'trial') lic.maxUsers = 1;
  }
  return lic;
}

async function putLic(env, key, lic) {
  await env.LICENSES.put(`lic:${key}`, JSON.stringify(lic));
}

async function userKey(env, tid) {
  return await env.LICENSES.get(`user:${tid}`);
}

async function bindUser(env, tid, key) {
  await env.LICENSES.put(`user:${tid}`, key);
}

async function addCredit(env, tid, days) {
  const cur = (await env.LICENSES.get(`credit:${tid}`)) || '0';
  await env.LICENSES.put(`credit:${tid}`, String(parseInt(cur) + days));
}

async function mintKey(env, tid, days, plan = 'custom') {
  const key = keygen();
  const now = Math.floor(Date.now() / 1000);
  // H3 fix: a fresh licence starts with days: 0 and expiresAt: now.
  // extend() is the SINGLE place that adds days, so mintKey()+extend(days)
  // yields exactly `days` — never double. A minted-but-never-extended key
  // is already expired, never a free licence. (days param kept so callers
  // keep their shape; the value is applied by extend via issueKey.)
  const lic = { key, telegramId: String(tid), plan, days: 0, issuedAt: now, expiresAt: now, maxUsers: 1, sessions: [] };
  await putLic(env, key, lic);
  await bindUser(env, tid, key);
  return key;
}

async function extend(env, key, days) {
  const raw = await env.LICENSES.get(`lic:${key}`);
  const lic = typeof raw === 'string' ? JSON.parse(raw) : raw;
  if (!lic) return null;
  const now = Math.floor(Date.now() / 1000);
  const base = lic.expiresAt && lic.expiresAt > now ? lic.expiresAt : now;
  lic.expiresAt = base + days * 86400;
  lic.days = (lic.days || 0) + days;
  await putLic(env, key, lic);
  return lic;
}

// Single issue path (H3): mint + extend exactly once, so lic.days always
// equals the real plan length and the progress bar is correct. All six
// issue sites (doTrial, /api/trial, /gen, /ok, okr:, gift:yes) use this.
// v2.1: a licence issued for a known plan id takes that plan's maxUsers
// (m1:1, m3:2, m12:3, or the admin-set value); trial / paid / custom stay 1
// unless the caller sets maxUsers afterwards (receipt approval does).
async function issueKey(env, tid, days, plan = 'custom') {
  const key = await mintKey(env, tid, days, plan);
  const plans = await plansOf(env);
  const p = plans.find((x) => x.id === plan);
  if (p) {
    const lic = await getLic(env, key);
    if (lic) {
      lic.maxUsers = planMaxUsers(p);
      await putLic(env, key, lic);
    }
  }
  await extend(env, key, days);
  return key;
}

// Drain stored credit in ONE read + ONE extend + ONE write (M4). The old
// loop did 4 KV ops per credit day and could die at the 1,000-subrequest
// ceiling mid-approval with the receipt already deleted — licence half
// extended, user never told. Order matters: extend first, then zero the
// credit, so if the zeroing write fails the user keeps the credit
// (spendable later) instead of losing paid days.
async function applyCredit(env, key, tid) {
  const cur = parseInt((await env.LICENSES.get(`credit:${tid}`)) || '0');
  if (!Number.isFinite(cur) || cur <= 0) return 0;
  await extend(env, key, cur);
  await env.LICENSES.put(`credit:${tid}`, '0');
  return cur;
}

async function upgradePlan(env, key, plan) {
  const raw = await env.LICENSES.get(`lic:${key}`);
  const lic = typeof raw === 'string' ? JSON.parse(raw) : raw;
  if (!lic || lic.plan === plan) return;
  lic.plan = plan;
  await putLic(env, key, lic);
}

async function tg(token, method, body, env, steps) {
  const r = await fetch(`https://api.telegram.org/bot${token}/${method}`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body),
  });
  const out = await r.json().catch(() => ({ ok: false, description: 'json-parse-failed' }));
  if (steps) {
    steps.push('tg:' + method + ':' + (out.ok ? 'ok#' + out.result?.message_id : out.description));
  }
  if (env && env.LICENSES) {
    try {
      if (!out.ok) {
        await env.LICENSES.put('lastError', `tg ${method}: ${out.error_code || ''} ${out.description || 'unknown'}`);
      } else if (method === 'sendMessage' && out.result?.message_id) {
        await env.LICENSES.put('lastSentId', String(out.result.message_id));
      }
    } catch (_) {}
  }
  // H1: a failed send used to look exactly like a success — no caller ever
  // checked out.ok, so support messages and payment codes were silently
  // lost. Throw so every failure is visible; use tgSafe() for best-effort
  // notifications and sendReply() for user-facing replies (plain-text
  // fallback on Markdown parse errors).
  if (!out.ok) throw new Error(`tg ${method} failed: ${out.error_code || ''} ${out.description || 'unknown'}`);
  return out;
}

// Best-effort Telegram call: returns the result, or null on failure (the
// failure is already recorded in lastError by tg()). For notifications to
// another user where there is nothing useful to do on failure.
async function tgSafe(token, method, body, env, steps) {
  try {
    return await tg(token, method, body, env, steps);
  } catch (e) {
    if (steps) steps.push('tg:' + method + ':fail');
    return null;
  }
}

// User-facing reply: try as built (usually Markdown); on failure retry once
// as plain text — a stray * or _ in the text must not swallow the reply.
// Returns null only if both attempts fail.
async function sendReply(env, chatId, payload, steps) {
  try {
    return await tg(env.BOT_TOKEN, 'sendMessage', { chat_id: chatId, ...payload }, env, steps);
  } catch (e) {
    if (payload && payload.parse_mode) {
      try {
        const { parse_mode, ...plain } = payload;
        return await tg(env.BOT_TOKEN, 'sendMessage', { chat_id: chatId, ...plain }, env, steps);
      } catch (_) {}
    }
    return null;
  }
}

async function mainMenu(env, from, lic) {
  const tid = from && from.id;
  const name = from && from.first_name ? from.first_name : '';
  const now = Math.floor(Date.now() / 1000);
  const active = lic && lic.expiresAt && lic.expiresAt > now && lic.plan !== 'revoked';
  const credit = tid ? parseInt((await env.LICENSES.get(`credit:${tid}`)) || '0') : 0;
  const joins = tid ? parseInt((await env.LICENSES.get(`refjoin:${tid}`)) || '0') : 0;
  const rows = [
    [{ text: '🛒 خرید / تمدید لایسنس', callback_data: 'buy' }, { text: '🎁 هدیه دادن', callback_data: 'gift' }],
    [{ text: '✅ چک‌این روزانه', callback_data: 'checkin' }, { text: '👥 دعوت دوستان', callback_data: 'ref' }],
    [{ text: '🏆 لیدربورد دعوت', callback_data: 'top' }, { text: '📥 دانلود برنامه', callback_data: 'dl' }],
    [{ text: '🔑 کد لایسنس من', callback_data: 'mykey' }, { text: '📊 وضعیت لایسنس', callback_data: 'status' }],
    [{ text: '📱 نشست‌ها', callback_data: 'sessions' }],
    [{ text: '🧾 وضعیت رسید من', callback_data: 'receipt' }, { text: '📖 راهنما', callback_data: 'help' }],
    [{ text: '🆘 پشتیبانی', callback_data: 'support' }],
  ];
  if (!active) {
    rows.push([{ text: '🎁 تست رایگان', callback_data: 'trial' }]);
  }
  const safe = name.replace(/([_*\[`])/g, '\\$1');
  const hi = name ? `سلام ${safe} 👋\n\n` : 'سلام 👋\n\n';
  let body = '';
  if (active) {
    const leftSec = lic.expiresAt - now;
    const daysLeft = Math.ceil(leftSec / 86400);
    const totalDays = lic.days || 0;
    const planName = lic.plan === 'paid' ? 'خریداری‌شده ویژه ⭐️' : (lic.plan === 'trial' ? 'تست رایگان موقت 🎁' : 'اختصاصی');
    body = `✅ *لایسنس فعال شما*\n\`${lic.key}\`\n\n` +
      `📦 نوع اشتراک: *${planName}*\n` +
      `⏳ پیشرفت اشتراک: \`${progressBar(daysLeft, totalDays)}\`${totalDays > 0 ? ` ${daysLeft} از ${totalDays} روز` : ''}\n` +
      `⏰ زمان باقی‌مانده: *${formatDuration(leftSec)}*\n` +
      `📅 تاریخ انقضا: *${formatJalali(lic.expiresAt)}*\n` +
      `🎁 اعتبار ذخیره هدیه: *${credit} روز*\n` +
      `👥 افراد دعوت‌شده: *${joins} نفر*\n\n` +
      `💡 روی کد لایسنس بالا ضربه بزنید تا کپی شود.`;
  } else {
    body = 'به ربات رسمی VoidrauVPN خوش آمدید!\n\n' +
      '🔐 برای فعال‌سازی و اتصال امن:\n' +
      '• تست رایگان ۲۴ ساعته بگیرید یا لایسنس بخرید\n' +
      '• کد دریافتی را در برنامه (تب لایسنس) وارد کنید\n' +
      '• آخرین نسخه برنامه را از بخش «📥 دانلود» دریافت نمایید' +
      (credit > 0 ? `\n\n🎁 اعتبار ذخیره هدیه شما: *${credit} روز*` : '') +
      (joins > 0 ? `\n👥 افراد دعوت‌شده: *${joins} نفر*` : '');
  }
  return { text: hi + body, parse_mode: 'Markdown', reply_markup: { inline_keyboard: rows } };
}

// ── latest release files from GitHub ─────────────────────────────────
async function releaseFiles(env) {
  try {
    const ghHeaders = { Accept: 'application/vnd.github+json', 'User-Agent': 'VoidrauLicenseBot' };
    if (env.GITHUB_TOKEN) ghHeaders.Authorization = `Bearer ${env.GITHUB_TOKEN}`;
    const r = await fetch('https://api.github.com/repos/AnishtayiN/vpn/releases/latest', { headers: ghHeaders });
    if (!r.ok) return null;
    const rel = await r.json();
    if (!rel || rel.message) return null;
    const out = (rel.assets || []).map((a) => ({
      name: a.name,
      size: a.size,
      url: a.browser_download_url,
      tag: rel.tag_name,
      date: a.updated_at,
    }));
    return out.length ? out : null;
  } catch (e) {
    try {
      console.log('releaseFiles error', e && e.message);
    } catch (_) {}
    return null;
  }
}

const humanSize = (n) =>
  n > 1048576 ? (n / 1048576).toFixed(1) + ' MB' : Math.round(n / 1024) + ' KB';

const DL_FILES_KEY = 'dlfiles';
const dlLabel = (n) => n.replace(/^VoidrauVPN-/, '').replace(/\.apk$|\.exe$|\.zip$/i, '');

async function doDownloads(env, tid) {
  const { files, stale } = await getReleaseFilesInfo(env);
  const pick = pickDownloadFiles(files);
  if (!pick.length) {
    // No cache at all and GitHub unreachable: offer the release page
    // directly instead of the old dead-end "no file found" message.
    return {
      text: '⚠️ در حال حاضر نتوانستیم لیست فایل‌ها را از گیت‌هاب بگیریم.\n\nمی‌توانید مستقیم از صفحهٔ ریلیز، آخرین نسخه را دانلود کنید:',
      reply_markup: {
        inline_keyboard: withHome([[{ text: '📥 صفحهٔ دانلود در گیت‌هاب', url: RELEASE_PAGE_URL }]]),
      },
    };
  }
  await env.LICENSES.put(`${DL_FILES_KEY}:${tid}`, JSON.stringify(pick), { expirationTtl: 3600 });
  const rows = pick.map((f, i) => [
    { text: `📄 ${dlLabel(f.name)} (${humanSize(f.size)})`, callback_data: `file:${i}` },
  ]);
  const tag = pick[0]?.tag || '';
  const staleNote = stale ? '\n⚠️ لیست زیر از کش قدیمی است و ممکن است کاملاً به‌روز نباشد.' : '';
  return {
    text: `📥 آخرین نسخه موجود: *${tag}*${staleNote}\nفایل مورد نظر برای دستگاه خود را انتخاب نمایید تا مستقیماً برایتان ارسال شود:`,
    parse_mode: 'Markdown',
    reply_markup: {
      inline_keyboard: withHome([
        ...rows,
        [{ text: '🔄 بروزرسانی لیست فایل‌ها', callback_data: 'dlrefresh' }],
        [{ text: '🌐 صفحهٔ ریلیز در گیت‌هاب', url: RELEASE_PAGE_URL }],
      ]),
    },
  };
}

// v2.1: when a file is too big for Telegram, send its direct download link
// instead of a dead end — and never claim the file was sent when it was not.
async function sendDownloadLink(env, tid, url, name, size) {
  await tgSafe(env.BOT_TOKEN, 'sendMessage', {
    chat_id: tid,
    text: `📥 فایل *${escMd(name)}* (${humanSize(size)}) برای ارسال مستقیم در تلگرام خیلی بزرگ است.\n\nاز دکمهٔ زیر مستقیم دانلود کنید:`,
    parse_mode: 'Markdown',
    reply_markup: { inline_keyboard: [[{ text: '📥 دانلود مستقیم فایل', url }]] },
  });
}

async function sendReleaseFile(env, tid, url, name, size) {
  // Returns true when the file was actually sent as a document, 'link'
  // when only a direct download link was sent (over Telegram's size
  // limit). The caller must not report success unless it gets true.
  const knownSize = Number(size) || 0;
  if (knownSize > TG_SEND_LIMIT) {
    await sendDownloadLink(env, tid, url, name, knownSize);
    return 'link';
  }
  const ghHeaders = {};
  if (env.GITHUB_TOKEN) ghHeaders.Authorization = `Bearer ${env.GITHUB_TOKEN}`;
  const res = await fetch(url, { headers: ghHeaders, redirect: 'follow' });
  if (!res.ok) throw new Error(`github ${res.status}`);
  const len = Number(res.headers ? res.headers.get('content-length') || 0 : 0);
  if (len && len > TG_SEND_LIMIT) {
    await sendDownloadLink(env, tid, url, name, len);
    return 'link';
  }
  const buf = await res.arrayBuffer();
  if (buf.byteLength > TG_SEND_LIMIT) {
    await sendDownloadLink(env, tid, url, name, buf.byteLength);
    return 'link';
  }
  const fd = new FormData();
  fd.append('chat_id', String(tid));
  fd.append('document', new Blob([buf]), name);
  const out = await fetch(`https://api.telegram.org/bot${env.BOT_TOKEN}/sendDocument`, {
    method: 'POST',
    body: fd,
  });
  const j = await out.json().catch(() => ({}));
  if (!j.ok) throw new Error(j.description || 'telegram upload failed');
  return true;
}

async function doHelp() {
  return {
    text: '📖 *راهنمای استفاده از VoidrauVPN*\n\nپلتفرم خود را انتخاب کنید تا مراحل مخصوص همان دستگاه را ببینید:',
    parse_mode: 'Markdown',
    reply_markup: {
      inline_keyboard: withHome([
        [{ text: '🤖 اندروید', callback_data: 'help:android' }, { text: '🪟 ویندوز', callback_data: 'help:windows' }],
        [{ text: '🍎 آیفون / iOS', callback_data: 'help:ios' }],
      ]),
    },
  };
}

async function doHelpPlatform(env, platform) {
  const files = await getReleaseFiles(env);
  const back = [[{ text: '⬅️ بازگشت به راهنما', callback_data: 'help' }]];
  if (platform === 'android') {
    // v2.1: most phones are arm64-v8a, so the arm64 APK (47 MB, sendable
    // in Telegram) is the default — the 132 MB Universal APK used to be
    // the default and could never be sent in-chat. Universal stays as an
    // alternative for older/other devices.
    const apk = files.find((f) => /arm64-v8a/i.test(f.name) && !/legacy/i.test(f.name) && f.name.toLowerCase().endsWith('.apk'))
      || files.find((f) => f.name.toLowerCase().endsWith('.apk'));
    const universal = files.find((f) => /universal/i.test(f.name) && !/legacy/i.test(f.name) && f.name.toLowerCase().endsWith('.apk'));
    const rows = [];
    if (apk) rows.push([{ text: `📥 دانلود نسخه اندروید (${apk.tag || ''} — ${humanSize(apk.size)})`, url: apk.url }]);
    if (universal && universal !== apk) rows.push([{ text: `📥 نسخه یونیورسال (جایگزین — ${humanSize(universal.size)})`, url: universal.url }]);
    rows.push([{ text: '📥 همهٔ فایل‌های دانلود', callback_data: 'dl' }]);
    return {
      text: '🤖 *راهنمای اندروید*\n\n' +
        '۱. از دکمهٔ دانلود زیر، فایل APK مخصوص گوشی خود (arm64-v8a) را بگیرید و نصب کنید (در صورت هشدار، «نصب از منبع ناشناس» را تایید کنید). اگر گوشی شما قدیمی است یا این فایل نصب نشد، نسخهٔ یونیورسال را امتحان کنید.\n' +
        '۲. برنامه را باز کنید و در تب «لایسنس»، کد خود را وارد نمایید.\n' +
        '۳. دکمهٔ اتصال را بزنید؛ در اولین اتصال، تایید VPN سیستم را قبول کنید.\n\n' +
        GUIDE_NO_CODE,
      parse_mode: 'Markdown',
      reply_markup: { inline_keyboard: withHome([...rows, ...back]) },
    };
  }
  if (platform === 'windows') {
    const exe = files.find((f) => /installer/i.test(f.name) && f.name.toLowerCase().endsWith('.exe'))
      || files.find((f) => f.name.toLowerCase().endsWith('.exe'));
    const rows = [];
    if (exe) rows.push([{ text: `📥 دانلود نسخه ویندوز (${exe.tag || ''} — ${humanSize(exe.size)})`, url: exe.url }]);
    rows.push([{ text: '📥 همهٔ فایل‌های دانلود', callback_data: 'dl' }]);
    return {
      text: '🪟 *راهنمای ویندوز*\n\n' +
        '۱. از دکمهٔ دانلود زیر، فایل Installer را بگیرید و اجرا کنید.\n' +
        '۲. برنامه را باز کنید و در بخش لایسنس، کد خود را وارد نمایید.\n' +
        '۳. دکمهٔ اتصال را بزنید؛ در صورت پرسش ویندوز، دسترسی شبکه را تایید کنید.\n\n' +
        GUIDE_NO_CODE,
      parse_mode: 'Markdown',
      reply_markup: { inline_keyboard: withHome([...rows, ...back]) },
    };
  }
  // iOS — no download link is claimed: activation steps only + support.
  return {
    text: '🍎 *راهنمای آیفون / iOS*\n\n' +
      '۱. برنامهٔ VoidrauVPN را روی آیفون خود باز کنید.\n' +
      '۲. در بخش لایسنس، کد خود را وارد نمایید.\n' +
      '۳. دکمهٔ اتصال را بزنید و در صورت پرسش، افزودن پیکربندی VPN را تایید کنید.\n\n' +
      '📲 برای دریافت لینک نصب نسخهٔ iOS، لطفاً به پشتیبانی پیام بدهید — لینک نصب از آن‌جا در اختیارتان قرار می‌گیرد.',
    parse_mode: 'Markdown',
    reply_markup: {
      inline_keyboard: withHome([
        [{ text: '🆘 تماس با پشتیبانی', callback_data: 'support' }],
        ...back,
      ]),
    },
  };
}

const FAQ_ANSWERS = {
  activation: '🔑 *فعال‌سازی لایسنس*\n\n۱. کد لایسنس خود را از «🔑 کد لایسنس من» در خانه کپی کنید.\n۲. برنامهٔ VoidrauVPN را باز کنید و در تب «لایسنس»، کد را پیست نمایید.\n۳. پس از تایید کد، دکمهٔ اتصال را بزنید.\n\nاگر کد قبول نشد، مطمئن شوید کد را کامل و بدون فاصلهٔ اضافه وارد کرده‌اید.',
  connecting: '📡 *وصل نشدن به VPN*\n\n• مطمئن شوید لایسنس شما فعال و منقضی نشده است (از «📊 وضعیت لایسنس» ببینید).\n• اتصال اینترنت خود را بررسی کنید و یک‌بار برنامه را ببندید و دوباره باز کنید.\n• حالت اتصال دیگری را امتحان کنید (مثلاً Psiphon یا Tor) و آخرین نسخهٔ برنامه را از «📥 دانلود» بگیرید.\n• اگر باز هم وصل نشد، اسکرین‌شات خطا را برای پشتیبانی بفرستید.',
  expired: '⏰ *انقضای لایسنس*\n\nاگر لایسنس شما منقضی شده است:\n• از خانه «🛒 خرید / تمدید» را بزنید و پلن تازه بخرید.\n• یا با «✅ چک‌این روزانه» و «👥 دعوت دوستان» اعتبار رایگان جمع کنید؛ اعتبار ذخیره به‌صورت خودکار به لایسنس بعدی شما اضافه می‌شود.',
  key: '🔑 *فراموش کردن کد لایسنس*\n\nنگران نباشید — کد شما همین‌جا ذخیره است. از خانه دکمهٔ «🔑 کد لایسنس من» را بزنید تا کد، نوع پلن و تاریخ انقضا را ببینید و با یک ضربه کپی کنید.',
  refund: '💳 *بازگشت وجه*\n\nبازگشت وجه پس از بررسی توسط پشتیبانی انجام می‌شود. لطفاً از بخش «تماس با پشتیبانی» پیام بدهید و شمارهٔ پیگیری پرداخت، تاریخ و مبلغ واریز را بنویسید تا بررسی شود.',
};

async function doSupport(env) {
  const sup = await getSetting(env, 'supportId', '@Voidrau');
  return {
    text: `🆘 *پشتیبانی VoidrauVPN*\n\nیکی از سوال‌های متداول را انتخاب کنید، یا مستقیم به پشتیبانی پیام بدهید:\n👤 ${escMd(sup)}`,
    parse_mode: 'Markdown',
    reply_markup: {
      inline_keyboard: withHome([
        [{ text: '🔑 فعال‌سازی لایسنس', callback_data: 'faq:activation' }],
        [{ text: '📡 وصل نشدن به VPN', callback_data: 'faq:connecting' }],
        [{ text: '⏰ انقضای لایسنس', callback_data: 'faq:expired' }],
        [{ text: '🔑 فراموش کردن کد', callback_data: 'faq:key' }],
        [{ text: '💳 بازگشت وجه', callback_data: 'faq:refund' }],
        [{ text: '✍️ تماس با پشتیبانی (نوشتن پیام)', callback_data: 'sup' }],
      ]),
    },
  };
}

function faqPayload(key) {
  const a = FAQ_ANSWERS[key];
  if (!a) return null;
  return {
    text: a,
    parse_mode: 'Markdown',
    reply_markup: {
      inline_keyboard: withHome([[{ text: '⬅️ بازگشت به پشتیبانی', callback_data: 'support' }]]),
    },
  };
}

async function doReceiptStatus(env, tid) {
  let st = null;
  try {
    st = JSON.parse((await env.LICENSES.get(`receiptStatus:${tid}`)) || 'null');
  } catch (_) {}
  const hasReceipt = await env.LICENSES.get(`receipt:${tid}`);
  if (!st && hasReceipt) st = { status: 'pending', at: Date.now(), planId: null };
  if (!st) {
    return {
      text: '🧾 هیچ رسیدی از شما ثبت نشده است.\nبرای خرید، از خانه «🛒 خرید / تمدید» را بزنید و پس از واریز، عکس رسید را همین‌جا ارسال کنید.',
      reply_markup: { inline_keyboard: withHome([[{ text: '🛒 خرید لایسنس', callback_data: 'buy' }]]) },
    };
  }
  const label = st.status === 'approved' ? 'تایید شد ✅' : st.status === 'rejected' ? 'رد شد ❌' : 'در انتظار بررسی ⏳';
  return {
    text: `🧾 *وضعیت رسید شما*\n\n🚦 وضعیت: *${label}*\n` +
      (st.planId ? `📦 پلن: ${st.planId}\n` : '') +
      (st.at ? `📅 زمان ثبت: *${formatJalali(Math.floor(st.at / 1000))}*\n` : '') +
      (st.status === 'pending' ? '\nرسید شما به مدیریت ارسال شده است؛ به محض بررسی، نتیجه همین‌جا اعلام می‌شود.' : '') +
      (st.status === 'rejected' ? '\nرسید تایید نشد. لطفاً تصویر واضح‌تری بفرستید یا با پشتیبانی تماس بگیرید.' : ''),
    parse_mode: 'Markdown',
    reply_markup: { inline_keyboard: homeRow() },
  };
}

// ── v2.1: bot sessions page ───────────────────────────────────────────
// Only the licence owner (telegramId) can see or remove sessions. The bot
// itself is not a device, so "delete all" really deletes all — the confirm
// text says every device must re-activate afterwards.
async function doSessions(env, tid) {
  const key = await userKey(env, tid);
  if (!key) {
    return { text: '📱 شما هنوز لایسنسی ندارید — با «🎁 تست رایگان» شروع کنید.', reply_markup: { inline_keyboard: homeRow() } };
  }
  const lic = await getLic(env, key);
  if (!lic || !lic.expiresAt || lic.plan === 'revoked') {
    return { text: '📱 لایسنس شما نامعتبر یا باطل شده است.', reply_markup: { inline_keyboard: homeRow() } };
  }
  if (String(lic.telegramId || '') !== String(tid)) {
    return { text: '⛔ این لایسنس به شما تعلق ندارد.', reply_markup: { inline_keyboard: homeRow() } };
  }
  const now = Math.floor(Date.now() / 1000);
  const sessions = normalizeSessions(lic);
  const active = sessions.filter((s) => sessionIsActive(s, now));
  const maxUsers = maxUsersOf(lic);
  let t = `📱 *نشست‌های لایسنس شما*\n\n${active.length} از ${maxUsers} نشست فعال\n\n`;
  if (!sessions.length) {
    t += 'هنوز هیچ دستگاهی با این لایسنس فعال نشده است.\nکد را در برنامه وارد کنید تا دستگاه شما اینجا دیده شود.';
  } else {
    for (const s of sessions) {
      const stale = !sessionIsActive(s, now);
      const emoji = PLATFORM_EMOJI[s.platform] || '❓';
      t += `${emoji} *${escMd(s.name || 'دستگاه ناشناس')}*\n` +
        `   نسخهٔ اپ: ${s.appVersion ? escMd(s.appVersion) : '—'}\n` +
        `   آخرین فعالیت: *${formatJalali(s.lastSeen)}*${stale ? ' — غیرفعال (بیش از ۳۰ روز)' : ''}\n\n`;
    }
    t += '💡 نشست غیرفعال به‌صورت خودکار حذف نمی‌شود؛ اگر دستگاهی را نمی‌شناسید، آن را حذف کنید تا جایش آزاد شود.';
  }
  const rows = sessions.map((s) => [
    { text: `🗑 حذف ${String(s.name || 'دستگاه').slice(0, 20)}`, callback_data: `sesdel:${s.id}` },
  ]);
  if (sessions.length) rows.push([{ text: '🗑 حذف همهٔ نشست‌ها', callback_data: 'sesdelall' }]);
  return { text: t, parse_mode: 'Markdown', reply_markup: { inline_keyboard: withHome(rows) } };
}

async function doStatus(env, tid) {
  const key = await userKey(env, tid);
  if (!key) return { text: '📊 هیچ لایسنسی ثبت نکرده‌اید — با «🎁 تست رایگان» شروع کنید.', reply_markup: { inline_keyboard: homeRow() } };
  const lic = await getLic(env, key);
  if (!lic || !lic.expiresAt || lic.plan === 'revoked') {
    return { text: '📊 لایسنس شما نامعتبر یا باطل شده است.', reply_markup: { inline_keyboard: homeRow() } };
  }
  // Opportunistic expiry reminder (also runs from scheduled() when cron is live).
  await maybeSendExpiryReminder(env, tid);
  const now = Math.floor(Date.now() / 1000);
  const active = lic.expiresAt > now;
  const joins = parseInt((await env.LICENSES.get(`refjoin:${tid}`)) || '0');
  const credit = parseInt((await env.LICENSES.get(`credit:${tid}`)) || '0');
  const planLabel = lic.plan === 'paid' ? 'خریداری‌شده ویژه ⭐️' : (lic.plan === 'trial' ? 'تست رایگان 🎁' : lic.plan);
  const daysLeft = Math.max(0, Math.ceil((lic.expiresAt - now) / 86400));
  return {
    text: `📊 *گزارش وضعیت حساب کاربری*\n\n` +
      `🔑 کد لایسنس:\n\`${key}\`\n\n` +
      `📦 نوع اشتراک: ${planLabel}\n` +
      `🚦 وضعیت: ${active ? 'فعال ✅' : 'منقضی شده ❌'}\n` +
      `⏳ پیشرفت اشتراک: \`${progressBar(daysLeft, lic.days || 0)}\`${(lic.days || 0) > 0 ? ` ${daysLeft} از ${lic.days} روز` : ''}\n` +
      `⏳ اعتبار زمانی: *${formatDuration(lic.expiresAt - now)}*\n` +
      `📅 تاریخ انقضا: *${formatJalali(lic.expiresAt)}*\n` +
      `👥 افراد دعوت‌شده: ${joins} نفر\n` +
      `🎁 اعتبار ذخیره هدیه: ${credit} روز`,
    parse_mode: 'Markdown',
    reply_markup: { inline_keyboard: homeRow() },
  };
}

// ── v2.0: expiry reminders ─────────────────────────────────────────────
// One reminder per user per Tehran calendar day, for licences expiring
// within 3 days. Runs from scheduled() (cron) and opportunistically on
// /start and licence-status views, so it works with or without cron.
async function maybeSendExpiryReminder(env, tid) {
  try {
    const key = await userKey(env, tid);
    if (!key) return false;
    const lic = await getLic(env, key);
    if (!lic || !lic.expiresAt || lic.plan === 'revoked') return false;
    const now = Math.floor(Date.now() / 1000);
    const daysLeft = Math.ceil((lic.expiresAt - now) / 86400);
    if (daysLeft < 0 || daysLeft > 3) return false;
    const today = tehranDate();
    if (await env.LICENSES.get(`remind:${tid}:${today}`)) return false;
    await env.LICENSES.put(`remind:${tid}:${today}`, '1');
    const when = daysLeft === 0 ? 'امروز' : `تا ${daysLeft} روز دیگر`;
    await tg(env.BOT_TOKEN, 'sendMessage', {
      chat_id: tid,
      text: `⏰ *یادآوری انقضا*\n\nلایسنس شما ${when} منقضی می‌شود.\n📅 تاریخ انقضا: *${formatJalali(lic.expiresAt)}*\n\nبرای تمدید، از خانه «🛒 خرید / تمدید» را بزنید.`,
      parse_mode: 'Markdown',
      reply_markup: { inline_keyboard: [[{ text: '🛒 خرید / تمدید', callback_data: 'buy' }], [{ text: '🏠 خانه', callback_data: 'home' }]] },
    });
    return true;
  } catch (_) {
    return false;
  }
}

async function runExpiryReminders(env) {
  let idx = [];
  try {
    idx = JSON.parse((await env.LICENSES.get('userIndex')) || '[]');
    if (!Array.isArray(idx)) idx = [];
  } catch (_) {}
  // M7: scan the whole index (no 300 cap) in bounded parallel batches
  // instead of one slow sequential pass.
  const results = await mapLimit(idx, 25, (u) => maybeSendExpiryReminder(env, u));
  return results.filter(Boolean).length;
}

// M7: broadcast to every user in bounded parallel batches. Runs in the
// background (ctx.waitUntil) so a long list cannot time out the webhook.
async function runBroadcast(env, adminTid, bc, list) {
  let n = 0;
  let fail = 0;
  const batchSize = 15;
  for (let i = 0; i < list.length; i += batchSize) {
    const batch = list.slice(i, i + batchSize);
    await Promise.all(
      batch.map(async (u) => {
        try {
          let r;
          if (bc.kind === 'photo') {
            r = await tg(env.BOT_TOKEN, 'sendPhoto', {
              chat_id: u,
              photo: bc.fileId,
              caption: bc.caption || '',
            });
          } else if (bc.kind === 'doc') {
            r = await tg(env.BOT_TOKEN, 'sendDocument', {
              chat_id: u,
              document: bc.fileId,
              caption: bc.caption || '',
            });
          } else {
            r = await tg(env.BOT_TOKEN, 'sendMessage', { chat_id: u, text: bc.text });
          }
          if (r && r.ok) n++;
          else fail++;
        } catch (_) {
          fail++;
        }
      })
    );
    await new Promise((resolve) => setTimeout(resolve, 200));
  }
  return { n, fail };
}

// ── v2.0: gift / check-in / leaderboard ─────────────────────────────────
async function doGiftHome(env, tid) {
  const credit = parseInt((await env.LICENSES.get(`credit:${tid}`)) || '0');
  if (credit <= 0) {
    return {
      text: '🎁 *هدیه دادن لایسنس*\n\nاعتبار ذخیرهٔ شما ۰ روز است.\nهدیه فقط از «اعتبار ذخیره» داده می‌شود، نه از زمان لایسنس فعال شما.\n\nاعتبار را می‌توانید با دعوت دوستان (هر ۳ دعوت = ۷ روز)، چک‌این روزانه (هر ۷ امتیاز = ۱ روز) یا خرید به دست بیاورید.',
      parse_mode: 'Markdown',
      reply_markup: { inline_keyboard: withHome([[{ text: '🛒 خرید لایسنس', callback_data: 'buy' }], [{ text: '👥 دعوت دوستان', callback_data: 'ref' }]]) },
    };
  }
  await env.LICENSES.put(`gift:${tid}`, JSON.stringify({ stage: 'awaitId' }));
  return {
    text: `🎁 *هدیه دادن لایسنس*\n\n🎁 اعتبار ذخیرهٔ شما: *${credit} روز*\n\nآیدی عددی دوست خود را بفرستید (دوست شما می‌تواند با دستور /id در ربات، آیدی‌اش را ببیند):`,
    parse_mode: 'Markdown',
    reply_markup: { inline_keyboard: homeRow() },
  };
}

async function doCheckin(env, tid) {
  const today = tehranDate();
  const yesterday = tehranYesterday();
  // M2: the whole check-in state lives in ONE key (checkin:{tid}) now, so a
  // double-tap cannot award two days: both taps read the same old state and
  // write the same new state, and the unique claim below lets the loser
  // detect it was second. Legacy per-field keys are read once and migrated.
  let state = null;
  try {
    state = JSON.parse((await env.LICENSES.get(`checkin:${tid}`)) || 'null');
  } catch (_) {}
  if (!state || typeof state !== 'object') {
    const last = (await env.LICENSES.get(`checkin:${tid}:last`)) || '';
    const streak = parseInt((await env.LICENSES.get(`checkin:${tid}:streak`)) || '0');
    const points = parseInt((await env.LICENSES.get(`checkin:${tid}:points`)) || '0');
    state = { last, streak: Number.isFinite(streak) ? streak : 0, points: Number.isFinite(points) ? points : 0 };
  }
  const r = checkinNext(state.last || '', state.streak || 0, state.points || 0, today, yesterday);
  if (r.already) {
    return {
      text: `✅ چک‌این امروز را قبلاً انجام داده‌اید.\n\n🔥 استریک فعلی: *${r.streak} روز*\n⭐ امتیاز: *${r.points} از ۷* (هر ۷ امتیاز = ۱ روز اعتبار)\n\nفردا دوباره سر بزنید!`,
      parse_mode: 'Markdown',
      reply_markup: { inline_keyboard: homeRow() },
    };
  }
  const claim = crypto.randomUUID();
  await env.LICENSES.put(`checkin:${tid}`, JSON.stringify({ last: today, streak: r.streak, points: r.points, claim }));
  // If another concurrent tap overwrote our claim, it already recorded this
  // day — do not award the bonus twice; report the recorded state instead.
  let back = null;
  try { back = JSON.parse((await env.LICENSES.get(`checkin:${tid}`)) || 'null'); } catch (_) {}
  if (!back || back.claim !== claim) {
    return {
      text: `✅ چک‌این امروز ثبت شد.\n\n🔥 استریک فعلی: *${r.streak} روز*\n⭐ امتیاز: *${r.points} از ۷* (هر ۷ امتیاز = ۱ روز اعتبار)`,
      parse_mode: 'Markdown',
      reply_markup: { inline_keyboard: homeRow() },
    };
  }
  const statKey = `stat:checkins:${today}`;
  await env.LICENSES.put(statKey, String(parseInt((await env.LICENSES.get(statKey)) || '0') + 1));
  let bonusText = '';
  if (r.bonus) {
    await addCredit(env, tid, 1);
    bonusText = `\n\n🎉 *تبریک! ۷ امتیاز کامل شد و ۱ روز اعتبار به حساب شما اضافه شد.*`;
  }
  return {
    text: `✅ *چک‌این روزانه ثبت شد!*\n\n🔥 استریک فعلی: *${r.streak} روز*\n⭐ امتیاز: *${r.points} از ۷* (هر ۷ امتیاز = ۱ روز اعتبار)${bonusText}`,
    parse_mode: 'Markdown',
    reply_markup: { inline_keyboard: homeRow() },
  };
}

async function doLeaderboard(env, tid) {
  // M7: cached for 5 minutes (top:cache) and scanned in bounded parallel
  // batches over the whole index — the old sequential scan of up to 300
  // users could outrun the webhook timeout, and every tap re-scanned.
  let rows = null;
  try {
    const cached = JSON.parse((await env.LICENSES.get('top:cache')) || 'null');
    if (cached && Array.isArray(cached.rows) && Date.now() - (cached.at || 0) < 300000) rows = cached.rows;
  } catch (_) {}
  if (!rows) {
    let idx = [];
    try {
      idx = JSON.parse((await env.LICENSES.get('userIndex')) || '[]');
      if (!Array.isArray(idx)) idx = [];
    } catch (_) {}
    const found = await mapLimit(idx, 25, async (u) => {
      const joins = parseInt((await env.LICENSES.get(`refjoin:${u}`)) || '0');
      return joins > 0 ? { tid: u, joins } : null;
    });
    rows = found.filter(Boolean);
    try {
      await env.LICENSES.put('top:cache', JSON.stringify({ at: Date.now(), rows }), { expirationTtl: 300 });
    } catch (_) {}
  }
  const { top, rank } = leaderboardRank(rows, tid);
  const medals = ['🥇', '🥈', '🥉'];
  let t = '🏆 *لیدربورد دعوت دوستان*\n\n';
  if (!top.length) {
    t += 'هنوز کسی دعوتی ثبت نکرده است — اولین نفر باشید!\nاز «👥 دعوت دوستان» لینک خود را بگیرید و بفرستید.';
  } else {
    for (let i = 0; i < top.length; i++) {
      const nm = (await env.LICENSES.get(`name:${top[i].tid}`)) || 'کاربر';
      const safe = String(nm).replace(/([_*\[`])/g, '\\$1');
      t += `${medals[i] || `${i + 1}.`} ${safe} — *${top[i].joins} دعوت*\n`;
    }
    if (rank > 10) {
      const myJoins = parseInt((await env.LICENSES.get(`refjoin:${tid}`)) || '0');
      t += `\n➖ رتبهٔ شما: *${rank}* (${myJoins} دعوت)`;
    } else if (rank > 0) {
      t += `\n🎉 شما در رتبهٔ *${rank}* هستید!`;
    }
  }
  return {
    text: t,
    parse_mode: 'Markdown',
    reply_markup: { inline_keyboard: withHome([[{ text: '👥 دعوت دوستان', callback_data: 'ref' }]]) },
  };
}

export default {
  async fetch(request, env, ctx) {
    try {
      return await handleHttp(request, env, ctx);
    } catch (e) {
      try {
        await env.LICENSES.put('lastError', 'fetch: ' + String(e && e.stack || e).slice(0, 400));
      } catch (_) {}
      return new Response('⚠️ Worker error — check /diag', { status: 500 });
    }
  },

  // v2.0: daily cron (05:00 UTC) — expiry reminders. Works alongside the
  // opportunistic checks on /start and status views, so reminders still fire
  // if the cron trigger is not enabled. NOTE: this MUST live inside the
  // default export — the Workers runtime only calls scheduled() from here;
  // a standalone `export async function scheduled` would be ignored.
  async scheduled(event, env, ctx) {
    // M7: run the reminder scan in the background so the cron invocation
    // itself returns immediately instead of holding the whole scan.
    const run = (async () => {
      try {
        const sent = await runExpiryReminders(env);
        try {
          await env.LICENSES.put('lastReminders', JSON.stringify({ at: new Date().toISOString(), sent }));
        } catch (_) {}
      } catch (e) {
        try {
          await env.LICENSES.put('lastError', 'scheduled: ' + String(e && e.stack || e).slice(0, 400));
        } catch (_) {}
      }
    })();
    if (event && typeof event.waitUntil === 'function') event.waitUntil(run);
    else if (ctx && typeof ctx.waitUntil === 'function') ctx.waitUntil(run);
    else await run;
  },
};

async function handleHttp(request, env, ctx) {
  const url = new URL(request.url);

  // ── HTTP API ──────────────────────────────────────────────────────────
  if (url.pathname === '/api/license' || url.pathname === '/api/status') {
    const key = (url.searchParams.get('key') || '').trim();
    if (!key) return json({ ok: false, error: 'missing-key' }, 400);
    const lic = await getLic(env, key);
    // L1: errors carry real HTTP statuses now (revoked 403, invalid 404)
    // instead of 200 for every outcome, so the app cannot mistake a dead
    // licence for a valid one by checking the status code alone.
    if (!lic || !lic.expiresAt || lic.plan === 'revoked') {
      return json({ ok: false, error: lic?.plan === 'revoked' ? 'revoked' : 'invalid' }, lic?.plan === 'revoked' ? 403 : 404);
    }
    const now = Math.floor(Date.now() / 1000);
    if (lic.expiresAt <= now) {
      return json({ ok: false, error: 'expired', expiresAt: lic.expiresAt, serverTime: now }, 410);
    }
    const isLicense = url.pathname === '/api/license';
    const deviceId = (url.searchParams.get('deviceId') || '').trim();
    const base = {
      ok: true,
      key: lic.key,
      plan: lic.plan,
      issuedAt: lic.issuedAt,
      expiresAt: lic.expiresAt,
      serverTime: now,
      remainingSeconds: Math.max(0, lic.expiresAt - now),
      daysLeft: Math.max(0, Math.ceil((lic.expiresAt - now) / 86400)),
      isPaid: lic.plan === 'paid' || lic.plan === 'admin',
      maxUsers: maxUsersOf(lic),
    };
    if (!deviceId) {
      // Legacy app (no deviceId): it keeps working exactly as before, and
      // the licence gets one anonymous legacy seat (see
      // ensureLegacySession) so the owner can see it in the bot.
      if (ensureLegacySession(lic, now)) await putLic(env, key, lic);
      return json({
        ...base,
        sessions: normalizeSessions(lic).map(sessionSummary),
        activeSessions: activeSessionsOf(lic, now).length,
      });
    }
    const info = {
      deviceId,
      name: (url.searchParams.get('deviceName') || '').trim().slice(0, 64),
      platform: normalizePlatform(url.searchParams.get('platform')),
      appVersion: (url.searchParams.get('appVersion') || '').trim().slice(0, 32),
    };
    if (!isLicense) {
      // /api/status: read-only touch — report whether THIS device's
      // session still exists (revoked sessions make the app sign out on
      // the next online check). New devices register via /api/license.
      const sessions = normalizeSessions(lic);
      const mine = sessions.find((s) => s.deviceId === deviceId);
      let sessionActive = false;
      if (mine) {
        mine.lastSeen = now;
        lic.sessions = sessions;
        await putLic(env, key, lic);
        sessionActive = true;
      }
      return json({
        ...base,
        sessionActive,
        sessions: sessions.map(sessionSummary),
        activeSessions: activeSessionsOf(lic, now).length,
      });
    }
    const reg = registerSession(lic, info, now);
    if (!reg.ok) {
      return json(
        { ok: false, error: 'session-limit', maxUsers: reg.maxUsers, activeCount: reg.activeCount, sessions: reg.sessions },
        409
      );
    }
    await putLic(env, key, lic);
    return json({
      ...base,
      sessionId: reg.sessionId,
      sessions: reg.sessions,
      activeSessions: reg.activeCount,
    });
  }

  // v2.1: session management from the app. deviceId must be one of the
  // licence's own sessions (proof of ownership from the app side); the
  // bot manages sessions with telegramId ownership instead.
  if ((url.pathname === '/api/sessions/revoke' || url.pathname === '/api/sessions/revoke-all') && request.method === 'POST') {
    const body = await request.json().catch(() => ({}));
    const key = String(body.key || '').trim();
    const deviceId = String(body.deviceId || '').trim();
    if (!key || !deviceId) return json({ ok: false, error: 'missing-params' }, 400);
    const lic = await getLic(env, key);
    if (!lic || !lic.expiresAt) return json({ ok: false, error: 'invalid' }, 404);
    if (lic.plan === 'revoked') return json({ ok: false, error: 'revoked' }, 403);
    const caller = normalizeSessions(lic).find((s) => s.deviceId === deviceId);
    if (!caller) return json({ ok: false, error: 'forbidden' }, 403);
    if (url.pathname === '/api/sessions/revoke') {
      const sessionId = String(body.sessionId || '').trim();
      if (!sessionId) return json({ ok: false, error: 'missing-params' }, 400);
      if (!revokeSessionFrom(lic, sessionId)) return json({ ok: false, error: 'session-not-found' }, 404);
    } else {
      const keep = String(body.keepSessionId || '').trim() || null;
      revokeAllSessionsFrom(lic, keep);
    }
    await putLic(env, key, lic);
    const now = Math.floor(Date.now() / 1000);
    return json({
      ok: true,
      sessions: normalizeSessions(lic).map(sessionSummary),
      activeSessions: activeSessionsOf(lic, now).length,
      maxUsers: maxUsersOf(lic),
    });
  }

  if (url.pathname === '/api/health') {
    return json({ ok: true, service: 'VoidrauVPN License API', time: Math.floor(Date.now() / 1000), version: BOT_VERSION });
  }

  if (url.pathname === '/api/trial' && request.method === 'POST') {
    const body = await request.json().catch(() => ({}));
    const tid = String(body.telegramId || '').trim();
    if (!/^\d{3,}$/.test(tid)) return json({ ok: false, error: 'bad-id' }, 400);

    const ip = request.headers.get('cf-connecting-ip') || 'x';
    const rlKey = `rl:${ip}`;
    const rl = parseInt((await env.LICENSES.get(rlKey)) || '0');
    if (rl >= 5) return json({ ok: false, error: 'rate-limited' }, 429);
    await env.LICENSES.put(rlKey, String(rl + 1), { expirationTtl: 600 });

    const used2 = await env.LICENSES.get(`trial:${tid}`);
    if (used2) return json({ ok: false, error: 'trial-used' }, 200);

    // Paid licence first: return it WITHOUT burning the trial claim.
    const existing = await userKey(env, tid);
    const exLic = existing ? await getLic(env, existing) : null;
    const now = Math.floor(Date.now() / 1000);
    if (exLic && exLic.expiresAt && exLic.expiresAt > now && exLic.plan !== 'trial' && exLic.plan !== 'revoked') {
      return json({
        ok: true,
        key: existing,
        plan: exLic.plan,
        expiresAt: exLic.expiresAt,
        serverTime: now,
        isPaid: true,
      });
    }

    // M5: claim the trial BEFORE minting, then verify the claim survived.
    // KV has no compare-and-swap, so two truly simultaneous POSTs can still
    // both pass — the window is now one claim round-trip instead of the
    // whole mint, and the pre-mint re-check below closes it further.
    const claim = crypto.randomUUID();
    await env.LICENSES.put(`trial:${tid}`, claim);
    const check = await env.LICENSES.get(`trial:${tid}`);
    if (check !== claim) return json({ ok: false, error: 'trial-used' }, 200);

    const TD = await trialDaysOf(env);
    if ((await env.LICENSES.get(`trial:${tid}`)) !== claim) {
      return json({ ok: false, error: 'trial-used' }, 200);
    }
    const key = await issueKey(env, tid, TD, 'trial');
    return json({
      ok: true,
      key,
      plan: 'trial',
      expiresAt: now + TD * 86400,
      serverTime: now,
      daysLeft: TD,
      isPaid: false,
    });
  }

  // ── Telegram webhook ─────────────────────────────────────────────────
  if (url.pathname === '/webhook' && request.method === 'POST') {
    // C2 hardening: prefer a fixed secret from env (WEBHOOK_SECRET, set as a
    // Cloudflare secret) so the check survives even if the KV value is ever
    // lost; fall back to the random KV secret registered by /setup.
    const whs = env.WEBHOOK_SECRET || (await env.LICENSES.get('set:whsecret'));
    const hdr = request.headers.get('X-Telegram-Bot-Api-Secret-Token');
    if (whs && hdr !== whs) return new Response('forbidden', { status: 403 });
    const upd = await request.json();

    try {
      await env.LICENSES.put(
        'lastUpdate',
        JSON.stringify({
          at: new Date().toISOString(),
          kind: upd.message
            ? 'message(' + String(upd.message.text || '').length + 'ch)'
            : upd.callback_query
            ? 'callback:' + upd.callback_query.data
            : 'other',
          from: upd.message?.from?.id || upd.callback_query?.from?.id || null,
        })
      );
      await env.LICENSES.delete('lastError');
    } catch (_) {}

    const steps = ['recv'];
    try {
      await handle(upd, env, steps, ctx);
      steps.push('done');
    } catch (e) {
      steps.push('ERROR: ' + String(e && e.stack || e).slice(0, 300));
      try {
        await env.LICENSES.put('lastError', steps.join(' > '));
      } catch (_) {}
    }
    try {
      await env.LICENSES.put('lastSteps', steps.join(' > '));
    } catch (_) {}
    return new Response('ok');
  }

  if (url.pathname === '/' || url.pathname === '/setup') {
    const self = `${url.protocol}//${url.host}/webhook`;
    // C2: the admin must run /setup once after the v2.0.1 deploy so Telegram
    // registers the webhook WITH this secret_token (the live webhook was
    // registered 2026-10-20, before any secret existed). Until then the
    // secret check above accepts everything.
    let whs = env.WEBHOOK_SECRET || (await env.LICENSES.get('set:whsecret'));
    if (!whs) {
      whs = crypto.randomUUID().replace(/-/g, '');
      await env.LICENSES.put('set:whsecret', whs);
    }
    // L2: the /diag key is a fresh random secret, never the (public) ADMIN_ID.
    let diagKey = await env.LICENSES.get('set:diagkey');
    if (!diagKey) {
      diagKey = crypto.randomUUID().replace(/-/g, '');
      await env.LICENSES.put('set:diagkey', diagKey);
    }
    try {
      await env.LICENSES.put('set:workerhost', url.host);
    } catch (_) {}
    const set = await tgSafe(
      env.BOT_TOKEN || '',
      'setWebhook',
      {
        url: self,
        allowed_updates: ['message', 'callback_query'],
        drop_pending_updates: false,
        secret_token: whs,
      },
      env
    );
    const me0 = await tgSafe(env.BOT_TOKEN || '', 'getMe', {}, env);
    if (me0 && me0.ok && me0.result?.username) {
      await env.LICENSES.put('set:botusername', me0.result.username);
    }
    // v2.0: register the bot menu commands (/start, /help, /id).
    await tgSafe(env.BOT_TOKEN || '', 'setMyCommands', {
      commands: [
        { command: 'start', description: 'شروع و بازگشت به خانه' },
        { command: 'help', description: 'راهنمای استفاده' },
        { command: 'id', description: 'آیدی عددی من' },
      ],
    }, env);
    if (env.LICENSES) {
      await env.LICENSES.put(
        'lastSetup',
        JSON.stringify({ at: new Date().toISOString(), ok: !!set?.ok, error: set?.description || null })
      );
    }
    if (url.pathname === '/') {
      return new Response(
        `VoidrauVPN license bot — alive & operational.\nWebhook: ${
          set?.ok ? 'SET ✓' : 'FAILED: ' + (set?.description || '?')
        }`
      );
    }
    return json({ setup: set });
  }

  if (url.pathname === '/diag') {
    // L2: ADMIN_ID is public (it sits in wrangler.toml in the public repo),
    // so it can no longer be the only gate. /diag now also needs the random
    // diag key stored in KV (set:diagkey); the admin gets the full URL from
    // the bot with /diagkey, never from chat or the repo.
    const diagKey = await env.LICENSES.get('set:diagkey');
    if (
      String(url.searchParams.get('a') || '') !== String(env.ADMIN_ID || '') ||
      !diagKey ||
      String(url.searchParams.get('k') || '') !== diagKey
    ) {
      return json({ ok: false, error: 'forbidden' }, 403);
    }
    const me = await tgSafe(env.BOT_TOKEN || '', 'getMe', {});
    const hook = await tgSafe(env.BOT_TOKEN || '', 'getWebhookInfo', {});
    const lastError = await env.LICENSES.get('lastError');
    const lastUpdate = await env.LICENSES.get('lastUpdate');
    const lastSentId = await env.LICENSES.get('lastSentId');
    const lastSetup = await env.LICENSES.get('lastSetup');
    const lastSteps = await env.LICENSES.get('lastSteps');
    const users = await env.LICENSES.get('stat:users');
    const pending = await countPending(env);
    return json({
      lastSteps,
      lastSetup: lastSetup ? JSON.parse(lastSetup) : null,
      lastUpdate: lastUpdate ? JSON.parse(lastUpdate) : null,
      lastSentId,
      lastError,
      stats: { users, pending },
      botTokenSet: !!env.BOT_TOKEN,
      adminIdSet: !!env.ADMIN_ID,
      kvSet: !!env.LICENSES,
      getMe: me,
      webhook: hook,
    });
  }

  return json({ ok: false, error: 'not-found' }, 404);
}

async function handle(upd, env, steps, ctx) {
  const token = env.BOT_TOKEN;
  const msg = upd.message;
  const cb = upd.callback_query;

  if (cb) {
    steps.push('cb:' + cb.data);
    const tid = cb.from.id;
    let out = null;

    const gate = await joinGatePrompt(env, tid);
    if (gate) {
      out = gate;
    } else if (cb.data === 'recheck') {
      const gate2 = await joinGatePrompt(env, tid);
      if (gate2) {
        out = gate2;
      } else {
        const pendingStart = await env.LICENSES.get(`startpending:${tid}`);
        if (pendingStart) await env.LICENSES.delete(`startpending:${tid}`);
        out = await startPayloadAction(env, cb.from, pendingStart || '', steps);
      }
    } else if (cb.data === 'trial') {
      out = await doTrial(env, tid);
    } else if (cb.data === 'buy') {
      out = await buyMenuFull(env);
    } else if (cb.data === 'ref') {
      out = await doReferral(env, tid);
    } else if (cb.data === 'mykey') {
      out = await doMyKey(env, tid);
    } else if (cb.data.startsWith('plan:')) {
      out = await doPlan(env, tid, cb.data.slice(5));
    } else if (cb.data.startsWith('okr:') && String(tid) === String(env.ADMIN_ID)) {
      const [, tS, dS] = cb.data.split(':');
      const target = tS;
      const days = parseInt(dS);
      const recRaw = await env.LICENSES.get(`receipt:${target}`);
      // v2.1: the receipt remembers which plan was picked, so a newly
      // issued licence takes that plan's device limit (extend keeps
      // maxUsers untouched on an existing licence).
      let recPlanId = null;
      try { recPlanId = JSON.parse(recRaw || 'null')?.planId || null; } catch (_) {}
      if (!recRaw) {
        out = { text: `ℹ️ رسید کاربر ${target} قبلاً پردازش شده است.` };
      } else if (!Number.isFinite(days) || days < 1 || days > 3650) {
        out = { text: '❌ تعداد روز نامعتبر در دکمهٔ تایید.' };
      } else {
        await env.LICENSES.delete(`receipt:${target}`);
        await env.LICENSES.put('stat:pending', String(await countPending(env)));
        await setReceiptStatus(env, target, 'approved', null);

        let k = await userKey(env, target);
        let l = k ? await getLic(env, k) : null;
        if (l && l.expiresAt) {
          await extend(env, k, days);
          await upgradePlan(env, k, 'paid');
        } else {
          k = await issueKey(env, target, days, 'paid');
          if (recPlanId) {
            const plans = await plansOf(env);
            const pp = plans.find((x) => x.id === recPlanId);
            const nl = await getLic(env, k);
            if (pp && nl) {
              nl.maxUsers = planMaxUsers(pp);
              await putLic(env, k, nl);
            }
          }
        }
        // M4: one bounded extend for all stored credit (see applyCredit).
        await applyCredit(env, k, target);
        const updatedLic = await getLic(env, k);
        await tgSafe(
          env.BOT_TOKEN,
          'sendMessage',
          {
            chat_id: target,
            text:
              `✅ *پرداخت شما تایید شد!*\n\n` +
              `🔑 کد لایسنس شما:\n\`${k}\`\n\n` +
              `⏳ به مدت *${days} روز* فعال شد.\n` +
              `📅 تاریخ انقضا: *${formatJalali(updatedLic?.expiresAt)}*\n\n` +
              `کد را کپی کرده و در برنامه وارد نمایید. متشکریم!`,
            parse_mode: 'Markdown',
          },
          env,
          steps
        );
        if (cb.message?.chat) {
          await tgSafe(
            env.BOT_TOKEN,
            'editMessageReplyMarkup',
            {
              chat_id: cb.message.chat.id,
              message_id: cb.message.message_id,
              reply_markup: { inline_keyboard: [] },
            },
            env,
            steps
          );
        }
        out = { text: `✅ رسید تایید و کد به کاربر ${target} ارسال شد.` };
      }
    } else if (cb.data.startsWith('rej:') && String(tid) === String(env.ADMIN_ID)) {
      const ru = cb.data.slice(4);
      await env.LICENSES.delete(`receipt:${ru}`);
      await env.LICENSES.put('stat:pending', String(await countPending(env)));
      await setReceiptStatus(env, ru, 'rejected', null);

      await tgSafe(
        env.BOT_TOKEN,
        'sendMessage',
        {
          chat_id: ru,
          text:
            '❌ رسید ارسالی شما تایید نشد.\n\n' +
            'دلایل معمول: ناخوانا بودن تصویر، عدم واریز، یا عدم تطابق مبلغ.\n' +
            'لطفاً تصویر واضح‌تری بفرستید یا با پشتیبانی تماس بگیرید.',
        },
        env,
        steps
      );
      if (cb.message?.chat) {
        await tgSafe(
          env.BOT_TOKEN,
          'editMessageReplyMarkup',
          {
            chat_id: cb.message.chat.id,
            message_id: cb.message.message_id,
            reply_markup: { inline_keyboard: [] },
          },
          env,
          steps
        );
      }
      out = { text: `❌ رسید کاربر ${ru} رد شد و به او اطلاع داده شد.` };
    } else if (cb.data === 'dl' || cb.data === 'dlrefresh') {
      if (cb.data === 'dlrefresh') await env.LICENSES.delete('cache:relfiles');
      out = await doDownloads(env, tid);
    } else if (cb.data.startsWith('file:')) {
      const idx = parseInt(cb.data.slice(5));
      let pick = [];
      try {
        pick = JSON.parse((await env.LICENSES.get(`${DL_FILES_KEY}:${tid}`)) || '[]');
      } catch (_) {}
      const f = pick[idx];
      if (!f) {
        out = await doDownloads(env, tid);
      } else {
        await tgSafe(token, 'answerCallbackQuery', { callback_query_id: cb.id, text: '⏳ در حال ارسال فایل...' });
        cb._answered = true;
        try {
          const sent = await sendReleaseFile(env, tid, f.url, f.name, f.size);
          // Only report success when the file was really sent. When the
          // file was over Telegram's limit, sendReleaseFile already sent
          // its direct download link — claiming a send here would be a lie.
          if (sent === true) {
            await sendReply(env, tid, {text: '✅ فایل برنامه با موفقیت ارسال شد 👆\n🤖 اندروید: فایل را باز کرده و نصب کنید.\n🪟 ویندوز: فایل نصبی را اجرا فرمایید.',});
          }
        } catch (e) {
          await sendReply(env, tid, {text: `❌ ارسال فایل ناموفق بود: ${e.message}\nلطفاً دوباره امتحان کنید.`,
            reply_markup: {
              inline_keyboard: withHome([
                [{ text: '🔄 تلاش دوباره', callback_data: `file:${idx}` }],
                [{ text: '📜 لیست فایل‌ها', callback_data: 'dl' }],
              ]),
            },});
        }
        out = null;
      }
    } else if (cb.data === 'help') {
      out = await doHelp();
    } else if (cb.data === 'support') {
      out = await doSupport(env);
    } else if (cb.data === 'status') {
      out = await doStatus(env, tid);
    } else if (cb.data === 'sessions') {
      out = await doSessions(env, tid);
    } else if (cb.data.startsWith('sesdel:')) {
      const sid = cb.data.slice(7);
      const key = await userKey(env, tid);
      const lic = key ? await getLic(env, key) : null;
      if (!lic || String(lic.telegramId || '') !== String(tid)) {
        out = { text: '⛔ این لایسنس به شما تعلق ندارد.', reply_markup: { inline_keyboard: homeRow() } };
      } else if (!revokeSessionFrom(lic, sid)) {
        out = { text: '⚠️ این نشست قبلاً حذف شده است.', reply_markup: { inline_keyboard: homeRow() } };
      } else {
        await putLic(env, key, lic);
        const page = await doSessions(env, tid);
        page.text = '✅ نشست حذف شد.\n\n' + page.text;
        out = page;
      }
    } else if (cb.data === 'sesdelall') {
      const key = await userKey(env, tid);
      const lic = key ? await getLic(env, key) : null;
      if (!lic || String(lic.telegramId || '') !== String(tid)) {
        out = { text: '⛔ این لایسنس به شما تعلق ندارد.', reply_markup: { inline_keyboard: homeRow() } };
      } else {
        out = {
          text: '⚠️ *حذف همهٔ نشست‌ها؟*\n\nهمهٔ دستگاه‌ها از لایسنس خارج می‌شوند و برای اتصال دوباره باید کد لایسنس را در برنامه وارد کنند.\n\nمطمئن هستید؟',
          parse_mode: 'Markdown',
          reply_markup: {
            inline_keyboard: withHome([
              [{ text: '✅ بله، همه را حذف کن', callback_data: 'sesdelall:yes' }],
              [{ text: '❌ لغو', callback_data: 'sessions' }],
            ]),
          },
        };
      }
    } else if (cb.data === 'sesdelall:yes') {
      const key = await userKey(env, tid);
      const lic = key ? await getLic(env, key) : null;
      if (!lic || String(lic.telegramId || '') !== String(tid)) {
        out = { text: '⛔ این لایسنس به شما تعلق ندارد.', reply_markup: { inline_keyboard: homeRow() } };
      } else {
        revokeAllSessionsFrom(lic, null);
        await putLic(env, key, lic);
        const page = await doSessions(env, tid);
        page.text = '✅ همهٔ نشست‌ها حذف شدند. دستگاه‌ها باید دوباره لایسنس را فعال کنند.\n\n' + page.text;
        out = page;
      }
    } else if (cb.data === 'home') {
      await env.LICENSES.delete(`gift:${tid}`);
      await env.LICENSES.delete(`supMode:${tid}`);
      const k0 = await userKey(env, tid);
      out = await mainMenu(env, cb.from, k0 ? await getLic(env, k0) : null);
    } else if (cb.data === 'gift') {
      out = await doGiftHome(env, tid);
    } else if (cb.data === 'gift:yes') {
      let g = null;
      try {
        g = JSON.parse((await env.LICENSES.get(`gift:${tid}`)) || 'null');
      } catch (_) {}
      if (!g || g.stage !== 'confirm' || !g.friend || !g.days) {
        out = { text: '⚠️ درخواست هدیه منقضی شده است — از خانه دوباره شروع کنید.', reply_markup: { inline_keyboard: homeRow() } };
      } else {
        const credit = parseInt((await env.LICENSES.get(`credit:${tid}`)) || '0');
        const err = giftValidate(tid, g.friend, g.days, credit);
        if (err) {
          await env.LICENSES.delete(`gift:${tid}`);
          out = { text: err === 'over-credit' ? '❌ اعتبار ذخیرهٔ شما کمتر از مقدار هدیه است.' : '❌ درخواست هدیه نامعتبر است.', reply_markup: { inline_keyboard: homeRow() } };
        } else {
          // M3: re-read the credit right before deducting — if another
          // concurrent gift changed it, abort instead of overspending.
          const creditNow = parseInt((await env.LICENSES.get(`credit:${tid}`)) || '0');
          if (creditNow !== credit) {
            await env.LICENSES.delete(`gift:${tid}`);
            out = { text: '⚠️ اعتبار ذخیرهٔ شما تغییر کرده است — لطفاً هدیه را از نو شروع کنید.', reply_markup: { inline_keyboard: homeRow() } };
          } else {
          await env.LICENSES.put(`credit:${tid}`, String(credit - g.days));
          let fk = await userKey(env, g.friend);
          let fl = fk ? await getLic(env, fk) : null;
          if (fl && fl.expiresAt) {
            await extend(env, fk, g.days);
          } else {
            fk = await issueKey(env, g.friend, g.days, 'paid');
          }
          const flic = await getLic(env, fk);
          const gl = parseInt((await env.LICENSES.get(`giftlog:${tid}`)) || '0');
          await env.LICENSES.put(`giftlog:${tid}`, String(gl + 1));
          await env.LICENSES.delete(`gift:${tid}`);
          const senderName = (await env.LICENSES.get(`name:${tid}`)) || 'یک دوست';
          await tgSafe(env.BOT_TOKEN, 'sendMessage', {
            chat_id: g.friend,
            text: `🎁 *هدیه دریافت کردید!*\n\n${escMd(senderName)} تعداد *${g.days} روز* لایسنس به شما هدیه داد.\n\n🔑 کد لایسنس شما:\n\`${fk}\`\n\n📅 تاریخ انقضا: *${formatJalali(flic?.expiresAt)}*\n\nکد را در برنامه (تب لایسنس) وارد کنید.`,
            parse_mode: 'Markdown',
            reply_markup: { inline_keyboard: [[{ text: '🏠 خانه', callback_data: 'home' }]] },
          }, env, steps);
          out = {
            text: `✅ هدیه با موفقیت ارسال شد!\n\n🎁 ${g.days} روز لایسنس به کاربر \`${g.friend}\` هدیه داده شد.\n💳 اعتبار باقی‌ماندهٔ شما: *${credit - g.days} روز*`,
            parse_mode: 'Markdown',
            reply_markup: { inline_keyboard: homeRow() },
          };
          }
        }
      }
    } else if (cb.data === 'gift:no') {
      await env.LICENSES.delete(`gift:${tid}`);
      const k0 = await userKey(env, tid);
      out = await mainMenu(env, cb.from, k0 ? await getLic(env, k0) : null);
    } else if (cb.data === 'checkin') {
      out = await doCheckin(env, tid);
    } else if (cb.data === 'top') {
      out = await doLeaderboard(env, tid);
    } else if (cb.data === 'receipt') {
      out = await doReceiptStatus(env, tid);
    } else if (cb.data === 'faq') {
      out = await doSupport(env);
    } else if (cb.data.startsWith('faq:')) {
      out = faqPayload(cb.data.slice(4)) || { text: 'سوال نامعتبر است.', reply_markup: { inline_keyboard: homeRow() } };
    } else if (cb.data === 'sup') {
      await env.LICENSES.put(`supMode:${tid}`, '1');
      out = {
        text: '✍️ *تماس با پشتیبانی*\n\nپیام خود را بنویسید و ارسال کنید (می‌توانید آیدی عددی و شرح مشکل را هم بنویسید). پشتیبانی در همین‌جا پاسخ می‌دهد.\n\nبرای انصراف، دکمهٔ زیر را بزنید:',
        parse_mode: 'Markdown',
        reply_markup: { inline_keyboard: [[{ text: '❌ انصراف', callback_data: 'supcancel' }]] },
      };
    } else if (cb.data === 'supcancel') {
      await env.LICENSES.delete(`supMode:${tid}`);
      const k0 = await userKey(env, tid);
      out = await mainMenu(env, cb.from, k0 ? await getLic(env, k0) : null);
    } else if (cb.data.startsWith('suprep:') && String(tid) === String(env.ADMIN_ID)) {
      const target = cb.data.slice(7);
      if (!/^\d{3,}$/.test(target)) {
        out = { text: '❌ آیدی کاربر نامعتبر است.' };
      } else {
        await env.LICENSES.put(`supMode:${tid}`, `reply:${target}`);
        out = {
          text: `✍️ در حال پاسخ به کاربر \`${target}\` هستید.\nپیام بعدی شما مستقیم به او ارسال می‌شود.`,
          parse_mode: 'Markdown',
          reply_markup: { inline_keyboard: [[{ text: '❌ انصراف', callback_data: 'ad:cancelmode' }]] },
        };
      }
    } else if (cb.data.startsWith('help:')) {
      const p = cb.data.slice(5);
      out = ['android', 'windows', 'ios'].includes(p)
        ? await doHelpPlatform(env, p)
        : await doHelp();
    } else if (cb.data.startsWith('fsetu:') && String(tid) === String(env.ADMIN_ID)) {
      // v2.1: quick maxUsers buttons under a /find result.
      const parts = cb.data.split(':');
      const fkey = parts[1];
      const n = parseInt(parts[2], 10);
      const flic = fkey ? await getLic(env, fkey) : null;
      if (!flic || !Number.isFinite(n) || n < 1 || n > 5) {
        out = { text: '❌ لایسنس یا عدد نامعتبر است.' };
      } else if (flic.plan === 'trial') {
        out = { text: '⚠️ تریال همیشه ۱ کاربر است و قابل تغییر نیست.' };
      } else {
        flic.maxUsers = n;
        await putLic(env, fkey, flic);
        out = await findPayload(env, fkey, flic.telegramId, flic);
        out.text = `✅ حداکثر کاربر به *${n} کاربر* تغییر کرد.\n\n` + out.text;
      }
    } else if (cb.data.startsWith('planusers:') && String(tid) === String(env.ADMIN_ID)) {
      // v2.1: per-plan device-limit buttons in the plan editor.
      const [, pid, nS] = cb.data.split(':');
      const n = parseInt(nS, 10);
      const plans = await plansOf(env);
      const p = plans.find((x) => x.id === pid);
      if (!p || !Number.isFinite(n) || n < 1 || n > 5) {
        out = { text: '❌ پلن یا عدد نامعتبر است.' };
      } else {
        p.maxUsers = n;
        await env.LICENSES.put('setting:plans', JSON.stringify(plans));
        const page = await planUsersEditor(env);
        page.text = `✅ حداکثر کاربر پلن «${escMd(p.label)}» به *${n} کاربر* تغییر کرد.\n\n` + page.text;
        out = page;
      }
    } else if (cb.data === 'ad:expiring' && String(tid) === String(env.ADMIN_ID)) {
      out = await expiringList(env);
    } else if (cb.data.startsWith('ad:') && String(tid) === String(env.ADMIN_ID)) {
      const a = cb.data.slice(3);
      if (a === 'cancelmode') {
        await env.LICENSES.delete(`admMode:${tid}`);
        await env.LICENSES.delete(`supMode:${tid}`);
        out = await adminPanel(env, tid);
      } else if (a === 'editbuy') {
        await env.LICENSES.put(`admMode:${tid}`, 'buyText');
        out = {
          text: 'متن جدید توضیحات خرید را ارسال کنید:\n(جهت انصراف دکمه لغو را بزنید)',
          reply_markup: { inline_keyboard: [[{ text: '❌ لغو', callback_data: 'ad:cancelmode' }]] },
        };
      } else if (a === 'editcard') {
        await env.LICENSES.put(`admMode:${tid}`, 'cardNumber');
        out = await askMode(env, tid, 'شماره کارت جدید جهت واریز را بفرستید:', 'cardNumber');
      } else if (a === 'editch') {
        await env.LICENSES.put(`admMode:${tid}`, 'forceChannel');
        out = await askMode(env, tid, 'آیدی کانال جوین اجباری را بفرستید (با @ یا آیدی عددی — خالی برای غیرفعال):', 'forceChannel');
      } else if (a === 'broadcast') {
        await env.LICENSES.put(`admMode:${tid}`, 'broadcast');
        out = await askMode(env, tid, 'متن یا عکس پیام همگانی را بفرستید:', 'broadcast');
      } else if (a === 'editsup') {
        await env.LICENSES.put(`admMode:${tid}`, 'supportId');
        out = await askMode(env, tid, 'آیدی یا یوزرنیم پشتیبانی را بفرستید (@...):', 'supportId');
      } else if (a === 'edittrial') {
        await env.LICENSES.put(`admMode:${tid}`, 'trialDays');
        out = await askMode(env, tid, 'تعداد روز تست رایگان را بفرستید (مثال: 1):', 'trialDays');
      } else if (a === 'editplans') {
        await env.LICENSES.put(`admMode:${tid}`, 'plans');
        out = await askMode(
          env,
          tid,
          'لیست پلن‌ها را بفرستید، هر خط: شناسه|برچسب|تعداد روز\nمثال:\nm1|۱ ماهه — ۱۰۰ هزار تومان|30\nm3|۳ ماهه — ۲۵۰ هزار تومان|90\nm12|یک‌ساله — ۸۰۰ هزار تومان|365',
          'plans'
        );
      } else if (a === 'plans') {
        out = await planUsersEditor(env);
      } else if (a === 'panel') {
        out = await adminPanel(env, tid);
      } else if (a === 'pending') {
        out = await pendingList(env, tid);
      } else if (a === 'users') {
        out = await recentUsers(env);
      } else if (a === 'export') {
        out = await exportBackup(env, tid);
      } else if (a === 'bcsend') {
        let bc = null;
        try {
          bc = JSON.parse((await env.LICENSES.get(`bc:${tid}`)) || 'null');
        } catch (_) {}
        await env.LICENSES.delete(`bc:${tid}`);
        await env.LICENSES.delete(`admMode:${tid}`);
        if (!bc || (!bc.text && !bc.fileId)) {
          out = { text: '⚠️ پیام همگانی یافت نشد — لطفاً از نو ارسال کنید.' };
        } else {
          const list = JSON.parse((await env.LICENSES.get('userIndex')) || '[]');
          // M7: send to the WHOLE list (no 300 cap) in the background via
          // ctx.waitUntil — the old code stopped at 300 users and still
          // reported success. The admin gets a completion summary here.
          const job = (async () => {
            const res = await runBroadcast(env, tid, bc, list);
            await tgSafe(env.BOT_TOKEN, 'sendMessage', {
              chat_id: tid,
              text: `📣 ارسال همگانی تمام شد: به ${res.n} کاربر رسید${res.fail ? `، ${res.fail} پیام ناموفق` : ''} (از مجموع ${list.length} کاربر).`,
            }, env);
            return res;
          })();
          if (ctx && typeof ctx.waitUntil === 'function') {
            ctx.waitUntil(job);
            out = { text: `📣 ارسال همگانی به ${list.length} کاربر آغاز شد؛ نتیجهٔ نهایی همین‌جا اعلام می‌شود.` };
          } else {
            const res = await job;
            out = { text: `📣 ارسال به ${res.n} کاربر انجام شد${res.fail ? ` (${res.fail} پیام ناموفق)` : ''}.` };
          }
        }
      } else if (a === 'stats') {
        out = await buildStatsMessage(env);
      }
    } else {
      out = { text: 'این دکمه منقضی شده است — لطفاً با /start از نو آغاز کنید.' };
    }

    if (out) await sendReply(env, tid, out, steps);
    if (!cb._answered) await tgSafe(token, 'answerCallbackQuery', { callback_query_id: cb.id }, env, steps);
    return;
  }

  if (!msg) {
    steps.push('no-msg');
    return;
  }
  const tid = msg.from.id;
  const text = (msg.text || '').trim();
  steps.push('msg:' + text.slice(0, 20));

  const mediaAdmin = msg.photo ? 'photo' : msg.document ? 'doc' : null;
  if (String(tid) === String(env.ADMIN_ID)) {
    const mode = await env.LICENSES.get(`admMode:${tid}`);
    if (mode && text.trim() === '/cancel') {
      await env.LICENSES.delete(`admMode:${tid}`);
      await sendReply(env, tid, {text: '❌ عملیات لغو شد.'}, steps);
      return;
    }
    if (mode === 'broadcast' && !text.startsWith('/') && (text || mediaAdmin)) {
      await env.LICENSES.put(
        `bc:${tid}`,
        JSON.stringify({
          text: mediaAdmin ? '' : text,
          fileId: mediaAdmin
            ? mediaAdmin === 'photo'
              ? msg.photo[msg.photo.length - 1].file_id
              : msg.document.file_id
            : null,
          kind: mediaAdmin,
          caption: msg.caption || '',
        })
      );
      await env.LICENSES.put(`admMode:${tid}`, 'bcconfirm');
      await sendReply(env, tid, {text: '📋 پیش‌نمایش پیام همگانی آماده شد. آیا مایلید به همهٔ کاربران ارسال شود؟',
          reply_markup: {
            inline_keyboard: [
              [{ text: '✅ بله، ارسال کن', callback_data: 'ad:bcsend' }],
              [{ text: '❌ لغو', callback_data: 'ad:cancelmode' }],
            ],
          },}, steps);
      return;
    }
    if (mode && !text.startsWith('/')) {
      await env.LICENSES.delete(`admMode:${tid}`);
      if (mediaAdmin) {
        await env.LICENSES.put(`admMode:${tid}`, mode);
        await sendReply(env, tid, {text: 'برای این بخش باید متن ارسال کنید.'}, steps);
        return;
      }
      if (mode === 'plans') {
        // v2.1: the text editor only sets id/label/days — a plan's
        // maxUsers survives a re-save (a new id gets its built-in default).
        const oldPlans = await plansOf(env);
        const rows = [];
        const bad = [];
        for (const [n, raw] of text.split('\n').entries()) {
          const l = raw.trim();
          if (!l) continue;
          const parts = l.split('|').map((x) => x.trim());
          const idOk = parts[0] && parts[0].length <= 40 && /^[\w-]+$/.test(parts[0]);
          const lblOk = parts[1] && parts[1].length <= 60;
          if (parts.length !== 3 || !idOk || !lblOk || !/^\d+$/.test(parts[2]) || parseInt(parts[2]) < 1) {
            bad.push(`خط ${n + 1}: ${l.slice(0, 40)}`);
            continue;
          }
          const pid = parts[0].replace(/\s+/g, '');
          rows.push({ id: pid, label: parts[1], days: parseInt(parts[2]), maxUsers: planMaxUsers(oldPlans.find((x) => x.id === pid) || { id: pid }) });
        }
        const ids = rows.map((r) => r.id);
        if (new Set(ids).size !== ids.length) {
          await sendReply(env, tid, {text: '❌ شناسهٔ تکراری در پلن‌ها وجود دارد.'}, steps);
          return;
        }
        if (bad.length) {
          await env.LICENSES.put(`admMode:${tid}`, mode);
          await sendReply(env, tid, {text: `❌ خطاهای یافت‌شده در پلن‌ها:\n${bad.join('\n')}\n\nلطفاً لیست کامل را اصلاح و مجدداً ارسال کنید.`,
              reply_markup: { inline_keyboard: [[{ text: '❌ لغو', callback_data: 'ad:cancelmode' }]] },}, steps);
          return;
        }
        if (!rows.length) {
          await env.LICENSES.put(`admMode:${tid}`, mode);
          await sendReply(env, tid, {text: '❌ هیچ پلن معتبری دریافت نشد.'}, steps);
          return;
        }
        await env.LICENSES.put('setting:plans', JSON.stringify(rows));
        await sendReply(env, tid, {text: `✅ تعداد ${rows.length} پلن با موفقیت ثبت شد:\n${rows
              .map((r) => `• ${r.label} (${r.days} روز)`)
              .join('\n')}`,}, steps);
      } else {
        let val = text.trim();
        if (mode === 'forceChannel') {
          if (!val || val === 'خالی' || val === '-') {
            await setSetting(env, mode, '');
            await sendReply(env, tid, {text: '✅ جوین اجباری غیرفعال شد.'}, steps);
            return;
          }
          const mch = val.match(/(?:t\.me\/|@)([A-Za-z0-9_]+)/);
          if (mch) val = '@' + mch[1];
          else if (/^-100\d+$/.test(val)) {
            // numeric id ok
          } else {
            await env.LICENSES.put(`admMode:${tid}`, mode);
            await sendReply(env, tid, {text: '❌ آیدی کانال نامعتبر است (مثال: @mychannel یا -100123456).'}, steps);
            return;
          }
        }
        if (mode === 'trialDays') {
          if (!/^\d+$/.test(val) || parseInt(val) < 1 || parseInt(val) > 365) {
            await env.LICENSES.put(`admMode:${tid}`, mode);
            await sendReply(env, tid, {text: '❌ عدد نامعتبر است (۱ تا ۳۶۵).'}, steps);
            return;
          }
          await env.LICENSES.put('setting:trialDays', val);
          await sendReply(env, tid, {text: `✅ مدت تست رایگان = ${val} روز تنظیم شد.`}, steps);
          return;
        }
        await setSetting(env, mode, val);
        await sendReply(env, tid, {text: `✅ تنظیم شد: ${val}`}, steps);
      }
      return;
    }
  }

  // ── v2.0: admin support-reply mode / user support mode / gift flow ──
  // These text flows run before receipt intake (media) and admin commands.
  if (String(tid) === String(env.ADMIN_ID) && text && !text.startsWith('/')) {
    const sup = await env.LICENSES.get(`supMode:${tid}`);
    if (sup && sup.startsWith('reply:')) {
      const target = sup.slice(6);
      if (/^\d{3,}$/.test(target)) {
        await env.LICENSES.delete(`supMode:${tid}`);
        // H1+H2: escape the reply text (a stray * or _ used to 400 the
        // send) and tell the admin honestly if it did not arrive.
        const sent = await tgSafe(env.BOT_TOKEN, 'sendMessage', {
          chat_id: target,
          text: `💬 *پاسخ پشتیبانی:*\n\n${escMd(text)}`,
          parse_mode: 'Markdown',
          reply_markup: { inline_keyboard: [[{ text: '🏠 خانه', callback_data: 'home' }]] },
        }, env, steps);
        await sendReply(env, tid, {text: sent ? `✅ پاسخ شما به کاربر \`${target}\` ارسال شد.` : `⚠️ ارسال پاسخ به کاربر \`${target}\` ناموفق بود (شاید ربات را بلاک کرده باشد).`, parse_mode: 'Markdown'}, steps);
        return;
      }
      await env.LICENSES.delete(`supMode:${tid}`);
    }
  }
  if (text && !text.startsWith('/')) {
    const sup = await env.LICENSES.get(`supMode:${tid}`);
    if (sup === '1') {
      await env.LICENSES.delete(`supMode:${tid}`);
      const senderName = (await env.LICENSES.get(`name:${tid}`)) || 'کاربر';
      // H1+H2: escape the user's name/text and tell the user honestly if
      // the forward failed, instead of showing "sent" for a lost message.
      const fwd = await tgSafe(env.BOT_TOKEN, 'sendMessage', {
        chat_id: env.ADMIN_ID,
        text: `🆘 *پیام پشتیبانی جدید*\n\n👤 از: ${escMd(senderName)} (\`${tid}\`)\n\n${escMd(text)}`,
        parse_mode: 'Markdown',
        reply_markup: { inline_keyboard: [[{ text: '✍️ پاسخ به این کاربر', callback_data: `suprep:${tid}` }]] },
      }, env, steps);
      if (!fwd) {
        await sendReply(env, tid, {text: '⚠️ ارسال پیام به پشتیبانی ناموفق بود. لطفاً دوباره تلاش کنید.', reply_markup: { inline_keyboard: homeRow() }}, steps);
        return;
      }
      await sendReply(env, tid, {text: '✅ پیام شما به پشتیبانی ارسال شد. پاسخ در همین‌جا برایتان می‌آید.', reply_markup: { inline_keyboard: homeRow() }}, steps);
      return;
    }
    let g = null;
    try {
      g = JSON.parse((await env.LICENSES.get(`gift:${tid}`)) || 'null');
    } catch (_) {}
    if (g && g.stage) {
      if (g.stage === 'awaitId') {
        const err = giftValidate(tid, text.trim(), 1, 1);
        if (err === 'bad-id') {
          await sendReply(env, tid, {text: '❌ آیدی عددی نامعتبر است. فقط عدد بفرستید (مثال: 123456789).', reply_markup: { inline_keyboard: homeRow() }}, steps);
          return;
        }
        if (err === 'self') {
          await sendReply(env, tid, {text: '❌ نمی‌توانید به خودتان هدیه بدهید. آیدی عددی دوست خود را بفرستید.', reply_markup: { inline_keyboard: homeRow() }}, steps);
          return;
        }
        await env.LICENSES.put(`gift:${tid}`, JSON.stringify({ stage: 'awaitDays', friend: text.trim() }));
        const credit = parseInt((await env.LICENSES.get(`credit:${tid}`)) || '0');
        await sendReply(env, tid, {text: `✅ گیرنده ثبت شد: \`${text.trim()}\`\n\nچند روز هدیه می‌دهید؟ (اعتبار شما: *${credit} روز* — عدد بفرستید)`, parse_mode: 'Markdown', reply_markup: { inline_keyboard: homeRow() }}, steps);
        return;
      }
      if (g.stage === 'awaitDays') {
        const credit = parseInt((await env.LICENSES.get(`credit:${tid}`)) || '0');
        const days = parseInt(text.trim(), 10);
        const err = giftValidate(tid, g.friend, text.trim(), credit);
        if (err === 'bad-days' || err === 'over-credit') {
          await sendReply(env, tid, {text: err === 'over-credit' ? `❌ مقدار هدیه بیشتر از اعتبار شماست (${credit} روز). عدد کوچک‌تری بفرستید.` : '❌ عدد نامعتبر است. تعداد روز را فقط با عدد بفرستید (مثال: 7).', reply_markup: { inline_keyboard: homeRow() }}, steps);
          return;
        }
        await env.LICENSES.put(`gift:${tid}`, JSON.stringify({ stage: 'confirm', friend: g.friend, days }));
        await sendReply(env, tid, {text: `🎁 *تایید هدیه*\n\n${days} روز لایسنس به کاربر \`${g.friend}\` هدیه داده می‌شود.\n💳 اعتبار باقی‌مانده پس از هدیه: *${credit - days} روز*\n\nمطمئن هستید؟`,
          parse_mode: 'Markdown',
          reply_markup: { inline_keyboard: [[{ text: '✅ بله، ارسال کن', callback_data: 'gift:yes' }, { text: '❌ لغو', callback_data: 'gift:no' }]] },}, steps);
        return;
      }
    }
  }

// Keep userIndex complete: a user can reach the receipt flow without ever
// pressing /start (buy menu via callback), and the admin scans (pending
// count, leaderboard, reminders) only see indexed users. L5 depends on it.
async function ensureIndexed(env, tid) {
  let idx = [];
  try {
    idx = JSON.parse((await env.LICENSES.get('userIndex')) || '[]');
    if (!Array.isArray(idx)) idx = [];
  } catch (_) {
    idx = [];
  }
  if (!idx.some((id) => String(id) === String(tid))) {
    idx.push(tid);
    await env.LICENSES.put('userIndex', JSON.stringify(idx));
    await env.LICENSES.put('stat:users', String(idx.length));
  }
}

  // ── Receipt intake ──────────────────────────────────────────────────
  const media2 = msg.photo ? 'photo' : msg.document ? 'doc' : null;
  if (media2) {
    // L4: a photo is a receipt ONLY when the user is in a purchase flow —
    // a plan was picked in the last 24h, or the caption says receipt/payment.
    // Any other photo (e.g. an error screenshot for support) is no longer
    // counted as a pending receipt and no longer overwrites a real one.
    const caption = (msg.caption || '').trim();
    const receiptWords = /(رسید|فیش|پرداخت|واریز|receipt)/i.test(caption);
    const planAt = parseInt((await env.LICENSES.get(`lastPlanAt:${tid}`)) || '0');
    const inPurchaseFlow = Date.now() - planAt < 24 * 3600 * 1000;
    if (!receiptWords && !inPurchaseFlow) {
      await sendReply(env, tid, {text: '📷 این عکس به‌عنوان رسید پرداخت ثبت نشد.\n\nاگر می‌خواهید خرید کنید، از خانه «🛒 خرید / تمدید» را بزنید، پلن را انتخاب کنید و بعد عکس رسید را همین‌جا بفرستید. اگر عکس را برای پشتیبانی فرستاده‌اید، از «🆘 پشتیبانی» پیام بدهید.',
          reply_markup: { inline_keyboard: withHome([[{ text: '🛒 خرید لایسنس', callback_data: 'buy' }]]) },}, steps);
      return;
    }
    await ensureIndexed(env, tid);
    const fid = media2 === 'photo' ? msg.photo[msg.photo.length - 1].file_id : msg.document.file_id;
    const selectedPlanId = await getSetting(env, `lastPlan:${tid}`, 'm1');
    const plans = await plansOf(env);
    const chosen = plans.find((p) => p.id === selectedPlanId) || plans[0];
    const hadReceipt = await env.LICENSES.get(`receipt:${tid}`);

    await env.LICENSES.put(
      `receipt:${tid}`,
      JSON.stringify({ fileId: fid, kind: media2, planId: selectedPlanId, at: Date.now() })
    );
    await setReceiptStatus(env, tid, 'pending', selectedPlanId);
    await env.LICENSES.put('stat:pending', String(await countPending(env)));

    const cap = `🧾 رسید جدید از کاربر \`${tid}\`${hadReceipt ? ' (جایگزین رسید قبلی)' : ''}\n📦 پلن انتخابی: *${escMd(chosen.label)}* (${chosen.days} روز)\n\nپلن مورد نظر را برای تایید انتخاب کنید:`;
    const approveRows = plans.map((p) => [
      { text: (p.id === chosen.id ? '⭐️ ' : '') + `تایید ${p.label}`, callback_data: `okr:${tid}:${p.days}` },
    ]);
    approveRows.push([{ text: '❌ رد رسید', callback_data: `rej:${tid}` }]);

    const fwd =
      media2 === 'photo'
        ? await tgSafe(
            env.BOT_TOKEN,
            'sendPhoto',
            {
              chat_id: env.ADMIN_ID,
              photo: fid,
              caption: cap,
              parse_mode: 'Markdown',
              reply_markup: { inline_keyboard: approveRows },
            },
            env,
            steps
          )
        : await tgSafe(
            env.BOT_TOKEN,
            'sendDocument',
            {
              chat_id: env.ADMIN_ID,
              document: fid,
              caption: cap,
              parse_mode: 'Markdown',
              reply_markup: { inline_keyboard: approveRows },
            },
            env,
            steps
          );

    if (!fwd || !fwd.ok) {
      await sendReply(env, tid, {text: '⚠️ ارسال رسید به ادمین با خطا مواجه شد. لطفاً دوباره تلاش نمایید یا با پشتیبانی تماس بگیرید.',}, steps);
      return;
    }
    await sendReply(env, tid, {text: '✅ رسید پرداخت شما دریافت شد و به مدیریت ارسال گردید.\nبه محض تایید، کد لایسنس اختصاصی همین‌جا برایتان ارسال خواهد شد.',}, steps);
    return;
  }

  // ── Admin Commands ──────────────────────────────────────────────────
  if (String(tid) === String(env.ADMIN_ID)) {
    if (text === '/diagkey') {
      // L2: the /diag URL (with its random key) is delivered only here, to
      // the admin's own Telegram chat — never in the public repo or chat.
      const diagKey = (await env.LICENSES.get('set:diagkey')) || '';
      const host = (await env.LICENSES.get('set:workerhost')) || 'voidrau.massagetoanishtayin.workers.dev';
      await sendReply(env, tid, {text: diagKey ? `🔐 لینک عیب‌یابی (فقط برای شما):\nhttps://${host}/diag?a=${env.ADMIN_ID}&k=${diagKey}\n\nاین لینک را با کسی به اشتراک نگذارید.` : '⚠️ کلید عیب‌یابی هنوز ساخته نشده است — اول یک‌بار /setup را در مرورگر باز کنید.'}, steps);
      return;
    }
    if (text === '/panel') {
      await sendReply(env, tid, (await adminPanel(env, tid)), steps);
      return;
    }
    if (text === '/stats') {
      await sendReply(env, tid, (await buildStatsMessage(env)), steps);
      return;
    }
    if (text.startsWith('/find')) {
      const q = (text.split(/\s+/)[1] || '').trim();
      if (!q) {
        await sendReply(env, tid, {text: 'فرمت: /find <آیدی عددی یا کد لایسنس>'});
        return;
      }
      let targetTid = q;
      let key = q;
      let lic = null;
      if (q.toUpperCase().startsWith('VDRV-')) {
        key = q.toUpperCase();
        lic = await getLic(env, key);
        targetTid = lic?.telegramId;
      } else {
        key = await userKey(env, targetTid);
        lic = key ? await getLic(env, key) : null;
      }
      if (!lic && !key) {
        await sendReply(env, tid, {text: `❌ موردی برای «${q}» یافت نشد.`});
        return;
      }
      await sendReply(env, tid, await findPayload(env, key, targetTid, lic), steps);
      return;
    }
    // v2.1: /setusers <key|tid> <1..5> — set a licence's device limit.
    // Trial is always 1 user and cannot be changed.
    if (text.startsWith('/setusers')) {
      const [, keyS, nS] = text.split(/\s+/);
      const n = parseInt(nS || '0', 10);
      if (!keyS || !Number.isFinite(n) || n < 1 || n > 5) {
        await sendReply(env, tid, {text: 'فرمت: /setusers <کد لایسنس یا آیدی> <عدد ۱ تا ۵>'});
        return;
      }
      let key = keyS;
      let lic = null;
      let targetTid = keyS;
      if (keyS.toUpperCase().startsWith('VDRV-')) {
        key = keyS.toUpperCase();
        lic = await getLic(env, key);
        targetTid = lic?.telegramId;
      } else {
        key = await userKey(env, targetTid);
        lic = key ? await getLic(env, key) : null;
      }
      if (!lic || !key) {
        await sendReply(env, tid, {text: `❌ لایسنسی برای «${keyS}» یافت نشد.`});
        return;
      }
      if (lic.plan === 'trial') {
        await sendReply(env, tid, {text: '⚠️ تریال همیشه ۱ کاربر است و قابل تغییر نیست.'});
        return;
      }
      lic.maxUsers = n;
      await putLic(env, key, lic);
      const cnt = normalizeSessions(lic).length;
      await sendReply(env, tid, {text: `✅ حداکثر کاربر لایسنس \`${key}\` به *${n} کاربر* تغییر کرد.\n📱 نشست‌های ثبت‌شده: ${cnt}`, parse_mode: 'Markdown'});
      return;
    }
    if (text.startsWith('/revoke')) {
      const q = (text.split(/\s+/)[1] || '').trim();
      if (!q) {
        await sendReply(env, tid, {text: 'فرمت: /revoke <آیدی عددی یا کد لایسنس>'});
        return;
      }
      let targetTid = q;
      let key = q;
      let lic = null;
      if (q.toUpperCase().startsWith('VDRV-')) {
        key = q.toUpperCase();
        lic = await getLic(env, key);
        targetTid = lic?.telegramId;
      } else {
        key = await userKey(env, targetTid);
        lic = key ? await getLic(env, key) : null;
      }
      if (!lic || !key) {
        await sendReply(env, tid, {text: `❌ لایسنسی برای «${q}» یافت نشد.`});
        return;
      }
      lic.expiresAt = 0;
      lic.plan = 'revoked';
      await putLic(env, key, lic);
      if (targetTid) {
        await tgSafe(token, 'sendMessage', { chat_id: targetTid, text: '⚠️ لایسنس شما توسط مدیریت باطل شد.' }, env);
      }
      await sendReply(env, tid, {text: `🚫 لایسنس \`${key}\` باطل گردید.`, parse_mode: 'Markdown'});
      return;
    }
    if (text.startsWith('/adddays')) {
      const [, targetS, daysS] = text.split(/\s+/);
      const days = parseInt(daysS || '0');
      if (!targetS || !Number.isFinite(days) || days < 1) {
        await sendReply(env, tid, {text: 'فرمت: /adddays <آیدی یا کد> <تعداد روز>'});
        return;
      }
      let targetTid = targetS;
      let key = targetS;
      let lic = null;
      if (targetS.toUpperCase().startsWith('VDRV-')) {
        key = targetS.toUpperCase();
        lic = await getLic(env, key);
        targetTid = lic?.telegramId;
      } else {
        key = await userKey(env, targetTid);
        lic = key ? await getLic(env, key) : null;
      }
      if (!lic || !key) {
        await sendReply(env, tid, {text: `❌ لایسنسی برای «${targetS}» یافت نشد.`});
        return;
      }
      await extend(env, key, days);
      const updated = await getLic(env, key);
      await sendReply(env, tid, {text: `✅ تعداد ${days} روز به لایسنس \`${key}\` اضافه شد.\n📅 تاریخ انقضای جدید: *${formatJalali(updated?.expiresAt)}*`,
          parse_mode: 'Markdown',});
      if (targetTid) {
        await tgSafe(
          token,
          'sendMessage',
          {
            chat_id: targetTid,
            text: `🎉 تعداد ${days} روز اعتبار هدیه به لایسنس شما اضافه گردید!\n📅 انقضای جدید: *${formatJalali(updated?.expiresAt)}*`,
            parse_mode: 'Markdown',
          },
          env
        );
      }
      return;
    }
    if (text.startsWith('/gen')) {
      const [, daysS, tidS] = text.split(/\s+/);
      const days = parseInt(daysS || '30');
      const target = tidS ? parseInt(tidS) : tid;
      if (!Number.isFinite(days) || days < 1 || days > 3650 || !Number.isFinite(target)) {
        await sendReply(env, tid, {text: 'فرمت: /gen <روز> [آیدی عددی]'});
        return;
      }
      const key = await issueKey(env, target, days, 'paid');
      const lic = await getLic(env, key);
      await sendReply(env, tid, {text: `🔑 لایسنس با موفقیت ساخته شد:\n\`${key}\`\n\nبرای کاربر: \`${target}\`\nمدت: ${days} روز\nانقضا: ${formatJalali(lic?.expiresAt)}`,
          parse_mode: 'Markdown',});
      return;
    }
    if (text.startsWith('/ok')) {
      const [, tidS, daysS] = text.split(/\s+/);
      const target = parseInt(tidS);
      const days = parseInt(daysS || '30');
      if (!/^\d{3,}$/.test(tidS || '') || !Number.isFinite(days) || days < 1 || days > 3650) {
        await sendReply(env, tid, {text: 'فرمت: /ok <آیدی عددی> <روز>'});
        return;
      }
      let key = await userKey(env, target);
      let lic = key ? await getLic(env, key) : null;
      let isNew = false;
      if (lic && lic.expiresAt) {
        await extend(env, key, days);
        await upgradePlan(env, key, 'paid');
      } else {
        key = await issueKey(env, target, days, 'paid');
        isNew = true;
      }
      // v2.1: a newly issued licence takes the device limit of the plan
      // the user last picked (extend keeps maxUsers on an existing one).
      if (isNew) {
        const lastPlanId = await getSetting(env, `lastPlan:${target}`, '');
        if (lastPlanId) {
          const plans = await plansOf(env);
          const pp = plans.find((x) => x.id === lastPlanId);
          const nl = await getLic(env, key);
          if (pp && nl) {
            nl.maxUsers = planMaxUsers(pp);
            await putLic(env, key, nl);
          }
        }
      }
      await applyCredit(env, key, target);
      await env.LICENSES.delete(`receipt:${target}`);
      await setReceiptStatus(env, target, 'approved', null);
      await env.LICENSES.put('stat:pending', String(await countPending(env)));

      const updated = await getLic(env, key);
      await sendReply(env, tid, {text: `✅ پرداخت تایید شد — ${days} روز برای \`${target}\`\n\`${key}\``,
          parse_mode: 'Markdown',});
      await tgSafe(
        token,
        'sendMessage',
        {
          chat_id: target,
          text:
            `✅ پرداخت شما با موفقیت تایید شد!\n\n` +
            `🔑 کد لایسنس شما:\n\`${key}\`\n\n` +
            `📅 تاریخ انقضا: *${formatJalali(updated?.expiresAt)}*\n\n` +
            `این کد را در برنامه (تب لایسنس) وارد فرمایید.`,
          parse_mode: 'Markdown',
        },
        env
      );
      return;
    }
    if (text.startsWith('/fix')) {
      const target = (text.split(/\s+/)[1] || '').trim();
      if (!target) {
        await sendReply(env, tid, {text: 'فرمت: /fix <آیدی کاربر>'});
        return;
      }
      const k = await userKey(env, target);
      if (!k) {
        await sendReply(env, tid, {text: `کاربر ${target} لایسنسی ندارد.`});
        return;
      }
      await upgradePlan(env, k, 'paid');
      const l = await getLic(env, k);
      await sendReply(env, tid, {text: `🔧 پلن کاربر ${target} به پولی تغییر یافت.\n\`${k}\`\nانقضا: ${formatJalali(l?.expiresAt)}`,
          parse_mode: 'Markdown',});
      return;
    }
  }

  // ── General Commands ────────────────────────────────────────────────
  if (text.startsWith('/start')) {
    steps.push('start-branch');
    const payload = text.split(/\s+/)[1] || '';
    const gate = await joinGatePrompt(env, tid);
    if (gate) {
      steps.push('join-gate');
      // Preserve supported deep links through the channel-join gate. Otherwise
      // Telegram's one-shot /start payload is lost when users tap "recheck".
      if (/^(trial|buy|ref|ref_\d{3,})$/.test(payload) && payload !== `ref_${tid}`) {
        await env.LICENSES.put(`startpending:${tid}`, payload, { expirationTtl: 86400 });
      }
      await sendReply(env, tid, gate, steps);
      return;
    }

    const response = await startPayloadAction(env, msg.from, payload, steps);
    await sendReply(env, tid, response, steps);
    return;
  }

  if (text === '/id') {
    await sendReply(env, tid, {text: `آیدی عددی شما:\n\`${tid}\``, parse_mode: 'Markdown'});
    return;
  }

  if (text === '/help' || text === '/commands') {
    if (String(tid) === String(env.ADMIN_ID)) {
      const adminHelp =
        `🛠 *دستورات مدیریت ربات:*\n\n` +
        `• \`/panel\` — باز کردن پنل تنظیمات ربات\n` +
        `• \`/stats\` — گزارش آمار سیستم\n` +
        `• \`/find <آیدی یا کد>\` — جستجو و جزئیات کاربر یا لایسنس\n` +
        `• \`/setusers <کد یا آیدی> <۱ تا ۵>\` — حداکثر دستگاه هم‌زمان یک لایسنس\n` +
        `• \`/gen <روز> [آیدی]\` — تولید لایسنس مستقیم\n` +
        `• \`/ok <آیدی> <روز>\` — تایید پرداخت کاربر\n` +
        `• \`/adddays <آیدی یا کد> <روز>\` — افزودن روز به لایسنس موجود\n` +
        `• \`/revoke <آیدی یا کد>\` — لغو و باطل کردن لایسنس\n` +
        `• \`/fix <آیدی>\` — ارتقای پلن کاربر به پولی\n` +
        `• \`/id\` — نمایش آیدی عددی\n` +
        `• \`/diagkey\` — لینک عیب‌یابی ربات (فقط ادمین)`;
      await sendReply(env, tid, {text: adminHelp, parse_mode: 'Markdown'});
      return;
    }
    await sendReply(env, tid, (await doHelp()));
    return;
  }

  await sendReply(env, tid, {text: '🤔 متوجه دستور نشدم. لطفاً از دکمه‌های منو یا دستور /start استفاده فرمایید.',}, steps);
}

// ── Commerce & Admin Panel Helpers ────────────────────────────────────
async function getSetting(env, k, dflt) {
  return (await env.LICENSES.get(`set:${k}`)) ?? dflt;
}

async function setSetting(env, k, v) {
  await env.LICENSES.put(`set:${k}`, v);
}

// M6: returns { joined, error }. On a getChatMember failure the gate now
// FAILS CLOSED (joined:false, error:true) instead of silently letting
// everyone through — a misconfigured forceChannel used to disable the gate
// without anyone noticing. The failure is recorded in lastError and shown
// in /panel.
async function checkJoined(env, tid) {
  const ch = (await getSetting(env, 'forceChannel', '')).trim();
  if (!ch) return { joined: true, error: false };
  const r = await tgSafe(env.BOT_TOKEN, 'getChatMember', { chat_id: ch, user_id: tid }, env);
  if (!r || !r.ok) {
    try {
      await env.LICENSES.put('lastError', `force-join: getChatMember ${ch}: ${r?.description || 'unknown'}`);
    } catch (_) {}
    return { joined: false, error: true };
  }
  const m = r.result || {};
  const st = m.status || 'left';
  if (st === 'restricted') return { joined: m.is_member === true, error: false };
  return { joined: ['member', 'administrator', 'creator'].includes(st), error: false };
}

function joinCheckFailedPrompt() {
  return {
    text: '⚠️ بررسی عضویت در کانال ممکن نشد.\n\nممکن است تنظیم کانال موقتاً مشکل داشته باشد. لطفاً چند دقیقه دیگر دوباره تلاش کنید:',
    reply_markup: {
      inline_keyboard: [[{ text: '🔄 تلاش دوباره', callback_data: 'recheck' }]],
    },
  };
}

// Returns the join-gate prompt when the user must (re)join, or null when
// they may proceed. `error` distinguishes "not a member" from "check failed".
async function joinGatePrompt(env, tid) {
  if (String(tid) === String(env.ADMIN_ID)) return null;
  const j = await checkJoined(env, tid);
  if (j.joined) return null;
  return j.error ? joinCheckFailedPrompt() : joinPrompt(await getSetting(env, 'forceChannel', ''));
}

function joinPrompt(ch) {
  return {
    text: '⛔ برای استفاده از ربات لطفاً ابتدا در کانال رسمی عضو شوید:',
    reply_markup: {
      inline_keyboard: [
        ...(/^\d+$/.test(String(ch))
          ? []
          : [[{ text: '📢 عضویت در کانال رسمی', url: `https://t.me/${String(ch).replace('@', '')}` }]]),
        [{ text: '✅ عضو شدم (بررسی مجدد)', callback_data: 'recheck' }],
      ],
    },
  };
}

async function buyMenuFull(env) {
  const card = await getSetting(env, 'cardNumber', 'تنظیم نشده — از /panel تنظیم کنید');
  const buyText = await getSetting(env, 'buyText', '🛒 *خرید لایسنس VoidrauVPN*');
  return {
    text: `${escMd(buyText)}\n\n💳 شماره کارت جهت واریز:\n\`${escMd(card)}\`\n\nلطفاً پلن مورد نظر را انتخاب و پس از واریز، عکس رسید را در همین چت ارسال نمایید:`,
    parse_mode: 'Markdown',
    reply_markup: {
      // v2.1: each plan label shows its device limit ("تا N کاربر").
      inline_keyboard: withHome((await plansOf(env)).map((p) => [{ text: `${p.label} (تا ${planMaxUsers(p)} کاربر)`, callback_data: `plan:${p.id}` }])),
    },
  };
}

async function askMode(env, tid, prompt, mode) {
  return { text: prompt, reply_markup: { inline_keyboard: [[{ text: '❌ لغو', callback_data: 'ad:cancelmode' }]] } };
}

async function adminLiveStats(env) {
  const idx = JSON.parse((await env.LICENSES.get('userIndex')) || '[]');
  const now = Math.floor(Date.now() / 1000);
  // M7: bounded parallel scan over the whole index (was sequential, 300 cap).
  const per = await mapLimit(idx, 25, async (u) => {
    const k = await env.LICENSES.get(`user:${u}`);
    if (!k) return null;
    const l = await getLic(env, k);
    if (l && l.expiresAt && l.expiresAt > now && l.plan !== 'revoked') {
      return { trial: l.plan === 'trial', expiring: Math.ceil((l.expiresAt - now) / 86400) <= 3 };
    }
    return null;
  });
  let active = 0;
  let trial = 0;
  let paid = 0;
  let expiring = 0;
  for (const p of per) {
    if (!p) continue;
    active++;
    if (p.trial) trial++;
    else paid++;
    if (p.expiring) expiring++;
  }
  const checkinsToday = parseInt((await env.LICENSES.get(`stat:checkins:${tehranDate()}`)) || '0');
  return { users: idx.length, active, trial, paid, expiring, checkinsToday };
}

async function expiringList(env) {
  const idx = JSON.parse((await env.LICENSES.get('userIndex')) || '[]');
  const now = Math.floor(Date.now() / 1000);
  // M7: bounded parallel scan over the whole index (was sequential, 300 cap).
  const found = await mapLimit(idx, 25, async (u) => {
    const k = await env.LICENSES.get(`user:${u}`);
    if (!k) return null;
    const l = await getLic(env, k);
    if (!l || !l.expiresAt || l.plan === 'revoked') return null;
    const daysLeft = Math.ceil((l.expiresAt - now) / 86400);
    if (daysLeft < 0 || daysLeft > 3) return null;
    return { u, daysLeft, plan: l.plan, exp: l.expiresAt };
  });
  const rows = found.filter(Boolean);
  rows.sort((a, b) => a.daysLeft - b.daysLeft);
  if (!rows.length) {
    return { text: '⏰ هیچ لایسنسی در ۳ روز آینده منقضی نمی‌شود.', reply_markup: { inline_keyboard: homeRow() } };
  }
  let t = `⏰ *لایسنس‌های در آستانهٔ انقضا (${rows.length} نفر):*\n\n`;
  for (const r of rows.slice(0, 20)) {
    t += `• \`${r.u}\` — ${r.daysLeft === 0 ? 'امروز' : `${r.daysLeft} روز دیگر`} (${r.plan}، انقضا ${formatJalali(r.exp)})\n`;
  }
  if (rows.length > 20) t += `\n…و ${rows.length - 20} نفر دیگر.`;
  return { text: t, parse_mode: 'Markdown', reply_markup: { inline_keyboard: homeRow() } };
}

async function buildStatsMessage(env) {
  const users = parseInt((await env.LICENSES.get('stat:users')) || '0');
  const pending = await countPending(env);
  const idx = JSON.parse((await env.LICENSES.get('userIndex')) || '[]');
  const now = Math.floor(Date.now() / 1000);
  let active = 0;
  let trial = 0;
  let paid = 0;

  // M7: bounded parallel scan of the 60-user sample.
  const sample = await mapLimit(idx.slice(-60), 25, async (u) => {
    const k = await env.LICENSES.get(`user:${u}`);
    if (!k) return null;
    const l = await getLic(env, k);
    if (l && l.expiresAt && l.expiresAt > now && l.plan !== 'revoked') {
      return l.plan === 'trial' ? 'trial' : 'paid';
    }
    return null;
  });
  for (const p of sample) {
    if (!p) continue;
    active++;
    if (p === 'trial') trial++;
    else paid++;
  }

  const live = await adminLiveStats(env);
  return {
    text:
      `📊 *آمار کلی سیستم VoidrauVPN*\n\n` +
      `👥 کل کاربران ثبت‌شده: *${users}*\n` +
      `🧾 رسیدهای در انتظار تایید: *${pending}*\n` +
      `✅ لایسنس‌های فعال (نمونه ۶۰ کاربر اخیر): *${active}*\n` +
      `🎁 لایسنس‌های تستی: *${trial}*\n` +
      `💰 لایسنس‌های پولی: *${paid}*\n\n` +
      `📈 *آمار زنده (تا ۳۰۰ کاربر):*\n` +
      `✅ فعال: *${live.active}* (تستی ${live.trial}، پولی ${live.paid})\n` +
      `⏰ در آستانهٔ انقضا (≤۳ روز): *${live.expiring}*\n` +
      `✅ چک‌این امروز: *${live.checkinsToday}*`,
    parse_mode: 'Markdown',
    reply_markup: { inline_keyboard: homeRow() },
  };
}

// v2.1: /find payload — licence/user details plus maxUsers, session
// counts, and quick buttons to change the device limit (not for trial).
async function findPayload(env, key, targetTid, lic) {
  const now = Math.floor(Date.now() / 1000);
  const active = lic && lic.expiresAt && lic.expiresAt > now && lic.plan !== 'revoked';
  const joins = targetTid ? parseInt((await env.LICENSES.get(`refjoin:${targetTid}`)) || '0') : 0;
  const credit = targetTid ? parseInt((await env.LICENSES.get(`credit:${targetTid}`)) || '0') : 0;
  const sessions = lic ? normalizeSessions(lic) : [];
  const activeCount = lic ? activeSessionsOf(lic, now).length : 0;
  const info =
    `🔍 *اطلاعات کاربر و لایسنس*\n\n` +
    `👤 آیدی عددی: \`${targetTid || 'نامشخص'}\`\n` +
    `🔑 کد لایسنس: \`${key || 'ندارد'}\`\n` +
    `📦 پلن: *${lic?.plan || 'نامشخص'}*\n` +
    `🚦 وضعیت: *${active ? 'فعال ✅' : 'غیرفعال / منقضی ❌'}*\n` +
    `⏳ باقی‌مانده: *${lic?.expiresAt ? formatDuration(lic.expiresAt - now) : '—'}*\n` +
    `📅 تاریخ انقضا: *${lic?.expiresAt ? formatJalali(lic.expiresAt) : '—'}*\n` +
    `👥 حداکثر کاربر: *${lic ? maxUsersOf(lic) : '—'}*\n` +
    `📱 نشست‌ها: *${activeCount} فعال از ${sessions.length} ثبت‌شده*\n` +
    `👥 تعداد دعوت‌ها: ${joins} نفر\n` +
    `🎁 اعتبار هدیه ذخیره: ${credit} روز`;
  const rows = [];
  if (lic && key && lic.plan !== 'trial') {
    rows.push([1, 2, 3, 5].map((v) => ({ text: (v === maxUsersOf(lic) ? '✅ ' : '') + `${v} کاربر`, callback_data: `fsetu:${key}:${v}` })));
  }
  return { text: info, parse_mode: 'Markdown', reply_markup: rows.length ? { inline_keyboard: rows } : undefined };
}

// v2.1: per-plan device-limit editor (admin panel). Each plan gets one
// row of 1/2/3/5-user buttons; the current value is marked ✅.
async function planUsersEditor(env) {
  const plans = await plansOf(env);
  let t = '👥 *کاربران هر پلن*\n\nبرای هر پلن، حداکثر تعداد دستگاه هم‌زمان را انتخاب کنید (۱ تا ۵).\nتریال همیشه ۱ کاربر است و قابل تغییر نیست.\n\n';
  const rows = [];
  for (const p of plans) {
    const n = planMaxUsers(p);
    t += `• ${escMd(p.label)} — تا *${n} کاربر*\n`;
    rows.push([1, 2, 3, 5].map((v) => ({ text: v === n ? `✅ ${p.id}: ${v}` : `${p.id}: ${v}`, callback_data: `planusers:${p.id}:${v}` })));
  }
  return {
    text: t,
    parse_mode: 'Markdown',
    reply_markup: { inline_keyboard: withHome([...rows, [{ text: '⬅️ بازگشت به پنل', callback_data: 'ad:panel' }]]) },
  };
}

async function adminPanel(env, tid) {
  const card = await getSetting(env, 'cardNumber', '—');
  const buy = await getSetting(env, 'buyText', 'خرید لایسنس');
  const ch = await getSetting(env, 'forceChannel', '—');
  const sup = await getSetting(env, 'supportId', '@Voidrau');
  const trialDays = String(await trialDaysOf(env));
  const users = parseInt((await env.LICENSES.get('stat:users')) || '0');
  const pending = await countPending(env);
  const lastErr = await env.LICENSES.get('lastError');
  const live = await adminLiveStats(env);

  return {
    text:
      `🛠 *پنل مدیریت ربات VoidrauVPN*\n\n` +
      `👥 کاربران: *${users}*\n` +
      `✅ فعال: *${live.active}* (تستی ${live.trial}، پولی ${live.paid})\n` +
      `⏰ در آستانهٔ انقضا (≤۳ روز): *${live.expiring}*\n` +
      `✅ چک‌این امروز: *${live.checkinsToday}*\n` +
      `🧾 رسید در انتظار: *${pending}*\n` +
      `💳 کارت: \`${escMd(card)}\`\n` +
      `🛒 متن خرید: ${escMd(buy)}\n` +
      `📢 کانال اجباری: ${escMd(ch)}\n` +
      `🎁 روز تست: ${trialDays} روز\n` +
      `🆘 پشتیبانی: ${escMd(sup)}` +
      (lastErr ? `\n⚠️ آخرین خطا: ${escMd(String(lastErr).slice(0, 120))}` : ''),
    parse_mode: 'Markdown',
    reply_markup: {
      inline_keyboard: withHome([
        [{ text: '✏️ متن خرید', callback_data: 'ad:editbuy' }, { text: '💳 شماره کارت', callback_data: 'ad:editcard' }],
        [{ text: '💰 قیمت‌ها', callback_data: 'ad:editplans' }, { text: '📢 کانال اجباری', callback_data: 'ad:editch' }],
        [{ text: '👥 کاربران هر پلن', callback_data: 'ad:plans' }],
        [{ text: '🆘 پشتیبانی', callback_data: 'ad:editsup' }, { text: '🎁 روز تست', callback_data: 'ad:edittrial' }],
        [{ text: '📊 آمار کامل', callback_data: 'ad:stats' }, { text: `🧾 رسیدها (${pending})`, callback_data: 'ad:pending' }],
        [{ text: '⏰ در آستانهٔ انقضا', callback_data: 'ad:expiring' }, { text: '👥 کاربران اخیر', callback_data: 'ad:users' }],
        [{ text: '📣 پیام همگانی', callback_data: 'ad:broadcast' }],
        [{ text: '💾 خروجی پشتیبان', callback_data: 'ad:export' }],
      ]),
    },
  };
}

async function pendingList(env, tid) {
  const idx = JSON.parse((await env.LICENSES.get('userIndex')) || '[]');
  // L3: plansOf() is read once, not twice per row. L5: the count comes from
  // this same scan (see countPending), not from the drifting stat:pending.
  const plans = await plansOf(env);
  const found = await mapLimit(idx, 25, async (u) => {
    const raw = await env.LICENSES.get(`receipt:${u}`);
    if (!raw) return null;
    const planId = await getSetting(env, `lastPlan:${u}`, 'm1');
    const p = plans.find((x) => x.id === planId) || plans[0];
    return [
      { text: `🧾 کاربر ${u} — ${p.label}`, callback_data: `okr:${u}:${p.days}` },
      { text: '❌', callback_data: `rej:${u}` },
    ];
  });
  const rows = found.filter(Boolean);
  const n = rows.length;
  return {
    text: n ? `🧾 تعداد ${n} رسید در انتظار تایید وجود دارد:` : '🧾 هیچ رسیدی در انتظار تایید نیست.',
    reply_markup: rows.length ? { inline_keyboard: withHome(rows) } : { inline_keyboard: homeRow() },
  };
}

// L5: the pending-receipt count is computed from the real receipt:* keys,
// never from the separate stat:pending counter that could drift after
// concurrent approvals or manual deletions.
async function countPending(env) {
  let idx = [];
  try {
    idx = JSON.parse((await env.LICENSES.get('userIndex')) || '[]');
    if (!Array.isArray(idx)) idx = [];
  } catch (_) {}
  const found = await mapLimit(idx, 25, async (u) => ((await env.LICENSES.get(`receipt:${u}`)) ? 1 : 0));
  return found.reduce((a, b) => a + b, 0);
}

async function recentUsers(env) {
  const idx = JSON.parse((await env.LICENSES.get('userIndex')) || '[]');
  const last = idx.slice(-15).reverse();
  let t = `👥 *آخرین کاربران (${idx.length} کل):*\n\n`;
  const now = Math.floor(Date.now() / 1000);
  const lines = await mapLimit(last, 25, async (u) => {
    const k = await env.LICENSES.get(`user:${u}`);
    let s = 'بدون لایسنس';
    if (k) {
      const l = await getLic(env, k);
      if (l && l.expiresAt) {
        s = l.expiresAt > now && l.plan !== 'revoked'
          ? `فعال تا ${formatJalali(l.expiresAt)} (${l.plan})`
          : 'منقضی/باطل';
      }
    }
    return `• \`${u}\` — ${s}\n`;
  });
  t += lines.join('');
  return { text: t, parse_mode: 'Markdown', reply_markup: { inline_keyboard: homeRow() } };
}

async function exportBackup(env, tid) {
  const idx = JSON.parse((await env.LICENSES.get('userIndex')) || '[]');
  const out = await mapLimit(idx.slice(0, 250), 25, async (u) => {
    const k = await env.LICENSES.get(`user:${u}`);
    const l = k ? await getLic(env, k) : null;
    return { id: u, key: k || null, plan: l?.plan || null, expiresAt: l?.expiresAt || null };
  });
  const body = JSON.stringify(out, null, 2);
  const fd = new FormData();
  fd.append('chat_id', String(tid));
  fd.append(
    'document',
    new Blob([body], { type: 'application/json' }),
    `voidrau-backup-${new Date().toISOString().slice(0, 10)}.json`
  );
  const up = await fetch(`https://api.telegram.org/bot${env.BOT_TOKEN}/sendDocument`, {
    method: 'POST',
    body: fd,
  });
  const j = await up.json().catch(() => ({}));
  if (j.ok) return { text: `💾 پشتیبان کامل (${out.length} کاربر) به‌صورت فایل ارسال شد 👆` };
  return { text: `💾 خروجی پشتیبان:\n\`\`\`json\n${body.slice(0, 3000)}\n\`\`\``, parse_mode: 'Markdown' };
}

async function doTrial(env, tid) {
  const used = await env.LICENSES.get(`trial:${tid}`);
  if (used) {
    const key = await userKey(env, tid);
    const lic = key ? await getLic(env, key) : null;
    if (!lic) return { text: '🔑 لایسنس قبلی یافت نشد — لطفاً با پشتیبانی تماس بگیرید.', reply_markup: { inline_keyboard: homeRow() } };
    const now = Math.floor(Date.now() / 1000);
    const active = lic.expiresAt && lic.expiresAt > now && lic.plan !== 'revoked';
    if (active) {
      return {
        text:
          `🎁 لایسنس شما هم‌اکنون فعال است:\n\`${key}\`\n\n` +
          `⏳ زمان باقی‌مانده: *${formatDuration(lic.expiresAt - now)}*\n` +
          `📅 تاریخ انقضا: *${formatJalali(lic.expiresAt)}*\n\n` +
          `کد را در برنامه (تب لایسنس) وارد کنید.`,
        parse_mode: 'Markdown',
        reply_markup: { inline_keyboard: homeRow() },
      };
    }
    return {
      text: '⏳ دورهٔ تست رایگان شما به پایان رسیده است.\nبرای ادامه اتصال امن، لطفاً اشتراک تهیه نمایید:',
      reply_markup: { inline_keyboard: withHome([[{ text: '🛒 خرید لایسنس', callback_data: 'buy' }]]) },
    };
  }
  // M1: no trial marker yet — first show an active paid licence instead of
  // burning the trial on top of it, then claim the trial (unique value,
  // verified) BEFORE minting anything. The old code minted the key and only
  // then marked the trial used, so two simultaneous taps both minted a
  // working key. KV has no compare-and-swap; the claim+verify narrows the
  // race to one round-trip.
  const key0 = await userKey(env, tid);
  const lic0 = key0 ? await getLic(env, key0) : null;
  const now0 = Math.floor(Date.now() / 1000);
  if (lic0 && lic0.expiresAt && lic0.expiresAt > now0 && lic0.plan !== 'trial' && lic0.plan !== 'revoked') {
    return {
      text:
        `🎁 لایسنس شما هم‌اکنون فعال است:\n\`${key0}\`\n\n` +
        `⏳ زمان باقی‌مانده: *${formatDuration(lic0.expiresAt - now0)}*\n` +
        `📅 تاریخ انقضا: *${formatJalali(lic0.expiresAt)}*\n\n` +
        `کد را در برنامه (تب لایسنس) وارد کنید.`,
      parse_mode: 'Markdown',
      reply_markup: { inline_keyboard: homeRow() },
    };
  }
  const claim = crypto.randomUUID();
  await env.LICENSES.put(`trial:${tid}`, claim);
  if ((await env.LICENSES.get(`trial:${tid}`)) !== claim) {
    return { text: '⏳ تست رایگان شما همین حالا فعال شد — از «🔑 کد لایسنس من» کد را ببینید.', reply_markup: { inline_keyboard: homeRow() } };
  }
  const TD = await trialDaysOf(env);
  const key = await issueKey(env, tid, TD, 'trial');
  await applyCredit(env, key, tid);
  const lic = await getLic(env, key);
  return {
    text:
      `🎁 *تست ${TD} روزه رایگان شما با موفقیت فعال شد!*\n\n` +
      `🔑 کد لایسنس اختصاصی شما:\n\`${key}\`\n\n` +
      `📅 انقضا: *${formatJalali(lic?.expiresAt)}*\n\n` +
      `📱 *نحوه استفاده:*\n` +
      `۱. روی کد لایسنس بالا ضربه بزنید تا کپی شود.\n` +
      `۲. برنامه VoidrauVPN را باز کنید و در تب «لایسنس»، کد را پیست نمایید.\n` +
      `۳. دکمه اتصال را بزنید و لذت ببرید!`,
    parse_mode: 'Markdown',
    reply_markup: { inline_keyboard: homeRow() },
  };
}

async function doPlan(env, tid, planId) {
  const p = (await plansOf(env)).find((x) => x.id === planId);
  if (!p) return { text: 'پلن نامعتبر.' };
  await setSetting(env, `lastPlan:${tid}`, p.id);
  await env.LICENSES.put(`lastPlanAt:${tid}`, String(Date.now()));
  const card = await getSetting(env, 'cardNumber', 'تنظیم نشده');
  return {
    text:
      `🛒 *پلن انتخابی:* ${escMd(p.label)}\n\n` +
      `👥 تا *${planMaxUsers(p)} دستگاه* هم‌زمان می‌توانند با این لایسنس وصل شوند.\n\n` +
      `💳 لطفاً مبلغ را به شماره کارت زیر واریز کنید:\n\`${escMd(card)}\`\n\n` +
      `سپس تصویر فیش یا اسکرین‌شات رسید را همین‌جا ارسال کنید تا تایید شود.`,
    parse_mode: 'Markdown',
    reply_markup: { inline_keyboard: homeRow() },
  };
}

async function startPayloadAction(env, user, payload, steps) {
  const tid = user.id;
  // v2.0: store the user's first name (for the referral leaderboard) and
  // clear any in-progress gift / support flow when returning home.
  if (user.first_name) {
    await env.LICENSES.put(`name:${tid}`, String(user.first_name).slice(0, 64));
  }
  await env.LICENSES.delete(`gift:${tid}`);
  await env.LICENSES.delete(`supMode:${tid}`);
  let idx = [];
  try {
    idx = JSON.parse((await env.LICENSES.get('userIndex')) || '[]');
    if (!Array.isArray(idx)) idx = [];
  } catch (_) {
    idx = [];
  }
  if (!idx.some((id) => String(id) === String(tid))) {
    idx.push(tid);
    await env.LICENSES.put('userIndex', JSON.stringify(idx));
    await env.LICENSES.put('stat:users', String(idx.length));
  }

  if (payload.startsWith('ref_')) {
    await recordReferralJoin(env, tid, payload.slice(4), steps);
  }
  if (payload === 'ref') return doReferral(env, tid);
  if (payload === 'trial') return doTrial(env, tid);
  if (payload === 'buy') return buyMenuFull(env);

  // Plain /start always returns the unified Home v2 — with an opportunistic
  // expiry reminder (also runs from scheduled() when cron is live).
  await maybeSendExpiryReminder(env, tid);
  const key = await userKey(env, tid);
  const lic = key ? await getLic(env, key) : null;
  return mainMenu(env, user, lic);
}

async function recordReferralJoin(env, inviteeId, referrerId, steps) {
  const invitee = String(inviteeId);
  const referrer = String(referrerId);
  if (!/^\d{3,}$/.test(referrer) || referrer === invitee) return false;
  // M3: claim this invitee with a unique value and verify it survived —
  // two simultaneous joins from the same link used to both count. (KV has
  // no atomic increment, so two joins from DIFFERENT invitees in the same
  // instant can still lose one increment; the per-invitee dedup — the
  // correctness-critical part — is fixed.)
  if (await env.LICENSES.get(`refseen:${invitee}`)) return false;
  const claim = crypto.randomUUID();
  await env.LICENSES.put(`refseen:${invitee}`, claim);
  if ((await env.LICENSES.get(`refseen:${invitee}`)) !== claim) return false;

  const previous = parseInt((await env.LICENSES.get(`refjoin:${referrer}`)) || '0', 10);
  const joins = (Number.isFinite(previous) ? previous : 0) + 1;
  await env.LICENSES.put(`refjoin:${referrer}`, String(joins));
  if (joins % REFERRAL_REWARD_JOINS === 0) {
    await addCredit(env, referrer, REFERRAL_REWARD_DAYS);
    await tgSafe(
      env.BOT_TOKEN,
      'sendMessage',
      {
        chat_id: referrer,
        text: `🎉 *تبریک!* ${REFERRAL_REWARD_JOINS} کاربر با لینک شما عضو شدند.\n*${REFERRAL_REWARD_DAYS} روز لایسنس هدیه* به حساب شما افزوده شد!`,
        parse_mode: 'Markdown',
      },
      env,
      steps
    );
  }
  return true;
}

async function doReferral(env, tid) {
  const botUser = env.BOT_USERNAME || (await env.LICENSES.get('set:botusername')) || 'VoidRauBot';
  const joins = parseInt((await env.LICENSES.get(`refjoin:${tid}`)) || '0');
  const credit = (await env.LICENSES.get(`credit:${tid}`)) || '0';
  const needed = REFERRAL_REWARD_JOINS - (joins % REFERRAL_REWARD_JOINS);
  // C1: the old message used parse_mode Markdown and the link always
  // contains ref_<id> — the underscore opens an italic entity Telegram can
  // never close, so EVERY invite failed with HTTP 400. Plain text keeps the
  // link tappable (Telegram auto-links t.me URLs) with no parse risk.
  return {
    text:
      `👥 سیستم دعوت دوستان (کسب اشتراک رایگان)\n\n` +
      `با ارسال لینک اختصاصی به دوستانتان، به ازای هر ${REFERRAL_REWARD_JOINS} نفر، ${REFERRAL_REWARD_DAYS} روز لایسنس رایگان دریافت می‌کنید!\n\n` +
      `🔗 لینک دعوت شما:\nhttps://t.me/${botUser}?start=ref_${tid}\n\n` +
      `📊 گزارش دعوت‌ها:\n` +
      `• تعداد افراد عضو شده: ${joins} نفر\n` +
      `• ${needed === REFERRAL_REWARD_JOINS ? 'دعوت بعدی شروع دور جدید پاداش' : `${needed} نفر مانده تا پاداش بعدی`}\n` +
      `• اعتبار ذخیره هدیه: ${credit} روز`,
    reply_markup: { inline_keyboard: withHome([[{ text: '🏆 لیدربورد دعوت', callback_data: 'top' }]]) },
  };
}

async function doMyKey(env, tid) {
  const key = await userKey(env, tid);
  if (!key) return { text: 'هنوز لایسنسی ندارید — از «🎁 تست رایگان» شروع فرمایید.' };
  const lic = await getLic(env, key);
  if (!lic || !lic.expiresAt || lic.plan === 'revoked') {
    return { text: 'لایسنس شما نامعتبر یا باطل شده است.' };
  }
  const now = Math.floor(Date.now() / 1000);
  const active = lic.expiresAt > now;
  const planLabel = lic.plan === 'paid' ? 'خریداری‌شده ویژه ⭐️' : (lic.plan === 'trial' ? 'تست رایگان موقت 🎁' : 'اختصاصی');
  return {
    text:
      `🔑 *کد لایسنس شما:*\n\`${key}\`\n\n` +
      `📦 نوع پلن: ${planLabel}\n` +
      `🚦 وضعیت: ${active ? 'فعال ✅' : 'منقضی شده ❌'}\n` +
      `⏳ زمان باقی‌مانده: *${formatDuration(lic.expiresAt - now)}*\n` +
      `📅 تاریخ انقضا: *${formatJalali(lic.expiresAt)}*\n\n` +
      `💡 برای کپی کردن، کافیست روی کد بالا ضربه بزنید.`,
    parse_mode: 'Markdown',
    reply_markup: { inline_keyboard: homeRow() },
  };
}

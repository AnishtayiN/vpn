// VoidrauVPN License Bot + API — Cloudflare Worker (single file). v2.0.0
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
//   • 📥 دانلود         → latest GitHub release files sent directly in-chat
//   • /panel            → interactive admin panel + live stat cards + expiring list
//   • /stats            → full statistics report (users, active, pending, revenue)
//   • /find <id|key>    → search any user or license key details
//   • /gen <days> [tid] → admin: mint a key
//   • /ok <tid> <days>  → admin: approve a pending purchase
//   • /adddays <id> <d> → admin: add bonus days to existing license
//   • /revoke <id|key>  → admin: revoke an abusive or refunded license
//   • /fix <tid>        → admin: upgrade user plan to paid
//   • /id               → show numeric telegram ID
//
// HTTP API (used by the app):
//   GET  /api/license?key=...   → { ok, plan, expiresAt, serverTime, remainingSeconds, isPaid }
//   GET  /api/status?key=...    → same shape as /license
//   GET  /api/health            → { ok, service, time, version }
//   POST /api/trial             → { ok, key, expiresAt, serverTime }

const BOT_VERSION = '2.0.0';

const DEFAULT_PLANS = [
  { id: 'm1', label: '۱ ماهه — ۱۰۰ هزار تومان', days: 30 },
  { id: 'm3', label: '۳ ماهه — ۲۵۰ هزار تومان', days: 90 },
  { id: 'm12', label: 'یک‌ساله — ۸۰۰ هزار تومان', days: 365 },
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

const homeRow = () => [[{ text: '🏠 خانه', callback_data: 'home' }]];
const withHome = (rows) => [...(rows || []), ...homeRow()];

async function getReleaseFiles(env) {
  let files = null;
  try {
    files = JSON.parse((await env.LICENSES.get('cache:relfiles')) || 'null');
  } catch (_) {}
  if (Array.isArray(files) && files.length) return files;
  files = (await releaseFiles(env)) || [];
  if (files.length) {
    await env.LICENSES.put('cache:relfiles', JSON.stringify(files), { expirationTtl: 600 });
  }
  return files;
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
  return typeof raw === 'string' ? JSON.parse(raw) : raw;
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

async function takeCredit(env, tid) {
  const cur = parseInt((await env.LICENSES.get(`credit:${tid}`)) || '0');
  if (!Number.isFinite(cur) || cur <= 0) return 0;
  await env.LICENSES.put(`credit:${tid}`, String(cur - 1));
  return 1;
}

async function mintKey(env, tid, days, plan = 'custom') {
  const key = keygen();
  const now = Math.floor(Date.now() / 1000);
  const lic = { key, telegramId: String(tid), plan, days, issuedAt: now };
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
    if (!out.ok) {
      await env.LICENSES.put('lastError', `tg ${method}: ${out.error_code || ''} ${out.description || 'unknown'}`);
    } else if (method === 'sendMessage' && out.result?.message_id) {
      await env.LICENSES.put('lastSentId', String(out.result.message_id));
    }
  }
  return out;
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
  const files = await getReleaseFiles(env);
  const apk = files.filter((f) => f.name.toLowerCase().endsWith('.apk'));
  const exe = files.filter((f) => f.name.toLowerCase().endsWith('.exe'));
  const other = files.filter((f) => f.name.toLowerCase().endsWith('.zip'));
  const pick = [...apk, ...exe, ...other].slice(0, 8);
  if (!pick.length) {
    return { text: '⚠️ فعلاً فایلی برای ارسال پیدا نشد. لطفاً چند دقیقه بعد امتحان کنید یا از کانال رسمی دانلود نمایید.', reply_markup: { inline_keyboard: homeRow() } };
  }
  await env.LICENSES.put(`${DL_FILES_KEY}:${tid}`, JSON.stringify(pick), { expirationTtl: 3600 });
  const rows = pick.map((f, i) => [
    { text: `📄 ${dlLabel(f.name)} (${humanSize(f.size)})`, callback_data: `file:${i}` },
  ]);
  const tag = pick[0]?.tag || '';
  return {
    text: `📥 آخرین نسخه موجود: *${tag}*\nفایل مورد نظر برای دستگاه خود را انتخاب نمایید تا مستقیماً برایتان ارسال شود:`,
    parse_mode: 'Markdown',
    reply_markup: {
      inline_keyboard: withHome([...rows, [{ text: '🔄 بروزرسانی لیست فایل‌ها', callback_data: 'dlrefresh' }]]),
    },
  };
}

async function sendReleaseFile(env, tid, url, name) {
  const ghHeaders = {};
  if (env.GITHUB_TOKEN) ghHeaders.Authorization = `Bearer ${env.GITHUB_TOKEN}`;
  const res = await fetch(url, { headers: ghHeaders, redirect: 'follow' });
  if (!res.ok) throw new Error(`github ${res.status}`);
  const len = Number(res.headers ? res.headers.get('content-length') || 0 : 0);
  if (len && len > 48 * 1024 * 1024) {
    await tg(env.BOT_TOKEN, 'sendMessage', {
      chat_id: tid,
      text: `⚠️ فایل ${name} حجمش بیش از حد مجاز تلگرام است (${humanSize(len)}).\nلطفاً از کانال رسمی @Voidrau دانلود فرمایید.`,
    });
    return;
  }
  const buf = await res.arrayBuffer();
  if (buf.byteLength > 48 * 1024 * 1024) {
    await tg(env.BOT_TOKEN, 'sendMessage', {
      chat_id: tid,
      text: `⚠️ فایل ${name} حجمش بیش از حد مجاز تلگرام است (${humanSize(buf.byteLength)}).\nاز کانال رسمی دانلود نمایید.`,
    });
    return;
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
    const apk = files.find((f) => /universal/i.test(f.name) && f.name.toLowerCase().endsWith('.apk'))
      || files.find((f) => f.name.toLowerCase().endsWith('.apk'));
    const rows = [];
    if (apk) rows.push([{ text: `📥 دانلود نسخه اندروید (${apk.tag || ''} — ${humanSize(apk.size)})`, url: apk.url }]);
    rows.push([{ text: '📥 همهٔ فایل‌های دانلود', callback_data: 'dl' }]);
    return {
      text: '🤖 *راهنمای اندروید*\n\n' +
        '۱. از دکمهٔ دانلود زیر، فایل APK یونیورسال را بگیرید و نصب کنید (در صورت هشدار، «نصب از منبع ناشناس» را تایید کنید).\n' +
        '۲. برنامه را باز کنید و در تب «لایسنس»، کد خود را وارد نمایید.\n' +
        '۳. دکمهٔ اتصال را بزنید؛ در اولین اتصال، تایید VPN سیستم را قبول کنید.\n\n' +
        '💡 کد ندارید؟ از خانه، «🎁 تست رایگان» را بزنید یا لایسنس بخرید.',
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
        '💡 کد ندارید؟ از خانه، «🎁 تست رایگان» را بزنید یا لایسنس بخرید.',
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
    text: `🆘 *پشتیبانی VoidrauVPN*\n\nیکی از سوال‌های متداول را انتخاب کنید، یا مستقیم به پشتیبانی پیام بدهید:\n👤 ${sup}`,
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
  let sent = 0;
  for (const u of idx.slice(0, 300)) {
    if (await maybeSendExpiryReminder(env, u)) sent++;
  }
  return sent;
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
  const last = (await env.LICENSES.get(`checkin:${tid}:last`)) || '';
  const prevStreak = parseInt((await env.LICENSES.get(`checkin:${tid}:streak`)) || '0');
  const prevPoints = parseInt((await env.LICENSES.get(`checkin:${tid}:points`)) || '0');
  const r = checkinNext(last, prevStreak, prevPoints, today, yesterday);
  if (r.already) {
    return {
      text: `✅ چک‌این امروز را قبلاً انجام داده‌اید.\n\n🔥 استریک فعلی: *${r.streak} روز*\n⭐ امتیاز: *${r.points} از ۷* (هر ۷ امتیاز = ۱ روز اعتبار)\n\nفردا دوباره سر بزنید!`,
      parse_mode: 'Markdown',
      reply_markup: { inline_keyboard: homeRow() },
    };
  }
  await env.LICENSES.put(`checkin:${tid}:last`, today);
  await env.LICENSES.put(`checkin:${tid}:streak`, String(r.streak));
  await env.LICENSES.put(`checkin:${tid}:points`, String(r.points));
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
  let idx = [];
  try {
    idx = JSON.parse((await env.LICENSES.get('userIndex')) || '[]');
    if (!Array.isArray(idx)) idx = [];
  } catch (_) {}
  const rows = [];
  for (const u of idx.slice(0, 300)) {
    const joins = parseInt((await env.LICENSES.get(`refjoin:${u}`)) || '0');
    if (joins > 0) rows.push({ tid: u, joins });
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
  async fetch(request, env) {
    try {
      return await handleHttp(request, env);
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
  },
};

async function handleHttp(request, env) {
  const url = new URL(request.url);

  // ── HTTP API ──────────────────────────────────────────────────────────
  if (url.pathname === '/api/license' || url.pathname === '/api/status') {
    const key = (url.searchParams.get('key') || '').trim();
    if (!key) return json({ ok: false, error: 'missing-key' }, 400);
    const lic = await getLic(env, key);
    if (!lic || !lic.expiresAt || lic.plan === 'revoked') {
      return json({ ok: false, error: lic?.plan === 'revoked' ? 'revoked' : 'invalid' }, 200);
    }
    const now = Math.floor(Date.now() / 1000);
    if (lic.expiresAt <= now) {
      return json({ ok: false, error: 'expired', expiresAt: lic.expiresAt, serverTime: now }, 200);
    }
    return json({
      ok: true,
      key: lic.key,
      plan: lic.plan,
      issuedAt: lic.issuedAt,
      expiresAt: lic.expiresAt,
      serverTime: now,
      remainingSeconds: Math.max(0, lic.expiresAt - now),
      daysLeft: Math.max(0, Math.ceil((lic.expiresAt - now) / 86400)),
      isPaid: lic.plan === 'paid' || lic.plan === 'admin',
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
    const claim = crypto.randomUUID();
    await env.LICENSES.put(`trial:${tid}`, claim);
    const check = await env.LICENSES.get(`trial:${tid}`);
    if (check !== claim) return json({ ok: false, error: 'trial-used' }, 200);

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
    const TD = await trialDaysOf(env);
    const key = await mintKey(env, tid, TD, 'trial');
    await extend(env, key, TD);
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
    const whs = await env.LICENSES.get('set:whsecret');
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
      await handle(upd, env, steps);
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
    let whs = await env.LICENSES.get('set:whsecret');
    if (!whs) {
      whs = crypto.randomUUID().replace(/-/g, '');
      await env.LICENSES.put('set:whsecret', whs);
    }
    const set = await tg(
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
    const me0 = await tg(env.BOT_TOKEN || '', 'getMe', {}, env);
    if (me0 && me0.ok && me0.result?.username) {
      await env.LICENSES.put('set:botusername', me0.result.username);
    }
    // v2.0: register the bot menu commands (/start, /help, /id).
    await tg(env.BOT_TOKEN || '', 'setMyCommands', {
      commands: [
        { command: 'start', description: 'شروع و بازگشت به خانه' },
        { command: 'help', description: 'راهنمای استفاده' },
        { command: 'id', description: 'آیدی عددی من' },
      ],
    }, env);
    if (env.LICENSES) {
      await env.LICENSES.put(
        'lastSetup',
        JSON.stringify({ at: new Date().toISOString(), ok: set.ok, error: set.description || null })
      );
    }
    if (url.pathname === '/') {
      return new Response(
        `VoidrauVPN license bot — alive & operational.\nWebhook: ${
          set.ok ? 'SET ✓' : 'FAILED: ' + (set.description || '?')
        }`
      );
    }
    return json({ setup: set });
  }

  if (url.pathname === '/diag') {
    if (String(url.searchParams.get('a') || '') !== String(env.ADMIN_ID || '')) {
      return json({ ok: false, error: 'forbidden — /diag?a=<ADMIN_ID>' }, 403);
    }
    const me = await tg(env.BOT_TOKEN || '', 'getMe', {});
    const hook = await tg(env.BOT_TOKEN || '', 'getWebhookInfo', {});
    const lastError = await env.LICENSES.get('lastError');
    const lastUpdate = await env.LICENSES.get('lastUpdate');
    const lastSentId = await env.LICENSES.get('lastSentId');
    const lastSetup = await env.LICENSES.get('lastSetup');
    const lastSteps = await env.LICENSES.get('lastSteps');
    const users = await env.LICENSES.get('stat:users');
    const pending = await env.LICENSES.get('stat:pending');
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

async function handle(upd, env, steps) {
  const token = env.BOT_TOKEN;
  const msg = upd.message;
  const cb = upd.callback_query;

  if (cb) {
    steps.push('cb:' + cb.data);
    const tid = cb.from.id;
    let out = null;

    if (String(tid) !== String(env.ADMIN_ID) && !(await checkJoined(env, tid))) {
      out = joinPrompt(await getSetting(env, 'forceChannel', ''));
    } else if (cb.data === 'recheck') {
      if (!(await checkJoined(env, tid))) {
        out = joinPrompt(await getSetting(env, 'forceChannel', ''));
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
      if (!recRaw) {
        out = { text: `ℹ️ رسید کاربر ${target} قبلاً پردازش شده است.` };
      } else if (!Number.isFinite(days) || days < 1 || days > 3650) {
        out = { text: '❌ تعداد روز نامعتبر در دکمهٔ تایید.' };
      } else {
        await env.LICENSES.delete(`receipt:${target}`);
        const curPending = Math.max(0, parseInt((await env.LICENSES.get('stat:pending')) || '1') - 1);
        await env.LICENSES.put('stat:pending', String(curPending));
        await setReceiptStatus(env, target, 'approved', null);

        let k = await userKey(env, target);
        let l = k ? await getLic(env, k) : null;
        if (l && l.expiresAt) {
          await extend(env, k, days);
          await upgradePlan(env, k, 'paid');
        } else {
          k = await mintKey(env, target, days, 'paid');
          await extend(env, k, days);
        }
        while ((await takeCredit(env, target)) === 1) {
          await extend(env, k, 1);
        }
        const updatedLic = await getLic(env, k);
        await tg(
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
          await tg(
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
      const curPending = Math.max(0, parseInt((await env.LICENSES.get('stat:pending')) || '1') - 1);
      await env.LICENSES.put('stat:pending', String(curPending));
      await setReceiptStatus(env, ru, 'rejected', null);

      await tg(
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
        await tg(
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
        await tg(token, 'answerCallbackQuery', { callback_query_id: cb.id, text: '⏳ در حال ارسال فایل...' });
        cb._answered = true;
        try {
          await sendReleaseFile(env, tid, f.url, f.name);
          await tg(token, 'sendMessage', {
            chat_id: tid,
            text: '✅ فایل برنامه با موفقیت ارسال شد 👆\n🤖 اندروید: فایل را باز کرده و نصب کنید.\n🪟 ویندوز: فایل نصبی را اجرا فرمایید.',
          });
        } catch (e) {
          await tg(token, 'sendMessage', {
            chat_id: tid,
            text: `❌ ارسال فایل ناموفق بود: ${e.message}\nلطفاً دوباره امتحان کنید.`,
            reply_markup: {
              inline_keyboard: withHome([
                [{ text: '🔄 تلاش دوباره', callback_data: `file:${idx}` }],
                [{ text: '📜 لیست فایل‌ها', callback_data: 'dl' }],
              ]),
            },
          });
        }
        out = null;
      }
    } else if (cb.data === 'help') {
      out = await doHelp();
    } else if (cb.data === 'support') {
      out = await doSupport(env);
    } else if (cb.data === 'status') {
      out = await doStatus(env, tid);
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
          await env.LICENSES.put(`credit:${tid}`, String(credit - g.days));
          let fk = await userKey(env, g.friend);
          let fl = fk ? await getLic(env, fk) : null;
          if (fl && fl.expiresAt) {
            await extend(env, fk, g.days);
          } else {
            fk = await mintKey(env, g.friend, g.days, 'paid');
            await extend(env, fk, g.days);
          }
          const flic = await getLic(env, fk);
          const gl = parseInt((await env.LICENSES.get(`giftlog:${tid}`)) || '0');
          await env.LICENSES.put(`giftlog:${tid}`, String(gl + 1));
          await env.LICENSES.delete(`gift:${tid}`);
          const senderName = (await env.LICENSES.get(`name:${tid}`)) || 'یک دوست';
          await tg(env.BOT_TOKEN, 'sendMessage', {
            chat_id: g.friend,
            text: `🎁 *هدیه دریافت کردید!*\n\n${senderName} تعداد *${g.days} روز* لایسنس به شما هدیه داد.\n\n🔑 کد لایسنس شما:\n\`${fk}\`\n\n📅 تاریخ انقضا: *${formatJalali(flic?.expiresAt)}*\n\nکد را در برنامه (تب لایسنس) وارد کنید.`,
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
          let n = 0;
          let fail = 0;
          const targetUsers = list.slice(0, 300);
          const batchSize = 15;
          for (let i = 0; i < targetUsers.length; i += batchSize) {
            const batch = targetUsers.slice(i, i + batchSize);
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
          out = { text: `📣 ارسال به ${n} کاربر انجام شد${fail ? ` (${fail} پیام ناموفق)` : ''}.` };
        }
      } else if (a === 'stats') {
        out = await buildStatsMessage(env);
      }
    } else {
      out = { text: 'این دکمه منقضی شده است — لطفاً با /start از نو آغاز کنید.' };
    }

    if (out) await tg(token, 'sendMessage', { chat_id: tid, ...out }, env, steps);
    if (!cb._answered) await tg(token, 'answerCallbackQuery', { callback_query_id: cb.id }, env, steps);
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
      await tg(env.BOT_TOKEN, 'sendMessage', { chat_id: tid, text: '❌ عملیات لغو شد.' }, env, steps);
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
      await tg(
        env.BOT_TOKEN,
        'sendMessage',
        {
          chat_id: tid,
          text: '📋 پیش‌نمایش پیام همگانی آماده شد. آیا مایلید به همهٔ کاربران ارسال شود؟',
          reply_markup: {
            inline_keyboard: [
              [{ text: '✅ بله، ارسال کن', callback_data: 'ad:bcsend' }],
              [{ text: '❌ لغو', callback_data: 'ad:cancelmode' }],
            ],
          },
        },
        env,
        steps
      );
      return;
    }
    if (mode && !text.startsWith('/')) {
      await env.LICENSES.delete(`admMode:${tid}`);
      if (mediaAdmin) {
        await env.LICENSES.put(`admMode:${tid}`, mode);
        await tg(env.BOT_TOKEN, 'sendMessage', { chat_id: tid, text: 'برای این بخش باید متن ارسال کنید.' }, env, steps);
        return;
      }
      if (mode === 'plans') {
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
          rows.push({ id: parts[0].replace(/\s+/g, ''), label: parts[1], days: parseInt(parts[2]) });
        }
        const ids = rows.map((r) => r.id);
        if (new Set(ids).size !== ids.length) {
          await tg(env.BOT_TOKEN, 'sendMessage', { chat_id: tid, text: '❌ شناسهٔ تکراری در پلن‌ها وجود دارد.' }, env, steps);
          return;
        }
        if (bad.length) {
          await env.LICENSES.put(`admMode:${tid}`, mode);
          await tg(
            env.BOT_TOKEN,
            'sendMessage',
            {
              chat_id: tid,
              text: `❌ خطاهای یافت‌شده در پلن‌ها:\n${bad.join('\n')}\n\nلطفاً لیست کامل را اصلاح و مجدداً ارسال کنید.`,
              reply_markup: { inline_keyboard: [[{ text: '❌ لغو', callback_data: 'ad:cancelmode' }]] },
            },
            env,
            steps
          );
          return;
        }
        if (!rows.length) {
          await env.LICENSES.put(`admMode:${tid}`, mode);
          await tg(env.BOT_TOKEN, 'sendMessage', { chat_id: tid, text: '❌ هیچ پلن معتبری دریافت نشد.' }, env, steps);
          return;
        }
        await env.LICENSES.put('setting:plans', JSON.stringify(rows));
        await tg(
          env.BOT_TOKEN,
          'sendMessage',
          {
            chat_id: tid,
            text: `✅ تعداد ${rows.length} پلن با موفقیت ثبت شد:\n${rows
              .map((r) => `• ${r.label} (${r.days} روز)`)
              .join('\n')}`,
          },
          env,
          steps
        );
      } else {
        let val = text.trim();
        if (mode === 'forceChannel') {
          if (!val || val === 'خالی' || val === '-') {
            await setSetting(env, mode, '');
            await tg(env.BOT_TOKEN, 'sendMessage', { chat_id: tid, text: '✅ جوین اجباری غیرفعال شد.' }, env, steps);
            return;
          }
          const mch = val.match(/(?:t\.me\/|@)([A-Za-z0-9_]+)/);
          if (mch) val = '@' + mch[1];
          else if (/^-100\d+$/.test(val)) {
            // numeric id ok
          } else {
            await env.LICENSES.put(`admMode:${tid}`, mode);
            await tg(
              env.BOT_TOKEN,
              'sendMessage',
              { chat_id: tid, text: '❌ آیدی کانال نامعتبر است (مثال: @mychannel یا -100123456).' },
              env,
              steps
            );
            return;
          }
        }
        if (mode === 'trialDays') {
          if (!/^\d+$/.test(val) || parseInt(val) < 1 || parseInt(val) > 365) {
            await env.LICENSES.put(`admMode:${tid}`, mode);
            await tg(
              env.BOT_TOKEN,
              'sendMessage',
              { chat_id: tid, text: '❌ عدد نامعتبر است (۱ تا ۳۶۵).' },
              env,
              steps
            );
            return;
          }
          await env.LICENSES.put('setting:trialDays', val);
          await tg(env.BOT_TOKEN, 'sendMessage', { chat_id: tid, text: `✅ مدت تست رایگان = ${val} روز تنظیم شد.` }, env, steps);
          return;
        }
        await setSetting(env, mode, val);
        await tg(env.BOT_TOKEN, 'sendMessage', { chat_id: tid, text: `✅ تنظیم شد: ${val}` }, env, steps);
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
        await tg(env.BOT_TOKEN, 'sendMessage', {
          chat_id: target,
          text: `💬 *پاسخ پشتیبانی:*\n\n${text}`,
          parse_mode: 'Markdown',
          reply_markup: { inline_keyboard: [[{ text: '🏠 خانه', callback_data: 'home' }]] },
        }, env, steps);
        await tg(env.BOT_TOKEN, 'sendMessage', { chat_id: tid, text: `✅ پاسخ شما به کاربر \`${target}\` ارسال شد.`, parse_mode: 'Markdown' }, env, steps);
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
      await tg(env.BOT_TOKEN, 'sendMessage', {
        chat_id: env.ADMIN_ID,
        text: `🆘 *پیام پشتیبانی جدید*\n\n👤 از: ${senderName} (\`${tid}\`)\n\n${text}`,
        parse_mode: 'Markdown',
        reply_markup: { inline_keyboard: [[{ text: '✍️ پاسخ به این کاربر', callback_data: `suprep:${tid}` }]] },
      }, env, steps);
      await tg(env.BOT_TOKEN, 'sendMessage', { chat_id: tid, text: '✅ پیام شما به پشتیبانی ارسال شد. پاسخ در همین‌جا برایتان می‌آید.', reply_markup: { inline_keyboard: homeRow() } }, env, steps);
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
          await tg(env.BOT_TOKEN, 'sendMessage', { chat_id: tid, text: '❌ آیدی عددی نامعتبر است. فقط عدد بفرستید (مثال: 123456789).', reply_markup: { inline_keyboard: homeRow() } }, env, steps);
          return;
        }
        if (err === 'self') {
          await tg(env.BOT_TOKEN, 'sendMessage', { chat_id: tid, text: '❌ نمی‌توانید به خودتان هدیه بدهید. آیدی عددی دوست خود را بفرستید.', reply_markup: { inline_keyboard: homeRow() } }, env, steps);
          return;
        }
        await env.LICENSES.put(`gift:${tid}`, JSON.stringify({ stage: 'awaitDays', friend: text.trim() }));
        const credit = parseInt((await env.LICENSES.get(`credit:${tid}`)) || '0');
        await tg(env.BOT_TOKEN, 'sendMessage', { chat_id: tid, text: `✅ گیرنده ثبت شد: \`${text.trim()}\`\n\nچند روز هدیه می‌دهید؟ (اعتبار شما: *${credit} روز* — عدد بفرستید)`, parse_mode: 'Markdown', reply_markup: { inline_keyboard: homeRow() } }, env, steps);
        return;
      }
      if (g.stage === 'awaitDays') {
        const credit = parseInt((await env.LICENSES.get(`credit:${tid}`)) || '0');
        const days = parseInt(text.trim(), 10);
        const err = giftValidate(tid, g.friend, text.trim(), credit);
        if (err === 'bad-days' || err === 'over-credit') {
          await tg(env.BOT_TOKEN, 'sendMessage', { chat_id: tid, text: err === 'over-credit' ? `❌ مقدار هدیه بیشتر از اعتبار شماست (${credit} روز). عدد کوچک‌تری بفرستید.` : '❌ عدد نامعتبر است. تعداد روز را فقط با عدد بفرستید (مثال: 7).', reply_markup: { inline_keyboard: homeRow() } }, env, steps);
          return;
        }
        await env.LICENSES.put(`gift:${tid}`, JSON.stringify({ stage: 'confirm', friend: g.friend, days }));
        await tg(env.BOT_TOKEN, 'sendMessage', {
          chat_id: tid,
          text: `🎁 *تایید هدیه*\n\n${days} روز لایسنس به کاربر \`${g.friend}\` هدیه داده می‌شود.\n💳 اعتبار باقی‌مانده پس از هدیه: *${credit - days} روز*\n\nمطمئن هستید؟`,
          parse_mode: 'Markdown',
          reply_markup: { inline_keyboard: [[{ text: '✅ بله، ارسال کن', callback_data: 'gift:yes' }, { text: '❌ لغو', callback_data: 'gift:no' }]] },
        }, env, steps);
        return;
      }
    }
  }

  // ── Receipt intake ──────────────────────────────────────────────────
  const media2 = msg.photo ? 'photo' : msg.document ? 'doc' : null;
  if (media2) {
    const fid = media2 === 'photo' ? msg.photo[msg.photo.length - 1].file_id : msg.document.file_id;
    const selectedPlanId = await getSetting(env, `lastPlan:${tid}`, 'm1');
    const plans = await plansOf(env);
    const chosen = plans.find((p) => p.id === selectedPlanId) || plans[0];

    await env.LICENSES.put(
      `receipt:${tid}`,
      JSON.stringify({ fileId: fid, kind: media2, planId: selectedPlanId, at: Date.now() })
    );
    await setReceiptStatus(env, tid, 'pending', selectedPlanId);

    const curP = parseInt((await env.LICENSES.get('stat:pending')) || '0');
    await env.LICENSES.put('stat:pending', String(curP + 1));

    const cap = `🧾 رسید جدید از کاربر \`${tid}\`\n📦 پلن انتخابی: *${chosen.label}* (${chosen.days} روز)\n\nپلن مورد نظر را برای تایید انتخاب کنید:`;
    const approveRows = plans.map((p) => [
      { text: (p.id === chosen.id ? '⭐️ ' : '') + `تایید ${p.label}`, callback_data: `okr:${tid}:${p.days}` },
    ]);
    approveRows.push([{ text: '❌ رد رسید', callback_data: `rej:${tid}` }]);

    const fwd =
      media2 === 'photo'
        ? await tg(
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
        : await tg(
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
      await tg(
        env.BOT_TOKEN,
        'sendMessage',
        {
          chat_id: tid,
          text: '⚠️ ارسال رسید به ادمین با خطا مواجه شد. لطفاً دوباره تلاش نمایید یا با پشتیبانی تماس بگیرید.',
        },
        env,
        steps
      );
      return;
    }
    await tg(
      env.BOT_TOKEN,
      'sendMessage',
      {
        chat_id: tid,
        text: '✅ رسید پرداخت شما دریافت شد و به مدیریت ارسال گردید.\nبه محض تایید، کد لایسنس اختصاصی همین‌جا برایتان ارسال خواهد شد.',
      },
      env,
      steps
    );
    return;
  }

  // ── Admin Commands ──────────────────────────────────────────────────
  if (String(tid) === String(env.ADMIN_ID)) {
    if (text === '/panel') {
      await tg(env.BOT_TOKEN, 'sendMessage', { chat_id: tid, ...(await adminPanel(env, tid)) }, env, steps);
      return;
    }
    if (text === '/stats') {
      await tg(env.BOT_TOKEN, 'sendMessage', { chat_id: tid, ...(await buildStatsMessage(env)) }, env, steps);
      return;
    }
    if (text.startsWith('/find')) {
      const q = (text.split(/\s+/)[1] || '').trim();
      if (!q) {
        await tg(token, 'sendMessage', { chat_id: tid, text: 'فرمت: /find <آیدی عددی یا کد لایسنس>' }, env);
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
        await tg(token, 'sendMessage', { chat_id: tid, text: `❌ موردی برای «${q}» یافت نشد.` }, env);
        return;
      }
      const now = Math.floor(Date.now() / 1000);
      const active = lic && lic.expiresAt && lic.expiresAt > now && lic.plan !== 'revoked';
      const joins = targetTid ? parseInt((await env.LICENSES.get(`refjoin:${targetTid}`)) || '0') : 0;
      const credit = targetTid ? parseInt((await env.LICENSES.get(`credit:${targetTid}`)) || '0') : 0;
      const info =
        `🔍 *اطلاعات کاربر و لایسنس*\n\n` +
        `👤 آیدی عددی: \`${targetTid || 'نامشخص'}\`\n` +
        `🔑 کد لایسنس: \`${key || 'ندارد'}\`\n` +
        `📦 پلن: *${lic?.plan || 'نامشخص'}*\n` +
        `🚦 وضعیت: *${active ? 'فعال ✅' : 'غیرفعال / منقضی ❌'}*\n` +
        `⏳ باقی‌مانده: *${lic?.expiresAt ? formatDuration(lic.expiresAt - now) : '—'}*\n` +
        `📅 تاریخ انقضا: *${lic?.expiresAt ? formatJalali(lic.expiresAt) : '—'}*\n` +
        `👥 تعداد دعوت‌ها: ${joins} نفر\n` +
        `🎁 اعتبار هدیه ذخیره: ${credit} روز`;
      await tg(token, 'sendMessage', { chat_id: tid, text: info, parse_mode: 'Markdown' }, env);
      return;
    }
    if (text.startsWith('/revoke')) {
      const q = (text.split(/\s+/)[1] || '').trim();
      if (!q) {
        await tg(token, 'sendMessage', { chat_id: tid, text: 'فرمت: /revoke <آیدی عددی یا کد لایسنس>' }, env);
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
        await tg(token, 'sendMessage', { chat_id: tid, text: `❌ لایسنسی برای «${q}» یافت نشد.` }, env);
        return;
      }
      lic.expiresAt = 0;
      lic.plan = 'revoked';
      await putLic(env, key, lic);
      if (targetTid) {
        await tg(token, 'sendMessage', { chat_id: targetTid, text: '⚠️ لایسنس شما توسط مدیریت باطل شد.' }, env);
      }
      await tg(
        token,
        'sendMessage',
        { chat_id: tid, text: `🚫 لایسنس \`${key}\` باطل گردید.`, parse_mode: 'Markdown' },
        env
      );
      return;
    }
    if (text.startsWith('/adddays')) {
      const [, targetS, daysS] = text.split(/\s+/);
      const days = parseInt(daysS || '0');
      if (!targetS || !Number.isFinite(days) || days < 1) {
        await tg(token, 'sendMessage', { chat_id: tid, text: 'فرمت: /adddays <آیدی یا کد> <تعداد روز>' }, env);
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
        await tg(token, 'sendMessage', { chat_id: tid, text: `❌ لایسنسی برای «${targetS}» یافت نشد.` }, env);
        return;
      }
      await extend(env, key, days);
      const updated = await getLic(env, key);
      await tg(
        token,
        'sendMessage',
        {
          chat_id: tid,
          text: `✅ تعداد ${days} روز به لایسنس \`${key}\` اضافه شد.\n📅 تاریخ انقضای جدید: *${formatJalali(updated?.expiresAt)}*`,
          parse_mode: 'Markdown',
        },
        env
      );
      if (targetTid) {
        await tg(
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
        await tg(token, 'sendMessage', { chat_id: tid, text: 'فرمت: /gen <روز> [آیدی عددی]' }, env);
        return;
      }
      const key = await mintKey(env, target, days, 'paid');
      await extend(env, key, days);
      const lic = await getLic(env, key);
      await tg(
        token,
        'sendMessage',
        {
          chat_id: tid,
          text: `🔑 لایسنس با موفقیت ساخته شد:\n\`${key}\`\n\nبرای کاربر: \`${target}\`\nمدت: ${days} روز\nانقضا: ${formatJalali(lic?.expiresAt)}`,
          parse_mode: 'Markdown',
        },
        env
      );
      return;
    }
    if (text.startsWith('/ok')) {
      const [, tidS, daysS] = text.split(/\s+/);
      const target = parseInt(tidS);
      const days = parseInt(daysS || '30');
      if (!/^\d{3,}$/.test(tidS || '') || !Number.isFinite(days) || days < 1 || days > 3650) {
        await tg(token, 'sendMessage', { chat_id: tid, text: 'فرمت: /ok <آیدی عددی> <روز>' }, env);
        return;
      }
      let key = await userKey(env, target);
      let lic = key ? await getLic(env, key) : null;
      if (lic && lic.expiresAt) {
        await extend(env, key, days);
        await upgradePlan(env, key, 'paid');
      } else {
        key = await mintKey(env, target, days, 'paid');
        await extend(env, key, days);
      }
      while ((await takeCredit(env, target)) === 1) {
        await extend(env, key, 1);
      }
      await env.LICENSES.delete(`receipt:${target}`);
      await setReceiptStatus(env, target, 'approved', null);
      const curP = Math.max(0, parseInt((await env.LICENSES.get('stat:pending')) || '1') - 1);
      await env.LICENSES.put('stat:pending', String(curP));

      const updated = await getLic(env, key);
      await tg(
        token,
        'sendMessage',
        {
          chat_id: tid,
          text: `✅ پرداخت تایید شد — ${days} روز برای \`${target}\`\n\`${key}\``,
          parse_mode: 'Markdown',
        },
        env
      );
      await tg(
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
        await tg(token, 'sendMessage', { chat_id: tid, text: 'فرمت: /fix <آیدی کاربر>' }, env);
        return;
      }
      const k = await userKey(env, target);
      if (!k) {
        await tg(token, 'sendMessage', { chat_id: tid, text: `کاربر ${target} لایسنسی ندارد.` }, env);
        return;
      }
      await upgradePlan(env, k, 'paid');
      const l = await getLic(env, k);
      await tg(
        token,
        'sendMessage',
        {
          chat_id: tid,
          text: `🔧 پلن کاربر ${target} به پولی تغییر یافت.\n\`${k}\`\nانقضا: ${formatJalali(l?.expiresAt)}`,
          parse_mode: 'Markdown',
        },
        env
      );
      return;
    }
  }

  // ── General Commands ────────────────────────────────────────────────
  if (text.startsWith('/start')) {
    steps.push('start-branch');
    const payload = text.split(/\s+/)[1] || '';
    if (String(tid) !== String(env.ADMIN_ID) && !(await checkJoined(env, tid))) {
      steps.push('join-gate');
      // Preserve supported deep links through the channel-join gate. Otherwise
      // Telegram's one-shot /start payload is lost when users tap "recheck".
      if (/^(trial|buy|ref|ref_\d{3,})$/.test(payload) && payload !== `ref_${tid}`) {
        await env.LICENSES.put(`startpending:${tid}`, payload, { expirationTtl: 86400 });
      }
      await tg(env.BOT_TOKEN, 'sendMessage', { chat_id: tid, ...joinPrompt(await getSetting(env, 'forceChannel', '')) }, env, steps);
      return;
    }

    const response = await startPayloadAction(env, msg.from, payload, steps);
    await tg(token, 'sendMessage', { chat_id: tid, ...response }, env, steps);
    return;
  }

  if (text === '/id') {
    await tg(token, 'sendMessage', { chat_id: tid, text: `آیدی عددی شما:\n\`${tid}\``, parse_mode: 'Markdown' }, env);
    return;
  }

  if (text === '/help' || text === '/commands') {
    if (String(tid) === String(env.ADMIN_ID)) {
      const adminHelp =
        `🛠 *دستورات مدیریت ربات:*\n\n` +
        `• \`/panel\` — باز کردن پنل تنظیمات ربات\n` +
        `• \`/stats\` — گزارش آمار سیستم\n` +
        `• \`/find <آیدی یا کد>\` — جستجو و جزئیات کاربر یا لایسنس\n` +
        `• \`/gen <روز> [آیدی]\` — تولید لایسنس مستقیم\n` +
        `• \`/ok <آیدی> <روز>\` — تایید پرداخت کاربر\n` +
        `• \`/adddays <آیدی یا کد> <روز>\` — افزودن روز به لایسنس موجود\n` +
        `• \`/revoke <آیدی یا کد>\` — لغو و باطل کردن لایسنس\n` +
        `• \`/fix <آیدی>\` — ارتقای پلن کاربر به پولی\n` +
        `• \`/id\` — نمایش آیدی عددی`;
      await tg(token, 'sendMessage', { chat_id: tid, text: adminHelp, parse_mode: 'Markdown' }, env);
      return;
    }
    await tg(token, 'sendMessage', { chat_id: tid, ...(await doHelp()) }, env);
    return;
  }

  await tg(
    token,
    'sendMessage',
    {
      chat_id: tid,
      text: '🤔 متوجه دستور نشدم. لطفاً از دکمه‌های منو یا دستور /start استفاده فرمایید.',
    },
    env,
    steps
  );
}

// ── Commerce & Admin Panel Helpers ────────────────────────────────────
async function getSetting(env, k, dflt) {
  return (await env.LICENSES.get(`set:${k}`)) ?? dflt;
}

async function setSetting(env, k, v) {
  await env.LICENSES.put(`set:${k}`, v);
}

async function checkJoined(env, tid) {
  const ch = (await getSetting(env, 'forceChannel', '')).trim();
  if (!ch) return true;
  const r = await tg(env.BOT_TOKEN, 'getChatMember', { chat_id: ch, user_id: tid }, env);
  if (!r || !r.ok) {
    try {
      await env.LICENSES.put('lastError', `force-join: getChatMember ${ch}: ${r?.description || 'unknown'}`);
    } catch (_) {}
    return true;
  }
  const m = r.result || {};
  const st = m.status || 'left';
  if (st === 'restricted') return m.is_member === true;
  return ['member', 'administrator', 'creator'].includes(st);
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
    text: `${buyText}\n\n💳 شماره کارت جهت واریز:\n\`${card}\`\n\nلطفاً پلن مورد نظر را انتخاب و پس از واریز، عکس رسید را در همین چت ارسال نمایید:`,
    parse_mode: 'Markdown',
    reply_markup: {
      inline_keyboard: withHome((await plansOf(env)).map((p) => [{ text: p.label, callback_data: `plan:${p.id}` }])),
    },
  };
}

async function askMode(env, tid, prompt, mode) {
  return { text: prompt, reply_markup: { inline_keyboard: [[{ text: '❌ لغو', callback_data: 'ad:cancelmode' }]] } };
}

async function adminLiveStats(env) {
  const idx = JSON.parse((await env.LICENSES.get('userIndex')) || '[]');
  const now = Math.floor(Date.now() / 1000);
  let active = 0;
  let trial = 0;
  let paid = 0;
  let expiring = 0;
  for (const u of idx.slice(0, 300)) {
    const k = await env.LICENSES.get(`user:${u}`);
    if (!k) continue;
    const l = await getLic(env, k);
    if (l && l.expiresAt && l.expiresAt > now && l.plan !== 'revoked') {
      active++;
      if (l.plan === 'trial') trial++;
      else paid++;
      if (Math.ceil((l.expiresAt - now) / 86400) <= 3) expiring++;
    }
  }
  const checkinsToday = parseInt((await env.LICENSES.get(`stat:checkins:${tehranDate()}`)) || '0');
  return { users: idx.length, active, trial, paid, expiring, checkinsToday };
}

async function expiringList(env) {
  const idx = JSON.parse((await env.LICENSES.get('userIndex')) || '[]');
  const now = Math.floor(Date.now() / 1000);
  const rows = [];
  for (const u of idx.slice(0, 300)) {
    const k = await env.LICENSES.get(`user:${u}`);
    if (!k) continue;
    const l = await getLic(env, k);
    if (!l || !l.expiresAt || l.plan === 'revoked') continue;
    const daysLeft = Math.ceil((l.expiresAt - now) / 86400);
    if (daysLeft >= 0 && daysLeft <= 3) rows.push({ u, daysLeft, plan: l.plan, exp: l.expiresAt });
  }
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
  const pending = parseInt((await env.LICENSES.get('stat:pending')) || '0');
  const idx = JSON.parse((await env.LICENSES.get('userIndex')) || '[]');
  const now = Math.floor(Date.now() / 1000);
  let active = 0;
  let trial = 0;
  let paid = 0;

  for (const u of idx.slice(-60)) {
    const k = await env.LICENSES.get(`user:${u}`);
    if (!k) continue;
    const l = await getLic(env, k);
    if (l && l.expiresAt && l.expiresAt > now && l.plan !== 'revoked') {
      active++;
      if (l.plan === 'trial') trial++;
      else paid++;
    }
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

async function adminPanel(env, tid) {
  const card = await getSetting(env, 'cardNumber', '—');
  const buy = await getSetting(env, 'buyText', 'خرید لایسنس');
  const ch = await getSetting(env, 'forceChannel', '—');
  const sup = await getSetting(env, 'supportId', '@Voidrau');
  const trialDays = String(await trialDaysOf(env));
  const users = parseInt((await env.LICENSES.get('stat:users')) || '0');
  const pending = parseInt((await env.LICENSES.get('stat:pending')) || '0');
  const live = await adminLiveStats(env);

  return {
    text:
      `🛠 *پنل مدیریت ربات VoidrauVPN*\n\n` +
      `👥 کاربران: *${users}*\n` +
      `✅ فعال: *${live.active}* (تستی ${live.trial}، پولی ${live.paid})\n` +
      `⏰ در آستانهٔ انقضا (≤۳ روز): *${live.expiring}*\n` +
      `✅ چک‌این امروز: *${live.checkinsToday}*\n` +
      `🧾 رسید در انتظار: *${pending}*\n` +
      `💳 کارت: \`${card}\`\n` +
      `🛒 متن خرید: ${buy}\n` +
      `📢 کانال اجباری: ${ch}\n` +
      `🎁 روز تست: ${trialDays} روز\n` +
      `🆘 پشتیبانی: ${sup}`,
    parse_mode: 'Markdown',
    reply_markup: {
      inline_keyboard: withHome([
        [{ text: '✏️ متن خرید', callback_data: 'ad:editbuy' }, { text: '💳 شماره کارت', callback_data: 'ad:editcard' }],
        [{ text: '💰 قیمت‌ها', callback_data: 'ad:editplans' }, { text: '📢 کانال اجباری', callback_data: 'ad:editch' }],
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
  const rows = [];
  let n = 0;
  for (const u of idx) {
    const raw = await env.LICENSES.get(`receipt:${u}`);
    if (!raw) continue;
    const planId = await getSetting(env, `lastPlan:${u}`, 'm1');
    const p = (await plansOf(env)).find((x) => x.id === planId) || (await plansOf(env))[0];
    rows.push([
      { text: `🧾 کاربر ${u} — ${p.label}`, callback_data: `okr:${u}:${p.days}` },
      { text: '❌', callback_data: `rej:${u}` },
    ]);
    n++;
  }
  return {
    text: n ? `🧾 تعداد ${n} رسید در انتظار تایید وجود دارد:` : '🧾 هیچ رسیدی در انتظار تایید نیست.',
    reply_markup: rows.length ? { inline_keyboard: withHome(rows) } : { inline_keyboard: homeRow() },
  };
}

async function recentUsers(env) {
  const idx = JSON.parse((await env.LICENSES.get('userIndex')) || '[]');
  const last = idx.slice(-15).reverse();
  let t = `👥 *آخرین کاربران (${idx.length} کل):*\n\n`;
  const now = Math.floor(Date.now() / 1000);
  for (const u of last) {
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
    t += `• \`${u}\` — ${s}\n`;
  }
  return { text: t, parse_mode: 'Markdown', reply_markup: { inline_keyboard: homeRow() } };
}

async function exportBackup(env, tid) {
  const idx = JSON.parse((await env.LICENSES.get('userIndex')) || '[]');
  const out = [];
  for (const u of idx.slice(0, 250)) {
    const k = await env.LICENSES.get(`user:${u}`);
    const l = k ? await getLic(env, k) : null;
    out.push({ id: u, key: k || null, plan: l?.plan || null, expiresAt: l?.expiresAt || null });
  }
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
  const TD = await trialDaysOf(env);
  const key = await mintKey(env, tid, TD, 'trial');
  await extend(env, key, TD);
  await env.LICENSES.put(`trial:${tid}`, '1');
  while ((await takeCredit(env, tid)) === 1) {
    await extend(env, key, 1);
  }
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
  const card = await getSetting(env, 'cardNumber', 'تنظیم نشده');
  return {
    text:
      `🛒 *پلن انتخابی:* ${p.label}\n\n` +
      `💳 لطفاً مبلغ را به شماره کارت زیر واریز کنید:\n\`${card}\`\n\n` +
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
  if (await env.LICENSES.get(`refseen:${invitee}`)) return false;

  await env.LICENSES.put(`refseen:${invitee}`, '1');
  const previous = parseInt((await env.LICENSES.get(`refjoin:${referrer}`)) || '0', 10);
  const joins = (Number.isFinite(previous) ? previous : 0) + 1;
  await env.LICENSES.put(`refjoin:${referrer}`, String(joins));
  if (joins % REFERRAL_REWARD_JOINS === 0) {
    await addCredit(env, referrer, REFERRAL_REWARD_DAYS);
    await tg(
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
  return {
    text:
      `👥 *سیستم دعوت دوستان (کسب اشتراک رایگان)*\n\n` +
      `با ارسال لینک اختصاصی به دوستانتان، به ازای هر *${REFERRAL_REWARD_JOINS} نفر*، *${REFERRAL_REWARD_DAYS} روز لایسنس رایگان* دریافت می‌کنید!\n\n` +
      `🔗 *لینک دعوت شما:*\nhttps://t.me/${botUser}?start=ref_${tid}\n\n` +
      `📊 *گزارش دعوت‌ها:*\n` +
      `• تعداد افراد عضو شده: *${joins} نفر*\n` +
      `• ${needed === REFERRAL_REWARD_JOINS ? 'دعوت بعدی شروع دور جدید پاداش' : `${needed} نفر مانده تا پاداش بعدی`}\n` +
      `• اعتبار ذخیره هدیه: *${credit} روز*`,
    parse_mode: 'Markdown',
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

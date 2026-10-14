// VoidrauVPN License Bot + API — Cloudflare Worker (single file).
//
// Deploy: wrangler deploy (or paste in the dashboard). Needs a KV namespace
// bound as LICENSES and the secret BOT_TOKEN (from @BotFather).
//
//   wrangler kv namespace create LICENSES
//   wrangler secret put BOT_TOKEN
//   wrangler secret put ADMIN_ID   (your numeric telegram id)
//
// Features:
//   • /start            → main menu (Persian)
//   • تست رایگان        → 24h trial key (once per telegram id)
//   • خرید لایسنس       → plans, payment placeholder → admin approves
//   • دعوت دوستان       → personal referral link; 1 week credit per 3 joins
//   • کد لایسنس من      → shows key + expiry
//   • دانلود نسخه جدید  → latest GitHub release files sent in-chat
//   • /panel            → admin panel (prices, card, channel, broadcast…)
//   • /gen <days> <tid> → admin: mint a key
//   • /ok <tid> <days>  → admin: approve a pending purchase
//
// HTTP API (used by the app):
//   GET  /api/license?key=...
//   GET  /api/status?key=...
//   POST /api/trial {telegramId}

const DEFAULT_PLANS = [
  { id: 'm1', label: '۱ ماهه — ۱۰۰ هزار تومان', days: 30 },
  { id: 'm3', label: '۳ ماهه — ۲۵۰ هزار تومان', days: 90 },
  { id: 'm12', label: 'یک‌ساله — ۸۰۰ هزار تومان', days: 365 },
];
const TRIAL_DAYS = 1;

const plansOf = async (env) => {
  try { const p = JSON.parse((await env.LICENSES.get('setting:plans')) || 'null'); if (Array.isArray(p) && p.length) return p; } catch (_) {}
  return DEFAULT_PLANS;
};
const trialDaysOf = async (env) => {
  const d = parseInt((await env.LICENSES.get('setting:trialDays')) || '');
  return d && d > 0 ? d : TRIAL_DAYS;
};
const REFERRAL_REWARD_JOINS = 3;   // every N joins
const REFERRAL_REWARD_DAYS = 7;    // → N days credit


function keygen() {
  const seg = () => crypto.randomUUID().replace(/-/g, '').slice(0, 4).toUpperCase();
  return `VDRV-${seg()}-${seg()}-${seg()}`;
}

function json(data, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { 'content-type': 'application/json' },
  });
}

async function getLic(env, key) {
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
  const out = await r.json();
  if (steps) steps.push('tg:' + method + ':' + (out.ok ? 'ok#' + out.result?.message_id : out.description));
  if (env && env.LICENSES) {
    if (!out.ok) {
      await env.LICENSES.put('lastError', `tg ${method}: ${out.error_code || ''} ${out.description || 'unknown'}`);
    } else if (method === 'sendMessage' && out.result?.message_id) {
      await env.LICENSES.put('lastSentId', String(out.result.message_id));
    }
  }
  return out;
}

function mainMenu(from, lic) {
  const name = from && from.first_name ? from.first_name : '';
  const active = lic && lic.expiresAt && lic.expiresAt * 1000 > Date.now();
  const rows = [
    [{ text: '🎁 تست رایگان', callback_data: 'trial' }, { text: '🛒 خرید لایسنس', callback_data: 'buy' }],
    [{ text: '📥 دانلود نسخه جدید برنامه', callback_data: 'dl' }],
    [{ text: '👥 دعوت دوستان (رفرال)', callback_data: 'ref' }, { text: '🔑 کد لایسنس من', callback_data: 'mykey' }],
    [{ text: '📊 وضعیت لایسنس', callback_data: 'status' }, { text: '📖 راهنما', callback_data: 'help' }],
    [{ text: '🆘 پشتیبانی', callback_data: 'support' }],
  ];
  const safe = name.replace(/([_*\[`])/g, '\\$1');
  const hi = name ? `سلام ${safe} 👋\n\n` : '👋\n\n';
  const body = active
    ? `✅ لایسنس فعال شما:\n\`${lic.key}\`\n⏳ تا: ${new Date(lic.expiresAt * 1000).toLocaleDateString('fa-IR')}`
    : 'به ربات رسمی VoidrauVPN خوش آمدید!\n\n🔐 برای فعال‌سازی برنامه:\n• تست رایگان بگیرید یا لایسنس بخرید\n• کد را در برنامه → تب «لایسنس» وارد کنید\n• نسخه جدید برنامه را از «دانلود» بگیرید';
  return { text: hi + body, parse_mode: 'Markdown', reply_markup: { inline_keyboard: rows } };
}

// ── latest release files from GitHub ─────────────────────────────────
async function releaseFiles(env) {
  try {
    const ghHeaders = { 'Accept': 'application/vnd.github+json', 'User-Agent': 'VoidrauLicenseBot' };
    if (env.GITHUB_TOKEN) ghHeaders.Authorization = `Bearer ${env.GITHUB_TOKEN}`;
    const r = await fetch('https://api.github.com/repos/AnishtayiN/vpn/releases/latest', { headers: ghHeaders });
    if (!r.ok) return null;
    const rel = await r.json();
    if (!rel || rel.message) return null;
    const out = (rel.assets || []).map((a) => ({
      name: a.name, size: a.size, url: a.browser_download_url,
      tag: rel.tag_name, date: a.updated_at,
    }));
    return out.length ? out : null;
  } catch (e) { try { console.log('releaseFiles error', e && e.message, e && e.stack && e.stack.split('\n').slice(1,4).join(' | ')); } catch (_) {} return null; }
}

const humanSize = (n) => n > 1048576 ? (n / 1048576).toFixed(1) + ' MB' : Math.round(n / 1024) + ' KB';

const DL_FILES_KEY = 'dlfiles';
const dlLabel = (n) => n.replace(/^VoidrauVPN-/, '').replace(/\.apk$|\.exe$|\.zip$/i, '');

async function doDownloads(env, tid) {
  let files = null;
  try { files = JSON.parse((await env.LICENSES.get('cache:relfiles')) || 'null'); } catch (_) {}
  if (!Array.isArray(files) || !files.length) {
    files = (await releaseFiles(env)) || [];
    if (files.length) await env.LICENSES.put('cache:relfiles', JSON.stringify(files), { expirationTtl: 600 });
  }
  const apk = files.filter((f) => f.name.toLowerCase().endsWith('.apk'));
  const exe = files.filter((f) => f.name.toLowerCase().endsWith('.exe'));
  const other = files.filter((f) => f.name.toLowerCase().endsWith('.zip'));
  const pick = [...apk, ...exe, ...other].slice(0, 8);
  if (!pick.length) return { text: '⚠️ فعلاً فایلی برای ارسال پیدا نشد. بعداً دوباره امتحان کنید.' };
  // remember the list so callback indexes resolve to the same file
  await env.LICENSES.put(`${DL_FILES_KEY}:${tid}`, JSON.stringify(pick), { expirationTtl: 3600 });
  const rows = pick.map((f, i) => [{ text: `📄 ${dlLabel(f.name)} (${humanSize(f.size)})`, callback_data: `file:${i}` }]);
  const tag = pick[0]?.tag || '';
  return {
    text: `📥 آخرین نسخه: ${tag}\nفایل مورد نظر را انتخاب کنید تا همین‌جا برایتان ارسال شود:`,
    reply_markup: { inline_keyboard: [...rows, [{ text: '🔄 بروزرسانی لیست', callback_data: 'dlrefresh' }]] },
  };
}

// send one file as a real document: worker downloads from GitHub and uploads
// to Telegram as multipart (send-by-URL fails on GitHub release redirects).
async function sendReleaseFile(env, tid, url, name) {
  const ghHeaders = {};
  if (env.GITHUB_TOKEN) ghHeaders.Authorization = `Bearer ${env.GITHUB_TOKEN}`;
  const res = await fetch(url, { headers: ghHeaders, redirect: 'follow' });
  if (!res.ok) throw new Error(`github ${res.status}`);
  const buf = await res.arrayBuffer();
  if (buf.byteLength > 45 * 1024 * 1024) {
    await tg(env.BOT_TOKEN, 'sendMessage', {
      chat_id: tid,
      text: `⚠️ فایل ${name} حجمش بیش از حد مجاز ربات است (${humanSize(buf.byteLength)}).\nاز نسخهٔ مخصوص دستگاه‌تان استفاده کنید (arm64 برای اکثر گوشی‌ها).`,
    });
    return;
  }
  const fd = new FormData();
  fd.append('chat_id', String(tid));
  fd.append('document', new Blob([buf]), name);
  const out = await fetch(`https://api.telegram.org/bot${env.BOT_TOKEN}/sendDocument`, { method: 'POST', body: fd });
  const j = await out.json().catch(() => ({}));
  if (!j.ok) throw new Error(j.description || 'telegram upload failed');
}

async function doHelp() {
  return { text: '📖 راهنما\n\n1️⃣ «تست رایگان» → کد ۲۴ ساعته بگیرید\n2️⃣ کد را در برنامه → تب «لایسنس» وارد کنید\n3️⃣ وصل شوید!\n\n🛒 خرید: پلن را انتخاب و کارت‌به‌کارت کنید؛ عکس رسید را همین‌جا بفرستید تا کد برایتان ارسال شود.\n\n👥 رفرال: لینک دعوت را برای دوستان بفرستید؛ هر ۳ نفر = ۷ روز هدیه.\n\n📥 دانلود: همیشه آخرین نسخه برنامه را از همین ربات بگیرید.' };
}

async function doSupport(env) {
  const sup = await getSetting(env, 'supportId', '@Voidrau');
  return { text: `🆘 پشتیبانی:\n${sup}\n\nمشکل‌تان را دقیق بنویسید (اسکرین‌شات بهتر).` };
}

async function doStatus(env, tid) {
  const key = await userKey(env, tid);
  if (!key) return { text: '📊 هیچ لایسنسی ثبت نکرده‌اید — با «تست رایگان» شروع کنید.' };
  const lic = await getLic(env, key);
  if (!lic || !lic.expiresAt) return { text: '📊 لایسنس نامعتبر.' };
  const left = Math.max(0, Math.ceil((lic.expiresAt * 1000 - Date.now()) / 86400000));
  return { text: `📊 وضعیت لایسنس\n\n🔑 کد: \`${key}\`\n📦 پلن: ${lic.plan === 'trial' ? 'تستی' : 'خریداری‌شده'}\n⏳ روز باقی‌مانده: ${left}\n📅 انقضا: ${new Date(lic.expiresAt * 1000).toLocaleDateString('fa-IR')}`, parse_mode: 'Markdown' };
}

export default {
  async fetch(request, env) {
    // Top-level guard: a thrown error must never surface as CF error 1101.
    try {
      return await handleHttp(request, env);
    } catch (e) {
      try { await env.LICENSES.put('lastError', 'fetch: ' + String(e && e.stack || e).slice(0, 400)); } catch (_) {}
      return new Response('⚠️ Worker error — see /diag', { status: 500 });
    }
  },
};

async function handleHttp(request, env) {
  const url = new URL(request.url);

    // ── HTTP API ──────────────────────────────────────────────────────────
    if (url.pathname === '/api/license' || url.pathname === '/api/status') {
      const key = url.searchParams.get('key');
      if (!key) return json({ ok: false, error: 'missing-key' }, 400);
      const lic = await getLic(env, key);
      if (!lic || !lic.expiresAt)
        return json({ ok: false, error: 'invalid' }, 200);
      const now = Math.floor(Date.now() / 1000);
      if (lic.expiresAt <= now)
        return json({ ok: false, error: 'expired' }, 200);
      return json({
        ok: true,
        plan: lic.plan,
        issuedAt: lic.issuedAt,
        expiresAt: lic.expiresAt,
      });
    }

    if (url.pathname === '/api/trial' && request.method === 'POST') {
      const body = await request.json().catch(() => ({}));
      const tid = String(body.telegramId || '').trim();
      if (!/^\d{3,}$/.test(tid)) return json({ ok: false, error: 'bad-id' }, 400);
      // rate limit per IP: 5 requests / 10 min
      const ip = request.headers.get('cf-connecting-ip') || 'x';
      const rlKey = `rl:${ip}`;
      const rl = parseInt((await env.LICENSES.get(rlKey)) || '0');
      if (rl >= 5) return json({ ok: false, error: 'rate-limited' }, 429);
      await env.LICENSES.put(rlKey, String(rl + 1), { expirationTtl: 600 });
      // used-flag first, then claim re-check so parallel calls can't double-issue
      const used2 = await env.LICENSES.get(`trial:${tid}`);
      if (used2) return json({ ok: false, error: 'trial-used' }, 200);
      const claim = crypto.randomUUID();
      await env.LICENSES.put(`trial:${tid}`, claim);
      const check = await env.LICENSES.get(`trial:${tid}`);
      if (check !== claim) return json({ ok: false, error: 'trial-used' }, 200);
      // never clobber an existing active non-trial binding
      const existing = await userKey(env, tid);
      const exLic = existing ? await getLic(env, existing) : null;
      if (exLic && exLic.expiresAt && exLic.expiresAt * 1000 > Date.now() && exLic.plan !== 'trial') {
        return json({ ok: true, key: existing, plan: exLic.plan, expiresAt: exLic.expiresAt });
      }
      const TD = await trialDaysOf(env);
      const key = await mintKey(env, tid, TD, 'trial');
      await extend(env, key, TD);
      return json({ ok: true, key, expiresAt: Math.floor(Date.now() / 1000) + TD * 86400 });
    }

    // ── Telegram webhook ─────────────────────────────────────────────────
    if (url.pathname === '/webhook' && request.method === 'POST') {
      // verify Telegram's signature (fail-open only before the first /setup arms the secret)
      const whs = await env.LICENSES.get('set:whsecret');
      const hdr = request.headers.get('X-Telegram-Bot-Api-Secret-Token');
      if (whs && hdr !== whs) return new Response('forbidden', { status: 403 });
      const upd = await request.json();
      // trace: record last update received + timestamp
      try {
        await env.LICENSES.put('lastUpdate', JSON.stringify({
          at: new Date().toISOString(),
          kind: upd.message ? 'message(' + String(upd.message.text || '').length + 'ch)' : upd.callback_query ? 'callback:' + upd.callback_query.data : 'other',
          from: upd.message?.from?.id || upd.callback_query?.from?.id || null,
        }));
        await env.LICENSES.delete('lastError');
      } catch (_) {}
      // synchronous + traced: every step recorded so /diag shows exactly where it stops
      const steps = ['recv'];
      try {
        await handle(upd, env, steps);
        steps.push('done');
      } catch (e) {
        steps.push('ERROR: ' + String(e && e.stack || e).slice(0, 300));
        try { await env.LICENSES.put('lastError', steps.join(' > ')); } catch (_) {}
      }
      try { await env.LICENSES.put('lastSteps', steps.join(' > ')); } catch (_) {}
      return new Response('ok');
    }

    // Self-healing: any visit to the root re-registers the webhook with Telegram,
    // so simply opening the worker URL (re)sets it — no manual curl needed.
    if (url.pathname === '/' || url.pathname === '/setup') {
      const self = `${url.protocol}//${url.host}/webhook`;
      // get-or-create the webhook secret so Telegram signs every update
      let whs = await env.LICENSES.get('set:whsecret');
      if (!whs) { whs = crypto.randomUUID().replace(/-/g, ''); await env.LICENSES.put('set:whsecret', whs); }
      const set = await tg(env.BOT_TOKEN || '', 'setWebhook', { url: self, allowed_updates: ['message', 'callback_query'], drop_pending_updates: false, secret_token: whs }, env);
      const me0 = await tg(env.BOT_TOKEN || '', 'getMe', {}, env);
      if (me0 && me0.ok && me0.result?.username) await env.LICENSES.put('set:botusername', me0.result.username);
      if (env.LICENSES) await env.LICENSES.put('lastSetup', JSON.stringify({ at: new Date().toISOString(), ok: set.ok, error: set.description || null }));
      if (url.pathname === '/')
        return new Response(`VoidrauVPN license bot — alive.\nWebhook: ${set.ok ? 'SET ✓' : 'FAILED: ' + (set.description || '?')}`);
      return json({ setup: set });
    }
    if (url.pathname === '/diag') {
      // diagnostics are not public: admin must pass ?a=<ADMIN_ID>
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
      return json({
        lastSteps,
        lastSetup: lastSetup ? JSON.parse(lastSetup) : null,
        lastUpdate: lastUpdate ? JSON.parse(lastUpdate) : null,
        lastSentId,
        lastError,
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
    }
    else if (cb.data === 'recheck') out = (await checkJoined(env, tid)) ? { text: '✅ خوش آمدید!' } : joinPrompt(await getSetting(env, 'forceChannel', ''));
    else if (cb.data === 'trial') out = await doTrial(env, tid);
    else if (cb.data === 'buy') out = await buyMenuFull(env);
    else if (cb.data === 'ref') out = await doReferral(env, tid);
    else if (cb.data === 'mykey') out = await doMyKey(env, tid);
    else if (cb.data.startsWith('plan:')) out = await doPlan(env, tid, cb.data.slice(5));
    else if (cb.data.startsWith('okr:') && String(tid) === String(env.ADMIN_ID)) {
      const [, tS, dS] = cb.data.split(':');
      const target = tS, days = parseInt(dS);
      // claim-first: only the first press grants days (double-press = no double grant)
      const recRaw = await env.LICENSES.get(`receipt:${target}`);
      if (!recRaw) {
        out = { text: `ℹ️ رسید ${target} قبلاً پردازش شده (دکمهٔ تکراری).` };
      } else if (!Number.isFinite(days) || days < 1 || days > 3650) {
        out = { text: '❌ روز نامعتبر در دکمهٔ تایید.' };
      } else {
        await env.LICENSES.delete(`receipt:${target}`);
        let k = await userKey(env, target);
        let l = k ? await getLic(env, k) : null;
        if (l && l.expiresAt) { await extend(env, k, days); await upgradePlan(env, k, 'paid'); }
        else { k = await mintKey(env, target, days, 'paid'); await extend(env, k, days); }
        while ((await takeCredit(env, target)) === 1) await extend(env, k, 1);
        await tg(env.BOT_TOKEN, 'sendMessage', { chat_id: target, text: `✅ پرداخت تایید شد!\n\`${k}\`\n${days} روز اضافه شد.`, parse_mode: 'Markdown' }, env, steps);
        if (cb.message?.chat) await tg(env.BOT_TOKEN, 'editMessageReplyMarkup', { chat_id: cb.message.chat.id, message_id: cb.message.message_id, reply_markup: { inline_keyboard: [] } }, env, steps);
        out = { text: '✅ تایید و برای کاربر ارسال شد.' };
      }
    }
    else if (cb.data.startsWith('rej:') && String(tid) === String(env.ADMIN_ID)) {
      const ru = cb.data.slice(4);
      await env.LICENSES.delete(`receipt:${ru}`);
      await tg(env.BOT_TOKEN, 'sendMessage', { chat_id: ru, text: '❌ رسید شما تایید نشد. لطفاً تصویر واضح‌تر از رسید (با مبلغ و تاریخ) بفرستید یا با پشتیبانی تماس بگیرید.' }, env, steps);
      out = { text: `❌ رسید ${ru} رد شد و به کاربر اطلاع داده شد.` };
    }
    else if (cb.data === 'dl' || cb.data === 'dlrefresh') { if (cb.data === 'dlrefresh') await env.LICENSES.delete('cache:relfiles'); out = await doDownloads(env, tid); }
    else if (cb.data.startsWith('file:')) {
      const idx = parseInt(cb.data.slice(5));
      let pick = [];
      try { pick = JSON.parse((await env.LICENSES.get(`${DL_FILES_KEY}:${tid}`)) || '[]'); } catch (_) {}
      const f = pick[idx];
      if (!f) {
        out = await doDownloads(env, tid);
      } else {
        await tg(token, 'answerCallbackQuery', { callback_query_id: cb.id, text: '⏳ در حال ارسال...' });
        cb._answered = true;
        try {
          await sendReleaseFile(env, tid, f.url, f.name);
          await tg(token, 'sendMessage', { chat_id: tid, text: '✅ فایل ارسال شد 👆\n🤖 اندروید: نصب کنید\n🪟 ویندوز: اجرا کنید' });
        } catch (e) {
          await tg(token, 'sendMessage', { chat_id: tid, text: `❌ ارسال فایل ناموفق بود: ${e.message}\nیک‌بار دیگر امتحان کنید.`, reply_markup: { inline_keyboard: [[{ text: '🔄 دوباره', callback_data: `file:${idx}` }], [{ text: '📜 لیست فایل‌ها', callback_data: 'dl' }]] } });
        }
        out = null;
      }
    }
    else if (cb.data === 'help') out = await doHelp();
    else if (cb.data === 'support') out = await doSupport(env);
    else if (cb.data === 'status') out = await doStatus(env, tid);
    else if (cb.data.startsWith('ad:') && String(tid) === String(env.ADMIN_ID)) {
      const a = cb.data.slice(3);
      if (a === 'cancelmode') { await env.LICENSES.delete(`admMode:${tid}`); out = await adminPanel(env, tid); }
      else if (a === 'editbuy') { await env.LICENSES.put(`admMode:${tid}`, 'buyText'); out = { text: 'متن جدید دکمه خرید را بفرست:\n(لغو: دکمهٔ پایین)', reply_markup: { inline_keyboard: [[{ text: '❌ لغو', callback_data: 'ad:cancelmode' }]] } }; }
      else if (a === 'editcard') { await env.LICENSES.put(`admMode:${tid}`, 'cardNumber'); out = await askMode(env, tid, 'شماره کارت جدید را بفرست:', 'cardNumber'); }
      else if (a === 'editch') { await env.LICENSES.put(`admMode:${tid}`, 'forceChannel'); out = await askMode(env, tid, 'آیدی کانال اجباری را بفرست (با @ — خالی برای غیرفعال):', 'forceChannel'); }
      else if (a === 'broadcast') { await env.LICENSES.put(`admMode:${tid}`, 'broadcast'); out = await askMode(env, tid, 'متن/عکس پیام همگانی را بفرست:', 'broadcast'); }
      else if (a === 'editsup') { await env.LICENSES.put(`admMode:${tid}`, 'supportId'); out = await askMode(env, tid, 'آیدی پشتیبانی را بفرست (@...):', 'supportId'); }
      else if (a === 'edittrial') { await env.LICENSES.put(`admMode:${tid}`, 'trialDays'); out = await askMode(env, tid, 'تعداد روز تست رایگان را بفرست:', 'trialDays'); }
      else if (a === 'editplans') { await env.LICENSES.put(`admMode:${tid}`, 'plans'); out = await askMode(env, tid, 'قیمت‌ها را بفرست، هر خط: شناسه|برچسب|روز\nمثال:\nm1|۱ ماهه — ۱۰۰ هزار تومان|30\nm3|۳ ماهه — ۲۵۰ هزار تومان|90\nm12|یک‌ساله — ۸۰۰ هزار تومان|365', 'plans'); }
      else if (a === 'pending') out = await pendingList(env, tid);
      else if (a === 'users') out = await recentUsers(env);
      else if (a === 'export') out = await exportBackup(env, tid);
      else if (a === 'bcsend') {
        let bc = null;
        try { bc = JSON.parse((await env.LICENSES.get(`bc:${tid}`)) || 'null'); } catch (_) {}
        await env.LICENSES.delete(`bc:${tid}`);
        await env.LICENSES.delete(`admMode:${tid}`);
        if (!bc || (!bc.text && !bc.fileId)) { out = { text: '⚠️ پیام همگانی یافت نشد — از نو بفرست.' }; }
        else {
          const list = JSON.parse((await env.LICENSES.get('userIndex')) || '[]');
          let n = 0, fail = 0;
          for (const u of list.slice(0, 500)) {
            try {
              let r;
              if (bc.kind === 'photo') r = await tg(env.BOT_TOKEN, 'sendPhoto', { chat_id: u, photo: bc.fileId, caption: bc.caption || '' });
              else if (bc.kind === 'doc') r = await tg(env.BOT_TOKEN, 'sendDocument', { chat_id: u, document: bc.fileId, caption: bc.caption || '' });
              else r = await tg(env.BOT_TOKEN, 'sendMessage', { chat_id: u, text: bc.text });
              if (r && r.ok) n++; else fail++;
            } catch (_) { fail++; }
          }
          out = { text: `📣 ارسال به ${n} کاربر انجام شد${fail ? ` — ${fail} ناموفق` : ''}.` };
        }
      }
      else if (a === 'stats') {
        const idx = JSON.parse((await env.LICENSES.get('userIndex')) || '[]');
        let act = 0, trial = 0, paid = 0;
        for (const u of idx) {
          const k = await env.LICENSES.get(`user:${u}`);
          if (!k) continue;
          const l = await getLic(env, k);
          if (l && l.expiresAt && l.expiresAt * 1000 > Date.now()) { act++; if (l.plan === 'trial') trial++; else paid++; }
        }
        out = { text: `📊 آمار کامل\n\n👥 کاربران: ${idx.length}\n✅ فعال: ${act}\n🎁 تستی فعال: ${trial}\n💰 خریداری فعال: ${paid}\n🧾 رسید در انتظار: ${(await env.LICENSES.get('stat:pending')) || 0}` };
      }
    }
    else out = { text: 'این دکمه منقضی شده — از /start دوباره شروع کنید.' };
    if (out) await tg(token, 'sendMessage', { chat_id: tid, ...out }, env, steps);
    if (!cb._answered) await tg(token, 'answerCallbackQuery', { callback_query_id: cb.id }, env, steps);
    return;
  }
  if (!msg) { steps.push('no-msg'); return; }
  const tid = msg.from.id;
  const text = (msg.text || '').trim();
  steps.push('msg:' + text.slice(0, 20));

  // Admin pending-input mode FIRST (so admin photos/edits are consumed, not "متوجه نشدم").
  const mediaAdmin = msg.photo ? 'photo' : (msg.document ? 'doc' : null);
  if (String(tid) === String(env.ADMIN_ID)) {
    const mode = await env.LICENSES.get(`admMode:${tid}`);
    if (mode && text.trim() === '/cancel') {
      await env.LICENSES.delete(`admMode:${tid}`);
      await tg(env.BOT_TOKEN, 'sendMessage', { chat_id: tid, text: '❌ حالت ویرایش لغو شد.' }, env, steps);
      return;
    }
    if (mode === 'broadcast' && !text.startsWith('/') && (text || mediaAdmin)) {
      // two-step confirm so a stray message never broadcasts to everyone
      await env.LICENSES.put(`bc:${tid}`, JSON.stringify({ text: mediaAdmin ? '' : text, fileId: mediaAdmin ? (mediaAdmin === 'photo' ? msg.photo[msg.photo.length - 1].file_id : msg.document.file_id) : null, kind: mediaAdmin, caption: msg.caption || '' }));
      await env.LICENSES.put(`admMode:${tid}`, 'bcconfirm');
      await tg(env.BOT_TOKEN, 'sendMessage', {
        chat_id: tid,
        text: '📋 پیش‌نمایش پیام همگانی آماده است. ارسال به همهٔ کاربران؟',
        reply_markup: { inline_keyboard: [[{ text: '✅ ارسال کن', callback_data: 'ad:bcsend' }, { text: '❌ لغو', callback_data: 'ad:cancelmode' }]] },
      }, env, steps);
      return;
    }
    if (mode && !text.startsWith('/')) {
      await env.LICENSES.delete(`admMode:${tid}`);
      if (mediaAdmin) {
        await env.LICENSES.put(`admMode:${tid}`, mode);
        await tg(env.BOT_TOKEN, 'sendMessage', { chat_id: tid, text: 'برای این مورد باید متن بفرستید (عکس/فایل قابل ذخیره نیست).' }, env, steps);
        return;
      }
      if (mode === 'broadcast') {
        // direct broadcast text is handled by the bcconfirm two-step flow
        await env.LICENSES.put(`admMode:${tid}`, mode);
        await tg(env.BOT_TOKEN, 'sendMessage', { chat_id: tid, text: 'از پنل: 📣 پیام همگانی را بزنید و متن را بفرست.' }, env, steps);
        return;
      } else if (mode === 'plans') {
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
        if (new Set(ids).size !== ids.length) { await tg(env.BOT_TOKEN, 'sendMessage', { chat_id: tid, text: '❌ شناسهٔ تکراری — هر پلن شناسهٔ یکتا داشته باشد.' }, env, steps); return; }
        if (bad.length) {
          await env.LICENSES.put(`admMode:${tid}`, mode);
          await tg(env.BOT_TOKEN, 'sendMessage', { chat_id: tid, text: `❌ این خط‌ها درست نیستن (فرمت: شناسه|برچسب|روز):\n${bad.join('\n')}\n\nهمهٔ خط‌ها را دوباره بفرست.`, reply_markup: { inline_keyboard: [[{ text: '❌ لغو', callback_data: 'ad:cancelmode' }]] } }, env, steps);
          return;
        }
        if (rows.length > 20) { await env.LICENSES.put(`admMode:${tid}`, mode); await tg(env.BOT_TOKEN, 'sendMessage', { chat_id: tid, text: '❌ حداکثر ۲۰ پلن — کمتر بفرست.', reply_markup: { inline_keyboard: [[{ text: '❌ لغو', callback_data: 'ad:cancelmode' }]] } }, env, steps); return; }
        if (!rows.length) { await env.LICENSES.put(`admMode:${tid}`, mode); await tg(env.BOT_TOKEN, 'sendMessage', { chat_id: tid, text: '❌ هیچ پلن معتبری پیدا نشد — دوباره بفرست.', reply_markup: { inline_keyboard: [[{ text: '❌ لغو', callback_data: 'ad:cancelmode' }]] } }, env, steps); return; }
        await env.LICENSES.put('setting:plans', JSON.stringify(rows));
        await tg(env.BOT_TOKEN, 'sendMessage', { chat_id: tid, text: `✅ ${rows.length} پلن ذخیره شد:\n${rows.map((r) => `• ${r.label} (${r.days} روز)`).join('\n')}` }, env, steps);
      } else {
        let val = text.trim();
        if (mode === 'forceChannel') {
          if (!val || val === 'خالی' || val === '-') {
            await setSetting(env, mode, '');
            await tg(env.BOT_TOKEN, 'sendMessage', { chat_id: tid, text: '✅ جوین اجباری غیرفعال شد.' }, env, steps);
            steps.push('admin-mode:' + mode);
            return;
          }
          // accept https://t.me/xyz , t.me/xyz , @xyz , xyz , or -100... id
          const mch = val.match(/(?:t\.me\/|@)([A-Za-z0-9_]+)/);
          if (mch) val = '@' + mch[1];
          else if (/^-100\d+$/.test(val)) { /* numeric id — keep as-is */ }
          else { await env.LICENSES.put(`admMode:${tid}`, mode); await tg(env.BOT_TOKEN, 'sendMessage', { chat_id: tid, text: '❌ فرمت کانال درست نیست. دوباره بفرست (مثال: @mychannel یا -1001234…).' }, env, steps); return; }
        }
        if (mode === 'trialDays') {
          if (!/^\d+$/.test(val) || parseInt(val) < 1 || parseInt(val) > 365) {
            await env.LICENSES.put(`admMode:${tid}`, mode);
            await tg(env.BOT_TOKEN, 'sendMessage', { chat_id: tid, text: '❌ عدد نامعتبر (۱ تا ۳۶۵) — دوباره بفرست.', reply_markup: { inline_keyboard: [[{ text: '❌ لغو', callback_data: 'ad:cancelmode' }]] } }, env, steps);
            return;
          }
          await env.LICENSES.put('setting:trialDays', val);
          await tg(env.BOT_TOKEN, 'sendMessage', { chat_id: tid, text: `✅ تست رایگان = ${val} روز.` }, env, steps);
          steps.push('admin-mode:' + mode);
          return;
        }
        await setSetting(env, mode, val);
        await tg(env.BOT_TOKEN, 'sendMessage', { chat_id: tid, text: `✅ ذخیره شد: ${val}` }, env, steps);
      }
      steps.push('admin-mode:' + mode);
      return;
    }
    if (mediaAdmin && !text.startsWith('/')) {
      // admin sent a screenshot outside any edit mode: guide instead of "متوجه نشدم"
      await tg(env.BOT_TOKEN, 'sendMessage', {
        chat_id: tid,
        text: '📸 عکس دریافت شد.\nاگر رسید کاربری را تایید می‌خواهی: /panel → 🧾 رسیدها\nاگر عکس همگانی می‌خواهی بفرستی: /panel → 📣 پیام همگانی، بعد عکس را بفرست.',
      }, env, steps);
      return;
    }
  }

  // Receipt intake: photo or document from a normal user.
  const media2 = msg.photo ? 'photo' : (msg.document ? 'doc' : null);
  if (media2) {
    const fid = media2 === 'photo' ? msg.photo[msg.photo.length - 1].file_id : msg.document.file_id;
    await env.LICENSES.put(`receipt:${tid}`, JSON.stringify({ fileId: fid, kind: media2, at: Date.now() }));
    const cap = `🧾 رسید از کاربر \`${tid}\` — پلن تاییدشده را انتخاب کنید`;
    const fwd = media2 === 'photo' ? await tg(env.BOT_TOKEN, 'sendPhoto', {
      chat_id: env.ADMIN_ID,
      photo: fid,
      caption: cap,
      parse_mode: 'Markdown',
      reply_markup: { inline_keyboard: ((await plansOf(env))).map((p) => [{ text: `تایید ${p.label}`, callback_data: `okr:${tid}:${p.days}` }]) },
    }, env, steps) : await tg(env.BOT_TOKEN, 'sendDocument', {
      chat_id: env.ADMIN_ID,
      document: fid,
      caption: cap,
      parse_mode: 'Markdown',
      reply_markup: { inline_keyboard: ((await plansOf(env))).map((p) => [{ text: `تایید ${p.label}`, callback_data: `okr:${tid}:${p.days}` }]) },
    }, env, steps);
    if (!fwd || !fwd.ok) {
      await tg(env.BOT_TOKEN, 'sendMessage', { chat_id: tid, text: '⚠️ ارسال رسید به ادمین ناموفق بود — دوباره امتحان کنید یا با پشتیبانی تماس بگیرید.' }, env, steps);
      steps.push('receipt-forward-failed');
      return;
    }
    await tg(env.BOT_TOKEN, 'sendMessage', { chat_id: tid, text: '✅ رسید شما ارسال شد — پس از تایید ادمین، کد لایسنس برایتان ارسال می‌شود.' }, env, steps);
    steps.push('receipt-forwarded');
    return;
  }

  if (String(tid) === String(env.ADMIN_ID) && text.trim() === '/panel') {
    steps.push('panel');
    await tg(env.BOT_TOKEN, 'sendMessage', { chat_id: tid, ...(await adminPanel(env, tid)) }, env, steps);
    return;
  }
  if (text.startsWith('/start')) {
    steps.push('start-branch');
    if (String(tid) !== String(env.ADMIN_ID) && !(await checkJoined(env, tid))) {
      steps.push('join-gate');
      await tg(env.BOT_TOKEN, 'sendMessage', { chat_id: tid, ...joinPrompt(await getSetting(env, 'forceChannel', '')) }, env, steps);
      return;
    }
    const idx = JSON.parse((await env.LICENSES.get('userIndex')) || '[]');
    if (!idx.includes(tid)) {
      idx.push(tid);
      await env.LICENSES.put('userIndex', JSON.stringify(idx));
      await env.LICENSES.put('stat:users', String(idx.length));
    }
    // referral payload: /start ref_<referrerId>
    const payload = text.split(' ')[1] || '';
    if (payload.startsWith('ref_')) {
      const ref = payload.slice(4);
      // only real numeric telegram ids count as referrers
      if (!/^\d{3,}$/.test(ref)) { steps.push('ref-bad'); }
      else if (ref !== String(tid)) {
        const seen = await env.LICENSES.get(`refseen:${tid}`);
        if (!seen) {
          await env.LICENSES.put(`refseen:${tid}`, '1');
          await env.LICENSES.put(`refjoin:${ref}`, String(
            (parseInt((await env.LICENSES.get(`refjoin:${ref}`)) || '0')) + 1));
          const joins = parseInt((await env.LICENSES.get(`refjoin:${ref}`)) || '0');
          if (joins % REFERRAL_REWARD_JOINS === 0) {
            await addCredit(env, ref, REFERRAL_REWARD_DAYS);
            await tg(token, 'sendMessage', {
              chat_id: ref,
              text: `🎉 ${REFERRAL_REWARD_JOINS} نفر با لینک شما وارد شدند — ${REFERRAL_REWARD_DAYS} روز هدیه به حساب شما اضافه شد. با /start کدتان را بگیرید.`,
            }, env);
          }
        }
      }
    }
    const key = await userKey(env, tid);
    steps.push('key:' + (key ? key.slice(0, 9) + '…' : 'none'));
    const lic = key ? await getLic(env, key) : null;
    steps.push('lic:' + (lic ? (lic.expiresAt ? 'valid' : 'no-expiry') : 'null'));
    const menu = mainMenu(msg.from, lic);
    steps.push('menu-built');
    const out = await tg(token, 'sendMessage', { chat_id: tid, ...menu }, env, steps);
    steps.push('sent:' + JSON.stringify({ ok: out.ok, id: out.result?.message_id, err: out.description || null }));
    return;
  }

  if (text.startsWith('/gen') && String(tid) === String(env.ADMIN_ID)) {
    const [, daysS, tidS] = text.split(/\s+/);
    const days = parseInt(daysS || '30');
    const target = tidS ? parseInt(tidS) : tid;
    if (!Number.isFinite(days) || days < 1 || days > 3650 || !Number.isFinite(target)) {
      await tg(token, 'sendMessage', { chat_id: tid, text: 'فرمت: /gen <روز> <آیدی> — روز عددی ۱ تا ۳۶۵۰' }, env); return;
    }
    const key = await mintKey(env, target, days, 'paid');
    await extend(env, key, days);
    await tg(token, 'sendMessage', { chat_id: tid, text: `🔑 ساخته شد:\n\`${key}\`\nبرای کاربر \`${target}\` — ${days} روز`, parse_mode: 'Markdown' }, env);
    return;
  }

  if (text.startsWith('/ok') && String(tid) === String(env.ADMIN_ID)) {
    const [, tidS, daysS] = text.split(/\s+/);
    const target = parseInt(tidS);
    const days = parseInt(daysS || '30');
    if (!/^\d{3,}$/.test(tidS || '') || !Number.isFinite(days) || days < 1 || days > 3650) {
      await tg(token, 'sendMessage', { chat_id: tid, text: 'فرمت: /ok <آیدی‌عددی> <روز>' }, env); return;
    }
    // use pending key if any, else mint
    let key = await userKey(env, target);
    let lic = key ? await getLic(env, key) : null;
    if (lic && lic.expiresAt) {
      await extend(env, key, days);
      await upgradePlan(env, key, 'paid');
    } else {
      key = await mintKey(env, target, days, 'paid');
      await extend(env, key, days);
    }
    // spend referral credit if present
    while ((await takeCredit(env, target)) === 1) await extend(env, key, 1);
    await tg(token, 'sendMessage', { chat_id: tid, text: `✅ تایید شد — ${days} روز برای \`${target}\`\n\`${key}\``, parse_mode: 'Markdown' }, env);
    await env.LICENSES.delete(`receipt:${target}`);
    const npOk = Math.max(0, (parseInt((await env.LICENSES.get('stat:pending')) || '0')) - 1);
    await env.LICENSES.put('stat:pending', String(npOk));
    await tg(token, 'sendMessage', {
      chat_id: target,
      text: `✅ پرداخت شما تایید شد!\n\`${key}\`\nاین کد را در برنامه (تب لایسنس) وارد کنید.`,
      parse_mode: 'Markdown',
    }, env);
    return;
  }

  if (text.startsWith('/fix') && String(tid) === String(env.ADMIN_ID)) {
    const target = (text.split(/\s+/)[1] || '').trim();
    if (!target) { await tg(token, 'sendMessage', { chat_id: tid, text: 'فرمت: /fix <آیدی‌کاربر>' }, env); return; }
    const k = await userKey(env, target);
    if (!k) { await tg(token, 'sendMessage', { chat_id: tid, text: `کاربر ${target} لایسنس ندارد.` }, env); return; }
    await upgradePlan(env, k, 'paid');
    const l = await getLic(env, k);
    await tg(token, 'sendMessage', { chat_id: tid, text: `🔧 پلن کاربر ${target} به خریداری تبدیل شد.\n\`${k}\`\n⏳ تا: ${l?.expiresAt ? new Date(l.expiresAt * 1000).toLocaleDateString('fa-IR') : '—'}`, parse_mode: 'Markdown' }, env);
    return;
  }

  if (text === '/id') {
    await tg(token, 'sendMessage', { chat_id: tid, text: `آیدی عددی شما: \`${tid}\``, parse_mode: 'Markdown' }, env);
    return;
  }

  // Unknown input: point back to the menu instead of staying silent.
  await tg(token, 'sendMessage', {
    chat_id: tid,
    text: '🤔 متوجه نشدم. از /start استفاده کنید یا دکمه‌های منو را بزنید.',
  }, env, steps);
}

// ── commerce: card payment + receipt approval + admin panel + forced join ──
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
    // bot not in channel / wrong channel id / not admin: do not lock users out
    // of the bot — surface it to the admin instead.
    try { await env.LICENSES.put('lastError', `force-join: getChatMember ${ch}: ${r?.description || 'unknown'}`); } catch (_) {}
    return true;
  }
  const m = r.result || {};
  const st = m.status || 'left';
  if (st === 'restricted') return m.is_member === true;
  return ['member', 'administrator', 'creator'].includes(st);
}
function joinPrompt(ch) {
  return {
    text: '⛔ برای استفاده از ربات اول در کانال عضو شو:',
    reply_markup: {
      inline_keyboard: [
        ...(/^\d+$/.test(String(ch)) ? [] : [[{ text: '📢 عضویت در کانال', url: `https://t.me/${String(ch).replace('@', '')}` }]]),
        [{ text: '✅ عضو شدم', callback_data: 'recheck' }],
      ],
    },
  };
}
async function buyMenuFull(env) {
  const card = await getSetting(env, 'cardNumber', 'تنظیم نشده — از /panel تنظیم کنید');
  const buyText = await getSetting(env, 'buyText', '🛒 خرید لایسنس');
  return {
    text: `${buyText}\n💳 کارت به کارت: ${card}\n\nپلن را انتخاب کنید؛ پس از پرداخت، اسکرین‌شات رسید را در همین چت بفرست تا ادمین تایید کند.`,
    reply_markup: {
      inline_keyboard: [
        ...((await plansOf(env))).map((p) => [{ text: p.label, callback_data: `plan:${p.id}` }]),
      ],
    },
  };
}
async function askMode(env, tid, prompt, mode) {
  return { text: prompt, reply_markup: { inline_keyboard: [[{ text: '❌ لغو', callback_data: 'ad:cancelmode' }]] } };
}

async function adminPanel(env, tid) {
  const card = await getSetting(env, 'cardNumber', '—');
  const buy = await getSetting(env, 'buyText', 'خرید لایسنس');
  const ch = await getSetting(env, 'forceChannel', '—');
  const sup = await getSetting(env, 'supportId', '@Voidrau');
  const trialDays = String(await trialDaysOf(env));
  const users = parseInt((await env.LICENSES.get('stat:users')) || '0');
  const pending = parseInt((await env.LICENSES.get('stat:pending')) || '0');
  // count active licenses
  let active = 0;
  const idx = JSON.parse((await env.LICENSES.get('userIndex')) || '[]');
  for (const u of idx) {
    const k = await env.LICENSES.get(`user:${u}`);
    if (!k) continue;
    const l = await getLic(env, k);
    if (l && l.expiresAt && l.expiresAt * 1000 > Date.now()) active++;
  }
  return {
    text: `🛠 پنل ادمین\n\n👥 کاربران: ${users}\n✅ لایسنس فعال: ${active}\n🧾 رسید در انتظار: ${pending}\n💳 کارت: ${card}\n🛒 متن خرید: ${buy}\n📢 کانال اجباری: ${ch}\n🎁 روز تست: ${trialDays}\n🆘 پشتیبانی: ${sup}`,
    reply_markup: { inline_keyboard: [
      [{ text: '✏️ متن خرید', callback_data: 'ad:editbuy' }, { text: '💳 شماره کارت', callback_data: 'ad:editcard' }],
      [{ text: '💰 قیمت‌ها', callback_data: 'ad:editplans' }, { text: '📢 کانال اجباری', callback_data: 'ad:editch' }],
      [{ text: '🆘 پشتیبانی', callback_data: 'ad:editsup' }, { text: '🎁 روز تست', callback_data: 'ad:edittrial' }],
      [{ text: '📊 آمار کامل', callback_data: 'ad:stats' }, { text: '🧾 رسیدها', callback_data: 'ad:pending' }],
      [{ text: '👥 کاربران اخیر', callback_data: 'ad:users' }, { text: '📣 پیام همگانی', callback_data: 'ad:broadcast' }],
      [{ text: '💾 خروجی پشتیبان', callback_data: 'ad:export' }],
    ] },
  };
}

// pending receipts list with per-receipt approve buttons
async function pendingList(env, tid) {
  const idx = JSON.parse((await env.LICENSES.get('userIndex')) || '[]');
  const rows = [];
  let n = 0;
  for (const u of idx) {
    const raw = await env.LICENSES.get(`receipt:${u}`);
    if (!raw) continue;
    const planId = await getSetting(env, `lastPlan:${u}`, 'm1');
    const p = ((await plansOf(env))).find((x) => x.id === planId) || ((await plansOf(env)))[0];
    rows.push([{ text: `🧾 کاربر ${u} — ${p.label}`, callback_data: `okr:${u}:${p.days}` }, { text: '❌', callback_data: `rej:${u}` }]);
    n++;
  }
  return { text: n ? `🧾 ${n} رسید در انتظار — برای تایید بزنید:` : '🧾 رسید در انتظاری نیست.',
    reply_markup: rows.length ? { inline_keyboard: rows } : undefined };
}

async function recentUsers(env) {
  const idx = JSON.parse((await env.LICENSES.get('userIndex')) || '[]');
  const last = idx.slice(-10).reverse();
  let t = `👥 آخرین کاربران (${idx.length} کل):\n\n`;
  for (const u of last) {
    const k = await env.LICENSES.get(`user:${u}`);
    let s = 'بدون لایسنس';
    if (k) {
      const l = await getLic(env, k);
      if (l && l.expiresAt) s = l.expiresAt * 1000 > Date.now() ? `فعال تا ${new Date(l.expiresAt * 1000).toLocaleDateString('fa-IR')}` : 'منقضی';
    }
    t += `• ${u} — ${s}\n`;
  }
  return { text: t };
}

async function exportBackup(env, tid) {
  const idx = JSON.parse((await env.LICENSES.get('userIndex')) || '[]');
  const out = [];
  for (const u of idx) {
    const k = await env.LICENSES.get(`user:${u}`);
    const l = k ? await getLic(env, k) : null;
    out.push({ id: u, key: k || null, plan: l?.plan || null, expiresAt: l?.expiresAt || null });
  }
  const body = JSON.stringify(out, null, 1);
  // KV values cap ~25MB — fine. Send as file via document upload requires multipart; send as text chunk instead.
  return { text: '💾 پشتیبان:\n' + body.slice(0, 3800) };
}

async function doTrial(env, tid) {
  const used = await env.LICENSES.get(`trial:${tid}`);
  if (used) {
    const key = await userKey(env, tid);
    const lic = key ? await getLic(env, key) : null;
    if (!lic) return { text: '🔑 لایسنس قبلی پیدا نشد — با پشتیبانی تماس بگیرید یا مجدد /start بزنید.' };
    const active = lic && lic.expiresAt && lic.expiresAt * 1000 > Date.now();
    if (active) return { text: `🎁 تست/لایسنس شما هنوز فعال است:\n\`${key}\`\n⏳ تا: ${new Date(lic.expiresAt * 1000).toLocaleDateString('fa-IR')}`, parse_mode: 'Markdown' };
    return { text: '⏳ تست رایگان شما تمام شده.\n🛒 برای ادامه از «خرید لایسنس» استفاده کنید.', reply_markup: { inline_keyboard: [[{ text: '🛒 خرید لایسنس', callback_data: 'buy' }]] } };
  }
  const TD = await trialDaysOf(env);
  const key = await mintKey(env, tid, TD, 'trial');
  await extend(env, key, TD);
  await env.LICENSES.put(`trial:${tid}`, '1');
  // spend any referral credit on top
  while ((await takeCredit(env, tid)) === 1) await extend(env, key, 1);
  return { text: `🎁 تست ${TD} روزه فعال شد!\n\`${key}\`\nدر برنامه → تب «لایسنس» → کد را وارد کنید.`, parse_mode: 'Markdown' };
}


async function doPlan(env, tid, planId) {
  const p = ((await plansOf(env))).find((x) => x.id === planId);
  if (!p) return { text: 'پلن نامعتبر.' };
  await setSetting(env, `lastPlan:${tid}`, p.id);
  const card = await getSetting(env, 'cardNumber', '—');
  return { text: `🛒 پلن: ${p.label}\n💳 مبلغ را کارت به کارت کنید به:\n${card}\n\nسپس اسکرین‌شات رسید را همین‌جا بفرست تا ادمین تایید کند.` };
}

async function doReferral(env, tid) {
  const joins = parseInt((await env.LICENSES.get(`refjoin:${tid}`)) || '0');
  const credit = (await env.LICENSES.get(`credit:${tid}`)) || '0';
  return {
    text: `👥 لینک دعوت اختصاصی شما:\nhttps://t.me/${env.BOT_USERNAME || (await env.LICENSES.get('set:botusername')) || 'VoidrauBot'}?start=ref_${tid}\n\n` +
      `تاکنون ${joins} نفر وارد شدند — به ازای هر ${REFERRAL_REWARD_JOINS} نفر، ${REFERRAL_REWARD_DAYS} روز هدیه می‌گیرید.\n` +
      `اعتبار فعلی: ${credit} روز`,
  };
}

async function doMyKey(env, tid) {
  const key = await userKey(env, tid);
  if (!key) return { text: 'هنوز لایسنسی ندارید — از «تست رایگان» شروع کنید.' };
  const lic = await getLic(env, key);
  if (!lic || !lic.expiresAt) return { text: 'لایسنس شما نامعتبر است.' };
  return {
    text: `🔑 کد شما: \`${key}\`\nانقضا: ${new Date(lic.expiresAt * 1000).toLocaleDateString('fa-IR')}`,
    parse_mode: 'Markdown',
  };
}

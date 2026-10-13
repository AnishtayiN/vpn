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
//   • /gen <days> <tid> → admin: mint a key
//   • /ok <tid> <days>  → admin: approve a pending purchase
//
// HTTP API (used by the app):
//   GET  /api/license?key=...
//   GET  /api/status?key=...
//   POST /api/trial {telegramId}

const PLANS = [
  { id: 'm1', label: '۱ ماهه — ۱۰۰ هزار تومان', days: 30 },
  { id: 'm3', label: '۳ ماهه — ۲۵۰ هزار تومان', days: 90 },
  { id: 'm12', label: 'یک‌ساله — ۸۰۰ هزار تومان', days: 365 },
];
const TRIAL_DAYS = 1;
const REFERRAL_REWARD_JOINS = 3;   // every N joins
const REFERRAL_REWARD_DAYS = 7;    // → N days credit

const fa = (s) => s; // all UI strings are Persian already

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
  return await env.LICENSES.get(`lic:${key}`, 'json');
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
  if (cur <= 0) return 0;
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
  const lic = await getLic(env, key);
  if (!lic) return null;
  const now = Math.floor(Date.now() / 1000);
  const base = lic.expiresAt && lic.expiresAt > now ? lic.expiresAt : now;
  lic.expiresAt = base + days * 86400;
  lic.days = (lic.days || 0) + days;
  await putLic(env, key, lic);
  return lic;
}

async function tg(token, method, body) {
  const r = await fetch(`https://api.telegram.org/bot${token}/${method}`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body),
  });
  return r.json();
}

function mainMenu(from, lic) {
  const rows = [
    [{ text: '🎁 تست رایگان ۲۴ ساعته', callback_data: 'trial' }],
    [{ text: '🛒 خرید لایسنس', callback_data: 'buy' }],
    [{ text: '👥 دعوت دوستان (رفرال)', callback_data: 'ref' }],
    [{ text: '🔑 کد لایسنس من', callback_data: 'mykey' }],
  ];
  return {
    text: lic && lic.expiresAt && lic.expiresAt * 1000 > Date.now()
      ? `✅ لایسنس فعال شما:\n\`${lic.key}\`\nتا: ${new Date(lic.expiresAt * 1000).toLocaleDateString('fa-IR')}`
      : 'به ربات VoidrauVPN خوش آمدید 👋\nبرای فعال‌سازی برنامه یکی از گزینه‌ها را انتخاب کنید.',
    parse_mode: 'Markdown',
    reply_markup: { inline_keyboard: rows },
  };
}

export default {
  async fetch(request, env) {
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
      if (!tid) return json({ ok: false, error: 'missing-id' }, 400);
      const used = await env.LICENSES.get(`trial:${tid}`);
      if (used) return json({ ok: false, error: 'trial-used' }, 200);
      const key = await mintKey(env, tid, TRIAL_DAYS, 'trial');
      await env.LICENSES.put(`trial:${tid}`, '1');
      await extend(env, key, TRIAL_DAYS);
      return json({ ok: true, key, expiresAt: Math.floor(Date.now() / 1000) + TRIAL_DAYS * 86400 });
    }

    // ── Telegram webhook ─────────────────────────────────────────────────
    if (url.pathname === '/webhook' && request.method === 'POST') {
      const upd = await request.json();
      // fire-and-forget so the webhook returns 200 immediately
      (async () => { try { await handle(upd, env); } catch (e) {} })();
      return new Response('ok');
    }

    if (url.pathname === '/') return new Response('VoidrauVPN license bot — alive.');
    return json({ ok: false, error: 'not-found' }, 404);
  },
};

async function handle(upd, env) {
  const token = env.BOT_TOKEN;
  const msg = upd.message;
  const cb = upd.callback_query;

  if (cb) {
    const tid = cb.from.id;
    let out = null;
    if (cb.data === 'trial') out = await doTrial(env, tid);
    else if (cb.data === 'buy') out = buyMenu();
    else if (cb.data === 'ref') out = await doReferral(env, tid);
    else if (cb.data === 'mykey') out = await doMyKey(env, tid);
    else if (cb.data.startsWith('plan:')) out = await doPlan(env, tid, cb.data.slice(5));
    if (out) await tg(token, 'sendMessage', { chat_id: tid, ...out });
    await tg(token, 'answerCallbackQuery', { callback_query_id: cb.id });
    return;
  }
  if (!msg) return;
  const tid = msg.from.id;
  const text = (msg.text || '').trim();

  if (text.startsWith('/start')) {
    // referral payload: /start ref_<referrerId>
    const payload = text.split(' ')[1] || '';
    if (payload.startsWith('ref_')) {
      const ref = payload.slice(4);
      if (ref !== String(tid)) {
        const seen = await env.LICENSES.get(`refseen:${tid}`);
        if (!seen) {
          await env.LICENSES.put(`refseen:${tid}`, '1');
          await addCredit(env, ref, 0); // counter via credit store: 1 join = +1 join
          await env.LICENSES.put(`refjoin:${ref}`, String(
            (parseInt((await env.LICENSES.get(`refjoin:${ref}`)) || '0')) + 1));
          const joins = parseInt((await env.LICENSES.get(`refjoin:${ref}`)) || '0');
          if (joins % REFERRAL_REWARD_JOINS === 0) {
            await addCredit(env, ref, REFERRAL_REWARD_DAYS);
            await tg(token, 'sendMessage', {
              chat_id: ref,
              text: `🎉 ${REFERRAL_REWARD_JOINS} نفر با لینک شما وارد شدند — ${REFERRAL_REWARD_DAYS} روز هدیه به حساب شما اضافه شد. با /start کدتان را بگیرید.`,
            });
          }
        }
      }
    }
    const key = await userKey(env, tid);
    const lic = key ? await getLic(env, key) : null;
    await tg(token, 'sendMessage', { chat_id: tid, ...mainMenu(msg.from, lic) });
    return;
  }

  if (text.startsWith('/gen') && String(tid) === String(env.ADMIN_ID)) {
    const [, daysS, tidS] = text.split(/\s+/);
    const days = parseInt(daysS || '30');
    const target = tidS ? parseInt(tidS) : tid;
    const key = await mintKey(env, target, days, 'admin');
    await extend(env, key, days);
    await tg(token, 'sendMessage', { chat_id: tid, text: `🔑 ساخته شد:\n\`${key}\`\nبرای کاربر \`${target}\` — ${days} روز`, parse_mode: 'Markdown' });
    return;
  }

  if (text.startsWith('/ok') && String(tid) === String(env.ADMIN_ID)) {
    const [, tidS, daysS] = text.split(/\s+/);
    const target = parseInt(tidS);
    const days = parseInt(daysS || '30');
    // use pending key if any, else mint
    let key = await userKey(env, target);
    let lic = key ? await getLic(env, key) : null;
    if (lic && lic.expiresAt) {
      await extend(env, key, days);
    } else {
      key = await mintKey(env, target, days, 'paid');
      await extend(env, key, days);
    }
    // spend referral credit if present
    while ((await takeCredit(env, target)) === 1) await extend(env, key, 1);
    await tg(token, 'sendMessage', { chat_id: tid, text: `✅ تایید شد — ${days} روز برای \`${target}\`\n\`${key}\``, parse_mode: 'Markdown' });
    await tg(token, 'sendMessage', {
      chat_id: target,
      text: `✅ پرداخت شما تایید شد!\n\`${key}\`\nاین کد را در برنامه (تب لایسنس) وارد کنید.`,
      parse_mode: 'Markdown',
    });
    return;
  }

  if (text === '/id') {
    await tg(token, 'sendMessage', { chat_id: tid, text: `آیدی عددی شما: \`${tid}\``, parse_mode: 'Markdown' });
  }
}

async function doTrial(env, tid) {
  const used = await env.LICENSES.get(`trial:${tid}`);
  if (used) {
    const key = await userKey(env, tid);
    return { text: `شما قبلاً تست رایگان گرفته‌اید.\nکد شما: \`${key || '—'}\``, parse_mode: 'Markdown' };
  }
  const key = await mintKey(env, tid, TRIAL_DAYS, 'trial');
  await extend(env, key, TRIAL_DAYS);
  await env.LICENSES.put(`trial:${tid}`, '1');
  // spend any referral credit on top
  while ((await takeCredit(env, tid)) === 1) await extend(env, key, 1);
  return { text: `🎁 تست ۲۴ ساعته فعال شد!\n\`${key}\`\nدر برنامه → تب «لایسنس» → کد را وارد کنید.`, parse_mode: 'Markdown' };
}

function buyMenu() {
  return {
    text: '🛒 پلن مورد نظر را انتخاب کنید:\n(پرداخت و تحویل کد توسط پشتیبانی انجام می‌شود)',
    reply_markup: {
      inline_keyboard: [
        ...PLANS.map((p) => [{ text: p.label, callback_data: `plan:${p.id}` }]),
      ],
    },
  };
}

async function doPlan(env, tid, planId) {
  const p = PLANS.find((x) => x.id === planId);
  if (!p) return { text: 'پلن نامعتبر.' };
  const admin = env.ADMIN_ID;
  await env.LICENSES.put(`pending:${tid}`, p.id);
  const txt = `🛒 درخواست خرید: ${p.label}\nآیدی کاربر: \`${tid}\`\n\nپس از دریافت پرداخت، ادمین با دستور /ok تایید می‌کند.`;
  await tg(env.BOT_TOKEN, 'sendMessage', { chat_id: admin, text: txt, parse_mode: 'Markdown' });
  return { text: 'درخواست شما ثبت شد ✅\nپشتیبانی برای پرداخت با شما در تماس است.' };
}

async function doReferral(env, tid) {
  const joins = parseInt((await env.LICENSES.get(`refjoin:${tid}`)) || '0');
  const credit = (await env.LICENSES.get(`credit:${tid}`)) || '0';
  return {
    text: `👥 لینک دعوت اختصاصی شما:\nhttps://t.me/${env.BOT_USERNAME || 'VoidrauLicenseBot'}?start=ref_${tid}\n\n` +
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

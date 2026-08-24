// ============================================================
//  ISS Weighbridge — mailer
//
//  A small, dependency-free SMTP client. Deliberately no nodemailer:
//  this app is installed on colliery PCs from an offline installer and
//  built on a CI runner that has already given trouble with native and
//  third-party modules. Everything here is Node core (net, tls, crypto).
//
//  Supports:
//    · implicit TLS  (port 465)          secure:true
//    · STARTTLS      (port 587 / 25)     secure:false  (upgrades if offered)
//    · AUTH LOGIN and AUTH PLAIN
//    · multipart/mixed  →  multipart/alternative (text + html) + attachments
//
//  Also does the outbound HTTPS POST used by the WhatsApp channel, because
//  the renderer runs on file:// and Meta's Graph API sends no CORS headers,
//  so a fetch() from the page is blocked before it leaves the machine.
// ============================================================
'use strict';
const net = require('net');
const tls = require('tls');
const https = require('https');
const crypto = require('crypto');

const CRLF = '\r\n';

// ── tiny line-oriented SMTP conversation ───────────────────────────────────
class Conn {
  constructor(sock, log) {
    this.sock = sock;
    this.buf = '';
    this.pending = null;
    this.log = log || (() => {});
    sock.setEncoding('utf8');
    sock.on('data', (d) => { this.buf += d; this._pump(); });
  }
  _pump() {
    if (!this.pending) return;
    const lines = this.buf.split(/\r?\n/);
    for (let i = 0; i < lines.length; i++) {
      if (/^\d{3} /.test(lines[i])) {                 // space = final line
        const block = lines.slice(0, i + 1).join(CRLF);
        this.buf = lines.slice(i + 1).join(CRLF);
        const p = this.pending; this.pending = null;
        this.log('S: ' + block.replace(/\n/g, ' | '));
        p.resolve({ code: parseInt(block.slice(0, 3), 10), text: block });
        return;
      }
    }
  }
  read(timeout) {
    return new Promise((resolve, reject) => {
      this.pending = { resolve, reject };
      this._pump();
      if (this.pending) {
        const t = setTimeout(() => {
          if (this.pending) { this.pending = null; reject(new Error('SMTP timed out waiting for the server')); }
        }, timeout || 30000);
        const orig = resolve;
        this.pending.resolve = (v) => { clearTimeout(t); orig(v); };
      }
    });
  }
  write(line, hide) {
    this.log('C: ' + (hide ? '***' : line));
    this.sock.write(line + CRLF);
  }
  async cmd(line, expect, hide) {
    this.write(line, hide);
    const r = await this.read();
    if (expect && !expect.includes(Math.floor(r.code / 100)) && !expect.includes(r.code)) {
      throw new Error('SMTP ' + r.code + ' — ' + r.text.split(/\r?\n/)[0].slice(4));
    }
    return r;
  }
}

function connect(opts) {
  return new Promise((resolve, reject) => {
    const common = { host: opts.host, port: opts.port };
    const done = (s) => { s.removeListener('error', reject); resolve(s); };
    let sock;
    if (opts.secure) {
      sock = tls.connect(Object.assign({ servername: opts.host,
        rejectUnauthorized: opts.rejectUnauthorized !== false }, common), () => done(sock));
    } else {
      sock = net.connect(common, () => done(sock));
    }
    sock.once('error', reject);
    sock.setTimeout(opts.timeout || 30000, () => sock.destroy(new Error('Connection to ' + opts.host + ' timed out')));
    // Cleared by the caller once connected — see sendMail. An idle timer left
    // running kills the socket while it is legitimately waiting for the 250
    // that follows a large message.
  });
}

// ── MIME ───────────────────────────────────────────────────────────────────
function b64(s) { return Buffer.from(String(s), 'utf8').toString('base64'); }
function wrap76(s) { return (s.match(/.{1,76}/g) || []).join(CRLF); }
function hdrEnc(s) {                                    // RFC 2047 for non-ASCII
  const v = String(s == null ? '' : s);
  return /[^\x20-\x7E]/.test(v) ? '=?UTF-8?B?' + b64(v) + '?=' : v;
}
function addrList(a) {
  return (Array.isArray(a) ? a : String(a || '').split(/[;,]/))
    .map((x) => String(x).trim()).filter(Boolean);
}

function buildMime(m) {
  const mix = 'ISSMIX-' + crypto.randomBytes(12).toString('hex');
  const alt = 'ISSALT-' + crypto.randomBytes(12).toString('hex');
  const atts = m.attachments || [];
  const H = [];
  H.push('From: ' + (m.fromName ? hdrEnc(m.fromName) + ' <' + m.from + '>' : m.from));
  H.push('To: ' + addrList(m.to).join(', '));
  if (addrList(m.cc).length) H.push('Cc: ' + addrList(m.cc).join(', '));
  if (m.replyTo) H.push('Reply-To: ' + m.replyTo);
  H.push('Subject: ' + hdrEnc(m.subject || ''));
  H.push('Date: ' + new Date().toUTCString());
  const fromDom = (String(m.from || '').split('@')[1] || 'iss-weighbridge.local').replace(/[>\s]/g, '');
  H.push('Message-ID: <' + crypto.randomBytes(16).toString('hex') + '@' + fromDom + '>');
  H.push('MIME-Version: 1.0');
  H.push('X-Mailer: ISS Weighbridge');

  const body = [];
  const openAlt = () => {
    body.push('Content-Type: multipart/alternative; boundary="' + alt + '"', '');
    body.push('--' + alt);
    body.push('Content-Type: text/plain; charset=UTF-8', 'Content-Transfer-Encoding: base64', '');
    body.push(wrap76(b64(m.text || '')));
    if (m.html) {
      body.push('--' + alt);
      body.push('Content-Type: text/html; charset=UTF-8', 'Content-Transfer-Encoding: base64', '');
      body.push(wrap76(b64(m.html)));
    }
    body.push('--' + alt + '--');
  };

  if (!atts.length) {
    openAlt();
    return H.join(CRLF) + CRLF + body.join(CRLF) + CRLF;
  }
  H.push('Content-Type: multipart/mixed; boundary="' + mix + '"');
  const out = [''];
  out.push('--' + mix);
  openAlt();
  atts.forEach((a) => {
    const data = a.base64 || Buffer.from(String(a.content || ''), 'utf8').toString('base64');
    body.push('--' + mix);
    body.push('Content-Type: ' + (a.type || 'application/octet-stream') + '; name="' + (a.filename || 'file') + '"');
    body.push('Content-Transfer-Encoding: base64');
    body.push('Content-Disposition: attachment; filename="' + (a.filename || 'file') + '"', '');
    body.push(wrap76(data));
  });
  body.push('--' + mix + '--');
  // ONE join over the whole lot. Joining `out` and `body` separately and then
  // concatenating the two strings left the opening boundary glued to the first
  // part header ("--ISSMIX-abcContent-Type: ..."), which is not a boundary
  // line, so every client saw a multipart message with no parts in it: no
  // body, no attachment.
  return H.join(CRLF) + CRLF + out.concat(body).join(CRLF) + CRLF;
}

// ── send ───────────────────────────────────────────────────────────────────
//  opts: {host, port, secure, user, pass, from, fromName, to, cc, replyTo,
//         subject, text, html, attachments:[{filename,type,content|base64}]}
async function sendMail(opts) {
  const trace = [];
  const log = (l) => { if (trace.length < 60) trace.push(l); };
  const host = String(opts.host || '').trim();
  const port = parseInt(opts.port, 10) || (opts.secure ? 465 : 587);
  if (!host) return { ok: false, error: 'No SMTP server set' };
  const to = addrList(opts.to);
  if (!to.length) return { ok: false, error: 'No recipient' };

  const from = opts.from || opts.user;

  let sock, conn;
  // A socket that errors or closes with nobody listening throws an uncaught
  // exception in the main process — an LTE link dropping mid-send used to do
  // exactly that. Route both into whichever read is waiting so the send simply
  // fails and the outbox retries it.
  const guard = (s) => {
    const bail = (e) => {
      if (conn && conn.pending) { const p = conn.pending; conn.pending = null; p.reject(e); }
    };
    s.on('error', (e) => bail(e instanceof Error ? e : new Error(String(e))));
    s.on('close', () => bail(new Error('The mail server closed the connection')));
  };

  try {
    sock = await connect({ host, port, secure: !!opts.secure, timeout: opts.timeout,
                           rejectUnauthorized: opts.rejectUnauthorized });
    sock.setTimeout(0);                       // reads carry their own timeouts
    conn = new Conn(sock, log);
    guard(sock);
    const greet = await conn.read();                       // 220, or a refusal
    if (Math.floor(greet.code / 100) !== 2) {
      // e.g. "421 service not available" from a throttled or blocked server.
      // Fail here rather than pressing on and waiting out the read timeout.
      throw new Error('SMTP ' + greet.code + ' — ' + greet.text.slice(4));
    }
    // Some servers refuse a bare label here; use the sender's domain.
    const me = opts.clientName || (String(from || '').split('@')[1] || '').trim() || 'iss-weighbridge.local';
    let ehlo = await conn.cmd('EHLO ' + me, [2]);

    if (!opts.secure && /STARTTLS/i.test(ehlo.text)) {
      await conn.cmd('STARTTLS', [2]);
      // Detach the plaintext reader first — leaving it attached puts the raw
      // socket in flowing mode while TLS is trying to read the handshake.
      sock.removeAllListeners('data');
      sock.removeAllListeners('close');
      const up = await new Promise((res, rej) => {
        const s = tls.connect({ socket: sock, servername: host,
          rejectUnauthorized: opts.rejectUnauthorized !== false }, () => res(s));
        s.once('error', rej);
      });
      conn = new Conn(up, log);
      sock = up;
      sock.setTimeout(0);
      guard(sock);
      ehlo = await conn.cmd('EHLO ' + me, [2]);
    }

    if (opts.user) {
      if (/AUTH[^\r\n]*PLAIN/i.test(ehlo.text)) {
        await conn.cmd('AUTH PLAIN ' + Buffer.from('\0' + opts.user + '\0' + (opts.pass || ''), 'utf8').toString('base64'), [2], true);
      } else {
        await conn.cmd('AUTH LOGIN', [334]);
        await conn.cmd(b64(opts.user), [334], true);
        await conn.cmd(b64(opts.pass || ''), [2], true);
      }
    }

    await conn.cmd('MAIL FROM:<' + from + '>', [2]);
    for (const r of to.concat(addrList(opts.cc))) await conn.cmd('RCPT TO:<' + r + '>', [2]);
    await conn.cmd('DATA', [354]);

    const mime = buildMime(Object.assign({}, opts, { from, to }));
    // dot-stuffing: a line that is exactly "." would end the message early
    conn.sock.write(mime.replace(/\r?\n\./g, CRLF + '..') + CRLF + '.' + CRLF);
    const r = await conn.read(120000);
    if (Math.floor(r.code / 100) !== 2) throw new Error('SMTP ' + r.code + ' — ' + r.text.slice(4));
    try { await conn.cmd('QUIT'); } catch (_) {}
    sock.end();
    return { ok: true, response: r.text.split(/\r?\n/)[0], accepted: to.length };
  } catch (e) {
    try { if (sock) sock.destroy(); } catch (_) {}
    return { ok: false, error: friendly(e), trace };
  }
}

// Turn the usual failures into something a site manager can act on.
function friendly(e) {
  const m = String((e && e.message) || e || 'unknown error');
  if (/ENOTFOUND|EAI_AGAIN/i.test(m)) return 'Cannot find the mail server — check the SMTP host name, and that this PC has internet.';
  if (/ECONNREFUSED/i.test(m))        return 'The mail server refused the connection — check the port (465 for SSL, 587 for TLS).';
  if (/ETIMEDOUT|timed out/i.test(m)) return 'The mail server did not answer — a firewall on site is the usual cause.';
  if (/535|534|authentication/i.test(m)) return 'The mail server rejected the username or password. Gmail and Microsoft 365 need an app password, not the normal one.';
  if (/self.signed|certificate/i.test(m)) return 'The mail server\'s security certificate was rejected: ' + m;
  if (/^SMTP 454/.test(m)) return 'The server offered an encrypted connection and then refused it. Credentials were not sent. Try port 465 with SSL ticked.';
  if (/^SMTP 421/.test(m)) return 'The mail server turned the connection away (421) — usually rate limiting or a blocked IP. It will be retried.';
  return m;
}

// ── generic HTTPS JSON POST (WhatsApp Cloud API, webhooks) ─────────────────
function httpPost({ url, headers, body, timeout }) {
  return new Promise((resolve) => {
    let u;
    try { u = new URL(url); } catch (_) { return resolve({ ok: false, error: 'Bad URL' }); }
    if (u.protocol !== 'https:') return resolve({ ok: false, error: 'Only https:// endpoints are allowed' });
    const payload = typeof body === 'string' ? body : JSON.stringify(body || {});
    const req = https.request({
      method: 'POST', hostname: u.hostname, port: u.port || 443, path: u.pathname + u.search,
      headers: Object.assign({
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(payload),
      }, headers || {}),
    }, (res) => {
      let d = '';
      res.on('data', (c) => { d += c; });
      res.on('end', () => {
        let json = null; try { json = JSON.parse(d); } catch (_) {}
        const ok = res.statusCode >= 200 && res.statusCode < 300;
        resolve({ ok, status: res.statusCode, body: json || d.slice(0, 2000),
                  error: ok ? null : ((json && json.error && json.error.message) || ('HTTP ' + res.statusCode)) });
      });
    });
    req.setTimeout(timeout || 30000, () => { req.destroy(new Error('Request timed out')); });
    req.on('error', (e) => resolve({ ok: false, error: friendly(e) }));
    req.write(payload);
    req.end();
  });
}

module.exports = { sendMail, httpPost };

#!/usr/bin/env node
/**
 * ollama-usage-poller.mjs
 *
 * Fetches the Ollama Cloud balance and writes a snapshot file that claude-hud
 * reads via `display.externalUsagePath`.
 *
 * The quota lives in https://ollama.com/api/balance since the 2026-08 pricing
 * change: /api/usage now carries only per-request metrics (request counts, USD,
 * tokens) and no longer exposes limit windows. Parity with
 * ollama-usage-poller.sh (hcross/ollama-usage @47d9bcb).
 *
 * Auth: reproduces the Ollama server's own mechanism — sign each request to
 * ollama.com with the ed25519 key at ~/.ollama/id_ed25519 (challenge-response,
 * no API key needed). The Authorization header is `<pubkey>:<base64(sig)>`
 * where the challenge is `METHOD,/path?ts=<unix>`.
 *
 * Included-balance shapes (docs.ollama.com/api/balance — `included` is a oneOf):
 *   - Legacy plans: `session` / `weekly` objects with `remaining_percent`
 *     (0-100, quota REMAINING, not consumed — convert with used = 100 − rest)
 *     and `resets_at`. Maps 1:1 to the snapshot's five_hour / seven_day bars.
 *   - Standard plans: `balance_usd` / `allowance_usd` / `period` monthly
 *     credits. No 5h/weekly windows exist, so the bars are written as null and
 *     only the balance label is populated.
 * `purchased.balance_usd` (remaining unexpired purchased credits) applies to
 * both shapes and feeds the snapshot's `balance_label`.
 *
 * Snapshot format (claude-hud external-usage):
 *   { updated_at, five_hour: { used_percentage, resets_at? },
 *     seven_day: { used_percentage, resets_at? }, balance_label? }
 *
 * Usage:
 *   node ollama-usage-poller.mjs [--out <path>] [--once]
 *   --out   snapshot file path (default: ~/.claude/plugins/claude-hud/ollama-usage.json)
 *   --once  fetch once and exit (default: poll every 5 minutes)
 */
import * as crypto from 'node:crypto';
import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';

const OLLAMA_COM = 'https://ollama.com';
const POLL_INTERVAL_MS = 5 * 60 * 1000; // 5 minutes
const DEFAULT_OUT = path.join(
  os.homedir(),
  '.claude',
  'plugins',
  'claude-hud',
  'ollama-usage.json',
);

// ---------------------------------------------------------------------------
// OpenSSH private key parsing (ed25519)
// ---------------------------------------------------------------------------

function readUint32(buf, offset) {
  return buf.readUInt32BE(offset);
}

function readString(buf, offset) {
  const len = readUint32(buf, offset);
  const start = offset + 4;
  return { value: buf.subarray(start, start + len), next: start + len };
}

/**
 * Parses an OpenSSH-format ed25519 private key file.
 * Returns { seed, pubkey } where seed is the 32-byte signing seed and pubkey
 * is the 32-byte raw public key.
 */
export function parseOpenSSHPrivateKey(pem) {
  const b64 = pem
    .replace(/-----BEGIN OPENSSH PRIVATE KEY-----/g, '')
    .replace(/-----END OPENSSH PRIVATE KEY-----/g, '')
    .replace(/\s+/g, '');
  const blob = Buffer.from(b64, 'base64');

  if (blob.subarray(0, 14).toString('utf8') !== 'openssh-key-v1' || blob[14] !== 0) {
    throw new Error('not an OpenSSH private key (bad magic)');
  }

  let off = 15;
  const cipher = readString(blob, off);
  off = cipher.next;
  const kdf = readString(blob, off);
  off = kdf.next;
  const kdfOpts = readString(blob, off);
  off = kdfOpts.next;

  if (cipher.value.toString('utf8') !== 'none' || kdf.value.toString('utf8') !== 'none') {
    throw new Error('encrypted OpenSSH keys are not supported');
  }

  const nkeys = readUint32(blob, off);
  off += 4;
  if (nkeys !== 1) {
    throw new Error(`unexpected key count: ${nkeys}`);
  }

  const pubBlob = readString(blob, off);
  off = pubBlob.next;
  const privBlobStr = readString(blob, off);
  off = privBlobStr.next;
  const privBlob = privBlobStr.value;

  // Private key blob: checkint(4) checkint(4) keytype(string) pubkey(string)
  // privkey(string) comment(string) padding
  let p = 0;
  const check1 = readUint32(privBlob, p);
  p += 4;
  const check2 = readUint32(privBlob, p);
  p += 4;
  if (check1 !== check2) {
    throw new Error('key checkints do not match (corrupt key)');
  }

  const keyType = readString(privBlob, p);
  p = keyType.next;
  if (keyType.value.toString('utf8') !== 'ssh-ed25519') {
    throw new Error(`unsupported key type: ${keyType.value.toString('utf8')}`);
  }

  const pub = readString(privBlob, p);
  p = pub.next;
  const priv = readString(privBlob, p);

  if (pub.value.length !== 32) {
    throw new Error(`unexpected public key length: ${pub.value.length}`);
  }
  if (priv.value.length !== 64) {
    throw new Error(`unexpected private key length: ${priv.value.length}`);
  }

  return { seed: priv.value.subarray(0, 32), pubkey: pub.value };
}

// ---------------------------------------------------------------------------
// Ollama cloud auth (challenge-response, same as the Ollama server)
// ---------------------------------------------------------------------------

export function buildKeyObject(seed, pubkey) {
  return crypto.createPrivateKey({
    key: {
      kty: 'OKP',
      crv: 'Ed25519',
      d: seed.toString('base64url'),
      x: pubkey.toString('base64url'),
    },
    format: 'jwk',
  });
}

function signChallenge(keyObject, method, apiPath, now) {
  const chal = `${method},${apiPath}?ts=${now}`;
  const sig = crypto.sign(null, Buffer.from(chal, 'utf8'), keyObject);
  return sig;
}

export function pubkeyBlobBase64(pubkey) {
  // Public key blob: string("ssh-ed25519") + string(32-byte key)
  const type = Buffer.from('ssh-ed25519', 'utf8');
  const blob = Buffer.alloc(4 + type.length + 4 + pubkey.length);
  blob.writeUInt32BE(type.length, 0);
  type.copy(blob, 4);
  blob.writeUInt32BE(pubkey.length, 4 + type.length);
  pubkey.copy(blob, 4 + type.length + 4);
  return blob.toString('base64');
}

export async function ollamaRequest(keyObject, pubkeyB64, method, apiPath) {
  const now = Math.floor(Date.now() / 1000).toString();
  const sig = signChallenge(keyObject, method, apiPath, now);
  const auth = `${pubkeyB64}:${sig.toString('base64')}`;
  const url = `${OLLAMA_COM}${apiPath}?ts=${now}`;

  const res = await fetch(url, {
    method,
    headers: {
      Authorization: auth,
      'Content-Type': 'application/json',
      Accept: 'application/json',
      'User-Agent': 'ollama-usage-poller/1.0',
    },
  });

  const text = await res.text();
  if (!res.ok) {
    throw new Error(`ollama.com ${method} ${apiPath} -> ${res.status}: ${text.slice(0, 200)}`);
  }
  return text ? JSON.parse(text) : null;
}

// ---------------------------------------------------------------------------
// Snapshot building
// ---------------------------------------------------------------------------

/** `remaining_percent` is quota REMAINING (0-100); the snapshot wants used, 2 decimals. */
function usedFromRemaining(remaining) {
  const n = typeof remaining === 'number'
    ? remaining
    : (typeof remaining === 'string' && remaining.trim() !== '' ? Number(remaining.trim()) : NaN);
  if (!Number.isFinite(n)) return null;
  const used = 100 - n;
  return Number(Math.min(100, Math.max(0, used)).toFixed(2));
}

function usd(value) {
  const n = typeof value === 'number' ? value : Number(value);
  return Number.isFinite(n) ? `$${n.toFixed(2)}` : null;
}

/**
 * Ollama Cloud resets are globally synchronized (same for every user):
 *   - session limits reset every 5 hours, aligned to Unix epoch multiples of 18000s
 *   - weekly limits reset every 7 days, aligned to epoch + 4 days (Monday 00:00 UTC)
 * Source: ollama.com/pricing + ollama/ollama#12532. Only a stand-in: the API's
 * own `resets_at` always wins.
 */
function nextSessionReset(nowSec) {
  return nowSec + (18000 - (nowSec % 18000));
}

function nextWeeklyReset(nowSec) {
  return nowSec + (604800 - ((nowSec - 345600) % 604800));
}

function windowEntry(shape, fallbackReset) {
  const used = usedFromRemaining(shape?.remaining_percent);
  if (used === null && shape?.resets_at == null) return null;
  const resetAt = shape?.resets_at ?? fallbackReset;
  return {
    used_percentage: used,
    ...(resetAt != null && { resets_at: resetAt }),
  };
}

function buildSnapshot(balance) {
  const included = balance?.included ?? {};
  const session = included.session ?? {};
  const weekly = included.weekly ?? {};
  const nowSec = Math.floor(Date.now() / 1000);

  const fiveHour = windowEntry(session, new Date(nextSessionReset(nowSec) * 1000).toISOString());
  const sevenDay = windowEntry(weekly, new Date(nextWeeklyReset(nowSec) * 1000).toISOString());

  const includedUsd = usd(included.balance_usd);
  const allowanceUsd = usd(included.allowance_usd);
  const purchasedUsd = usd(balance?.purchased?.balance_usd);

  let label;
  if (includedUsd != null && allowanceUsd != null) {
    label = `Cr: ${includedUsd}/${allowanceUsd}${purchasedUsd != null ? ` +${purchasedUsd}` : ''}`;
  } else if (purchasedUsd != null) {
    label = `Xtr: ${purchasedUsd} left`;
  }

  return {
    updated_at: new Date().toISOString(),
    five_hour: { used_percentage: fiveHour?.used_percentage ?? null, ...(fiveHour?.resets_at != null && { resets_at: fiveHour.resets_at }) },
    seven_day: { used_percentage: sevenDay?.used_percentage ?? null, ...(sevenDay?.resets_at != null && { resets_at: sevenDay.resets_at }) },
    ...(label && { balance_label: label }),
  };
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

function parseArgs(argv) {
  const args = { out: DEFAULT_OUT, once: false };
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--out' && argv[i + 1]) {
      args.out = path.resolve(argv[++i]);
    } else if (argv[i] === '--once') {
      args.once = true;
    }
  }
  return args;
}

async function runOnce(outPath) {
  const keyPath = path.join(os.homedir(), '.ollama', 'id_ed25519');
  const pem = fs.readFileSync(keyPath, 'utf8');
  const { seed, pubkey } = parseOpenSSHPrivateKey(pem);
  const keyObject = buildKeyObject(seed, pubkey);
  const pubkeyB64 = pubkeyBlobBase64(pubkey);

  const balance = await ollamaRequest(keyObject, pubkeyB64, 'GET', '/api/balance');
  const snapshot = buildSnapshot(balance);
  const tmp = `${outPath}.${process.pid}.tmp`;
  fs.writeFileSync(tmp, `${JSON.stringify(snapshot, null, 2)}\n`, { encoding: 'utf8', mode: 0o600 });
  fs.renameSync(tmp, outPath);
  fs.chmodSync(outPath, 0o600);
  return snapshot;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const outDir = path.dirname(args.out);
  if (!fs.existsSync(outDir)) {
    fs.mkdirSync(outDir, { recursive: true });
  }

  if (args.once) {
    const snap = await runOnce(args.out);
    console.log(`wrote ${args.out}`);
    console.log(JSON.stringify(snap, null, 2));
    return;
  }

  console.log(`polling every ${POLL_INTERVAL_MS / 60000} min -> ${args.out}`);
  for (;;) {
    try {
      const snap = await runOnce(args.out);
      console.log(`[${new Date().toISOString()}] 5h:${snap.five_hour.used_percentage}% 7d:${snap.seven_day.used_percentage}% ${snap.balance_label ?? ''}`);
    } catch (err) {
      console.error(`[${new Date().toISOString()}] poll failed:`, err.message);
    }
    await new Promise((r) => setTimeout(r, POLL_INTERVAL_MS));
  }
}

const isEntryPoint = process.argv[1]
  && import.meta.url === new URL(`file://${process.argv[1].replace(/\\/g, '/')}`).href;

if (isEntryPoint) {
  main().catch((err) => {
    console.error('fatal:', err.message);
    process.exit(1);
  });
}

import fs from 'node:fs';
import crypto from 'node:crypto';
import { DatabaseSync } from 'node:sqlite';
import config from './config.js';

fs.mkdirSync(config.DATA_DIR, { recursive: true });
const sqlite = new DatabaseSync(config.DB_PATH, { timeout: 10_000 });
sqlite.exec(`
PRAGMA journal_mode=WAL;
PRAGMA synchronous=FULL;
PRAGMA foreign_keys=ON;
PRAGMA busy_timeout=10000;
PRAGMA wal_autocheckpoint=1000;
`);

sqlite.exec(`
CREATE TABLE IF NOT EXISTS messages (
  id TEXT PRIMARY KEY,
  idempotency_key TEXT UNIQUE,
  recipient TEXT NOT NULL,
  type TEXT NOT NULL,
  payload_json TEXT NOT NULL,
  metadata_json TEXT NOT NULL DEFAULT '{}',
  status TEXT NOT NULL DEFAULT 'queued',
  attempts INTEGER NOT NULL DEFAULT 0,
  scheduled_at INTEGER NOT NULL,
  next_attempt_at INTEGER NOT NULL,
  provider_message_id TEXT,
  error TEXT,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_messages_queue ON messages(status, next_attempt_at, scheduled_at);
CREATE INDEX IF NOT EXISTS idx_messages_provider ON messages(provider_message_id);

CREATE TABLE IF NOT EXISTS events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  message_id TEXT,
  event_type TEXT NOT NULL,
  payload_json TEXT NOT NULL,
  created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_events_message ON events(message_id, created_at DESC);

CREATE TABLE IF NOT EXISTS inbound_messages (
  id TEXT PRIMARY KEY,
  sender TEXT NOT NULL,
  body TEXT NOT NULL,
  has_media INTEGER NOT NULL DEFAULT 0,
  timestamp INTEGER NOT NULL,
  payload_json TEXT NOT NULL,
  created_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS settings (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL,
  updated_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS auth_store (
  bucket TEXT NOT NULL,
  item_key TEXT NOT NULL,
  value TEXT NOT NULL,
  updated_at INTEGER NOT NULL,
  PRIMARY KEY(bucket, item_key)
);

CREATE TABLE IF NOT EXISTS webhook_outbox (
  id TEXT PRIMARY KEY,
  event_type TEXT NOT NULL,
  payload_json TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'queued',
  attempts INTEGER NOT NULL DEFAULT 0,
  next_attempt_at INTEGER NOT NULL,
  lease_until INTEGER,
  error TEXT,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_webhook_queue ON webhook_outbox(status, next_attempt_at);
`);

function ensureColumn(table, column, ddl) {
  const columns = sqlite.prepare(`PRAGMA table_info(${table})`).all().map(row => row.name);
  if (!columns.includes(column)) sqlite.exec(`ALTER TABLE ${table} ADD COLUMN ${column} ${ddl}`);
}

ensureColumn('messages', 'lease_until', 'INTEGER');
ensureColumn('messages', 'provider_message_json', 'TEXT');
ensureColumn('messages', 'uncertain', 'INTEGER NOT NULL DEFAULT 0');

function transaction(callback) {
  sqlite.exec('BEGIN IMMEDIATE;');
  try {
    const result = callback();
    sqlite.exec('COMMIT;');
    return result;
  } catch (error) {
    try { sqlite.exec('ROLLBACK;'); } catch {}
    throw error;
  }
}

const now = () => Date.now();
const parseJson = (value, fallback = {}) => {
  try { return JSON.parse(value); } catch { return fallback; }
};

function rowToMessage(row) {
  if (!row) return null;
  return {
    id: row.id,
    idempotencyKey: row.idempotency_key,
    to: row.recipient,
    type: row.type,
    payload: parseJson(row.payload_json),
    metadata: parseJson(row.metadata_json),
    status: row.status,
    attempts: row.attempts,
    scheduledAt: new Date(row.scheduled_at).toISOString(),
    nextAttemptAt: new Date(row.next_attempt_at).toISOString(),
    leaseUntil: row.lease_until ? new Date(row.lease_until).toISOString() : null,
    providerMessageId: row.provider_message_id,
    providerMessage: parseJson(row.provider_message_json, null),
    uncertain: Boolean(row.uncertain),
    error: row.error,
    createdAt: new Date(row.created_at).toISOString(),
    updatedAt: new Date(row.updated_at).toISOString()
  };
}

export function createMessage({ idempotencyKey, recipient, type, payload, metadata = {}, scheduledAt }) {
  if (stats().active >= config.MAX_QUEUE_DEPTH) throw new Error('Gateway queue capacity reached');
  const id = crypto.randomUUID();
  const ts = now();
  const due = scheduledAt ? new Date(scheduledAt).getTime() : ts;
  if (!Number.isFinite(due)) throw new Error('Invalid scheduledAt');
  try {
    sqlite.prepare(`INSERT INTO messages
      (id,idempotency_key,recipient,type,payload_json,metadata_json,status,attempts,scheduled_at,next_attempt_at,created_at,updated_at)
      VALUES (?,?,?,?,?,?, 'queued',0,?,?,?,?)`)
      .run(id, idempotencyKey || null, recipient, type, JSON.stringify(payload), JSON.stringify(metadata), due, due, ts, ts);
  } catch (error) {
    if (idempotencyKey && String(error.message).includes('UNIQUE')) return getByIdempotencyKey(idempotencyKey);
    throw error;
  }
  return getMessage(id);
}

export function getMessage(id) {
  return rowToMessage(sqlite.prepare('SELECT * FROM messages WHERE id=?').get(id));
}

export function getByIdempotencyKey(key) {
  return rowToMessage(sqlite.prepare('SELECT * FROM messages WHERE idempotency_key=?').get(key));
}

export function listMessages(limit = 100, status = null) {
  const safeLimit = Math.max(1, Math.min(Number(limit) || 100, 500));
  const rows = status
    ? sqlite.prepare('SELECT * FROM messages WHERE status=? ORDER BY created_at DESC LIMIT ?').all(status, safeLimit)
    : sqlite.prepare('SELECT * FROM messages ORDER BY created_at DESC LIMIT ?').all(safeLimit);
  return rows.map(rowToMessage);
}

export function claimNextMessage() {
  const ts = now();
  return transaction(() => {
    const row = sqlite.prepare(`SELECT * FROM messages
      WHERE status IN ('queued','retry') AND scheduled_at<=? AND next_attempt_at<=?
      ORDER BY next_attempt_at ASC, created_at ASC LIMIT 1`).get(ts, ts);
    if (!row) return null;
    const changed = sqlite.prepare(`UPDATE messages
      SET status='sending', attempts=attempts+1, lease_until=?, updated_at=?
      WHERE id=? AND status IN ('queued','retry')`).run(ts + config.LEASE_MS, ts, row.id);
    return changed.changes ? getMessage(row.id) : null;
  });
}

export function ensureProviderMessageId(id, providerMessageId) {
  sqlite.prepare(`UPDATE messages SET provider_message_id=COALESCE(provider_message_id,?), updated_at=? WHERE id=?`)
    .run(providerMessageId, now(), id);
  return getMessage(id).providerMessageId;
}

export function markSubmitted(id, providerMessageId, providerMessage) {
  sqlite.prepare(`UPDATE messages SET status='sent', provider_message_id=?, provider_message_json=?,
    uncertain=0, error=NULL, lease_until=NULL, updated_at=? WHERE id=?`)
    .run(providerMessageId || null, providerMessage ? JSON.stringify(providerMessage) : null, now(), id);
  return getMessage(id);
}

const rank = { queued: 0, retry: 0, sending: 1, sent: 2, delivered: 3, read: 4 };
export function markAck(providerMessageId, status) {
  if (!Object.hasOwn(rank, status)) return null;
  const row = sqlite.prepare('SELECT * FROM messages WHERE provider_message_id=?').get(providerMessageId);
  if (!row) return null;
  if ((rank[row.status] ?? -1) > rank[status]) return rowToMessage(row);
  sqlite.prepare('UPDATE messages SET status=?, error=NULL, uncertain=0, lease_until=NULL, updated_at=? WHERE id=?')
    .run(status, now(), row.id);
  return getMessage(row.id);
}

export function markFailure(id, error, { uncertain = false, retryable = true } = {}) {
  const row = sqlite.prepare('SELECT attempts FROM messages WHERE id=?').get(id);
  if (!row) return null;
  const terminal = !retryable || row.attempts >= config.MAX_ATTEMPTS;
  const base = Math.min(30 * 60 * 1000, 30_000 * Math.pow(2, Math.max(0, row.attempts - 1)));
  const jitter = Math.floor(Math.random() * Math.min(15_000, base / 4));
  sqlite.prepare(`UPDATE messages SET status=?, error=?, uncertain=?, next_attempt_at=?, lease_until=NULL, updated_at=? WHERE id=?`)
    .run(terminal ? 'failed' : 'retry', String(error).slice(0, 2000), uncertain ? 1 : 0, now() + base + jitter, now(), id);
  return getMessage(id);
}

export function retryMessage(id) {
  const result = sqlite.prepare(`UPDATE messages SET status='retry', attempts=0, error=NULL,
    uncertain=0, next_attempt_at=?, lease_until=NULL, updated_at=? WHERE id=? AND status='failed'`)
    .run(now(), now(), id);
  return result.changes ? getMessage(id) : null;
}

export function requeueExpiredLeases() {
  const ts = now();
  return sqlite.prepare(`UPDATE messages SET status='retry', next_attempt_at=?, lease_until=NULL,
    uncertain=1, error='Recovered expired send lease; deterministic provider ID retained', updated_at=?
    WHERE status='sending' AND (lease_until IS NULL OR lease_until<?)`)
    .run(ts, ts, ts).changes;
}

export function findProviderMessage(providerMessageId) {
  const row = sqlite.prepare('SELECT provider_message_json FROM messages WHERE provider_message_id=?').get(providerMessageId);
  return row?.provider_message_json ? parseJson(row.provider_message_json, null) : null;
}

export function addEvent(messageId, eventType, payload) {
  sqlite.prepare('INSERT INTO events(message_id,event_type,payload_json,created_at) VALUES (?,?,?,?)')
    .run(messageId || null, eventType, JSON.stringify(payload || {}), now());
}

export function addInbound({ id, sender, body, hasMedia, timestamp, payload }) {
  sqlite.prepare(`INSERT OR IGNORE INTO inbound_messages(id,sender,body,has_media,timestamp,payload_json,created_at)
    VALUES (?,?,?,?,?,?,?)`).run(id, sender, body || '', hasMedia ? 1 : 0, timestamp, JSON.stringify(payload || {}), now());
}

export function listInbound(limit = 100) {
  return sqlite.prepare('SELECT * FROM inbound_messages ORDER BY timestamp DESC LIMIT ?').all(Math.min(Number(limit) || 100, 500)).map(row => ({
    id: row.id,
    sender: row.sender,
    body: row.body,
    hasMedia: Boolean(row.has_media),
    timestamp: new Date(row.timestamp).toISOString(),
    createdAt: new Date(row.created_at).toISOString()
  }));
}

export function stats() {
  const result = Object.fromEntries(sqlite.prepare('SELECT status,COUNT(*) count FROM messages GROUP BY status').all().map(row => [row.status, row.count]));
  result.active = (result.queued || 0) + (result.retry || 0) + (result.sending || 0);
  return result;
}

export function setSetting(key, value) {
  sqlite.prepare(`INSERT INTO settings(key,value,updated_at) VALUES (?,?,?)
    ON CONFLICT(key) DO UPDATE SET value=excluded.value,updated_at=excluded.updated_at`).run(key, String(value), now());
}

export function getSetting(key) {
  return sqlite.prepare('SELECT value FROM settings WHERE key=?').get(key)?.value || null;
}

export function authGet(bucket, itemKey) {
  return sqlite.prepare('SELECT value FROM auth_store WHERE bucket=? AND item_key=?').get(bucket, itemKey)?.value || null;
}

export function authSet(bucket, itemKey, value) {
  sqlite.prepare(`INSERT INTO auth_store(bucket,item_key,value,updated_at) VALUES (?,?,?,?)
    ON CONFLICT(bucket,item_key) DO UPDATE SET value=excluded.value,updated_at=excluded.updated_at`)
    .run(bucket, itemKey, value, now());
}

export function authSetMany(records) {
  transaction(() => {
    const statement = sqlite.prepare(`INSERT INTO auth_store(bucket,item_key,value,updated_at) VALUES (?,?,?,?)
      ON CONFLICT(bucket,item_key) DO UPDATE SET value=excluded.value,updated_at=excluded.updated_at`);
    const ts = now();
    for (const item of records) {
      if (item.value === null || item.value === undefined) {
        sqlite.prepare('DELETE FROM auth_store WHERE bucket=? AND item_key=?').run(item.bucket, item.itemKey);
      } else {
        statement.run(item.bucket, item.itemKey, item.value, ts);
      }
    }
  });
}

export function authClear() {
  sqlite.prepare('DELETE FROM auth_store').run();
}

export function enqueueWebhook(eventType, payload) {
  if (!config.WEBHOOK_URL) return;
  const id = crypto.randomUUID();
  const ts = now();
  sqlite.prepare(`INSERT INTO webhook_outbox(id,event_type,payload_json,status,attempts,next_attempt_at,created_at,updated_at)
    VALUES (?,?,?,'queued',0,?,?,?)`).run(id, eventType, JSON.stringify(payload || {}), ts, ts, ts);
}

export function claimWebhook() {
  const ts = now();
  return transaction(() => {
    sqlite.prepare(`UPDATE webhook_outbox SET status='retry',lease_until=NULL,next_attempt_at=?,updated_at=?
      WHERE status='sending' AND lease_until<?`).run(ts, ts, ts);
    const row = sqlite.prepare(`SELECT * FROM webhook_outbox WHERE status IN ('queued','retry') AND next_attempt_at<=?
      ORDER BY created_at ASC LIMIT 1`).get(ts);
    if (!row) return null;
    const changed = sqlite.prepare(`UPDATE webhook_outbox SET status='sending',attempts=attempts+1,lease_until=?,updated_at=?
      WHERE id=? AND status IN ('queued','retry')`).run(ts + 60_000, ts, row.id);
    if (!changed.changes) return null;
    return { ...row, payload: parseJson(row.payload_json) };
  });
}

export function markWebhookSent(id) {
  sqlite.prepare(`UPDATE webhook_outbox SET status='sent',error=NULL,lease_until=NULL,updated_at=? WHERE id=?`).run(now(), id);
}

export function markWebhookFailure(id, error) {
  const row = sqlite.prepare('SELECT attempts FROM webhook_outbox WHERE id=?').get(id);
  if (!row) return;
  const terminal = row.attempts >= 10;
  const delay = Math.min(60 * 60 * 1000, 30_000 * Math.pow(2, Math.max(0, row.attempts - 1)));
  sqlite.prepare(`UPDATE webhook_outbox SET status=?,error=?,next_attempt_at=?,lease_until=NULL,updated_at=? WHERE id=?`)
    .run(terminal ? 'failed' : 'retry', String(error).slice(0, 2000), now() + delay, now(), id);
}

export function healthCheck() {
  return sqlite.prepare('SELECT 1 ok').get().ok === 1;
}

export function closeDatabase() {
  sqlite.exec('PRAGMA wal_checkpoint(TRUNCATE);');
  sqlite.close();
}

export { sqlite };

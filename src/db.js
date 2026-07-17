const Database = require('better-sqlite3');
const fs = require('node:fs');
const crypto = require('node:crypto');
const config = require('./config');

fs.mkdirSync(config.DATA_DIR, { recursive: true });
const db = new Database(config.DB_PATH);
db.pragma('journal_mode = WAL');
db.pragma('synchronous = NORMAL');
db.pragma('foreign_keys = ON');
db.pragma('busy_timeout = 5000');

db.exec(`
CREATE TABLE IF NOT EXISTS messages (
  id TEXT PRIMARY KEY,
  idempotency_key TEXT UNIQUE,
  recipient TEXT NOT NULL,
  type TEXT NOT NULL CHECK(type IN ('text','media')),
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
CREATE INDEX IF NOT EXISTS idx_messages_provider_id ON messages(provider_message_id);

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
`);

const now = () => Date.now();
const rowToMessage = row => row ? ({
  id: row.id,
  idempotencyKey: row.idempotency_key,
  to: row.recipient,
  type: row.type,
  payload: JSON.parse(row.payload_json),
  metadata: JSON.parse(row.metadata_json || '{}'),
  status: row.status,
  attempts: row.attempts,
  scheduledAt: new Date(row.scheduled_at).toISOString(),
  nextAttemptAt: new Date(row.next_attempt_at).toISOString(),
  providerMessageId: row.provider_message_id,
  error: row.error,
  createdAt: new Date(row.created_at).toISOString(),
  updatedAt: new Date(row.updated_at).toISOString()
}) : null;

function createMessage({ idempotencyKey, recipient, type, payload, metadata = {}, scheduledAt }) {
  const id = crypto.randomUUID();
  const ts = now();
  const due = scheduledAt ? new Date(scheduledAt).getTime() : ts;
  try {
    db.prepare(`INSERT INTO messages
      (id,idempotency_key,recipient,type,payload_json,metadata_json,status,attempts,scheduled_at,next_attempt_at,created_at,updated_at)
      VALUES (?,?,?,?,?,?, 'queued',0,?,?,?,?)`)
      .run(id, idempotencyKey || null, recipient, type, JSON.stringify(payload), JSON.stringify(metadata), due, due, ts, ts);
    return getMessage(id);
  } catch (error) {
    if (idempotencyKey && String(error.message).includes('UNIQUE')) {
      return getByIdempotencyKey(idempotencyKey);
    }
    throw error;
  }
}

function getMessage(id) {
  return rowToMessage(db.prepare('SELECT * FROM messages WHERE id = ?').get(id));
}
function getByIdempotencyKey(key) {
  return rowToMessage(db.prepare('SELECT * FROM messages WHERE idempotency_key = ?').get(key));
}
function listMessages(limit = 100, status = null) {
  const rows = status
    ? db.prepare('SELECT * FROM messages WHERE status = ? ORDER BY created_at DESC LIMIT ?').all(status, limit)
    : db.prepare('SELECT * FROM messages ORDER BY created_at DESC LIMIT ?').all(limit);
  return rows.map(rowToMessage);
}
function claimNextMessage() {
  const ts = now();
  const tx = db.transaction(() => {
    const row = db.prepare(`SELECT * FROM messages
      WHERE status IN ('queued','retry') AND scheduled_at <= ? AND next_attempt_at <= ?
      ORDER BY next_attempt_at ASC, created_at ASC LIMIT 1`).get(ts, ts);
    if (!row) return null;
    const changed = db.prepare(`UPDATE messages SET status='sending', attempts=attempts+1, updated_at=?
      WHERE id=? AND status IN ('queued','retry')`).run(ts, row.id);
    return changed.changes ? getMessage(row.id) : null;
  });
  return tx();
}
function markSent(id, providerMessageId) {
  db.prepare(`UPDATE messages SET status='sent', provider_message_id=?, error=NULL, updated_at=? WHERE id=?`)
    .run(providerMessageId || null, now(), id);
  return getMessage(id);
}
function markAck(providerMessageId, status) {
  const allowedCurrent = {
    sent: ['sending', 'sent'],
    delivered: ['sending', 'sent', 'delivered'],
    read: ['sending', 'sent', 'delivered', 'read']
  }[status] || [];
  if (allowedCurrent.length) {
    const placeholders = allowedCurrent.map(() => '?').join(',');
    db.prepare(`UPDATE messages SET status=?, updated_at=? WHERE provider_message_id=? AND status IN (${placeholders})`)
      .run(status, now(), providerMessageId, ...allowedCurrent);
  }
  return db.prepare('SELECT id FROM messages WHERE provider_message_id=?').get(providerMessageId)?.id || null;
}
function markFailure(id, error, maxAttempts) {
  const row = db.prepare('SELECT attempts FROM messages WHERE id=?').get(id);
  if (!row) return null;
  const terminal = row.attempts >= maxAttempts;
  const delay = Math.min(30 * 60 * 1000, Math.pow(2, Math.max(0, row.attempts - 1)) * 60 * 1000);
  db.prepare(`UPDATE messages SET status=?, error=?, next_attempt_at=?, updated_at=? WHERE id=?`)
    .run(terminal ? 'failed' : 'retry', String(error).slice(0, 2000), now() + delay, now(), id);
  return getMessage(id);
}
function retryMessage(id) {
  const result = db.prepare(`UPDATE messages
    SET status='retry', attempts=0, error=NULL, next_attempt_at=?, updated_at=?
    WHERE id=? AND status='failed'`).run(now(), now(), id);
  return result.changes ? getMessage(id) : null;
}

function resetStuckMessages() {
  const cutoff = now() - 15 * 60 * 1000;
  return db.prepare(`UPDATE messages SET status='retry', next_attempt_at=?, error='Recovered after interrupted send', updated_at=?
    WHERE status='sending' AND updated_at < ?`).run(now(), now(), cutoff).changes;
}
function addEvent(messageId, eventType, payload) {
  db.prepare('INSERT INTO events(message_id,event_type,payload_json,created_at) VALUES (?,?,?,?)')
    .run(messageId || null, eventType, JSON.stringify(payload || {}), now());
}
function addInbound({ id, sender, body, hasMedia, timestamp, payload }) {
  db.prepare(`INSERT OR IGNORE INTO inbound_messages(id,sender,body,has_media,timestamp,payload_json,created_at)
    VALUES (?,?,?,?,?,?,?)`).run(id, sender, body || '', hasMedia ? 1 : 0, timestamp, JSON.stringify(payload || {}), now());
}
function listInbound(limit = 100) {
  return db.prepare('SELECT * FROM inbound_messages ORDER BY timestamp DESC LIMIT ?').all(limit).map(row => ({
    id: row.id, sender: row.sender, body: row.body, hasMedia: Boolean(row.has_media),
    timestamp: new Date(row.timestamp).toISOString(), createdAt: new Date(row.created_at).toISOString()
  }));
}
function stats() {
  const rows = db.prepare('SELECT status, COUNT(*) count FROM messages GROUP BY status').all();
  return Object.fromEntries(rows.map(r => [r.status, r.count]));
}
function setSetting(key, value) {
  db.prepare(`INSERT INTO settings(key,value,updated_at) VALUES (?,?,?)
    ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=excluded.updated_at`).run(key, value, now());
}
function getSetting(key) {
  return db.prepare('SELECT value FROM settings WHERE key=?').get(key)?.value || null;
}

module.exports = {
  db, createMessage, getMessage, getByIdempotencyKey, listMessages, claimNextMessage,
  markSent, markAck, markFailure, retryMessage, resetStuckMessages, addEvent, addInbound, listInbound,
  stats, setSetting, getSetting
};

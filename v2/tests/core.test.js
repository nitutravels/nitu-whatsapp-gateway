import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';

const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'nitu-wa-v2-'));
process.env.DATA_DIR = temp;
process.env.API_KEY = 'a'.repeat(32);
process.env.ADMIN_TOKEN = 'b'.repeat(32);
process.env.WEBHOOK_SECRET = 'c'.repeat(32);
process.env.MEDIA_ALLOWED_HOSTS = 'example.com';

const cryptoModule = await import('../src/crypto.js');
const db = await import('../src/db.js');

process.on('exit', () => {
  try { db.closeDatabase(); } catch {}
  fs.rmSync(temp, { recursive: true, force: true });
});

test('encrypted values round trip and reject tampering', () => {
  const encrypted = cryptoModule.encryptString('sensitive-auth-state');
  assert.match(encrypted, /^v1:/);
  assert.equal(cryptoModule.decryptString(encrypted), 'sensitive-auth-state');
  const tampered = `${encrypted.slice(0, -2)}AA`;
  assert.throws(() => cryptoModule.decryptString(tampered));
});

test('idempotency returns the original message', () => {
  const first = db.createMessage({ idempotencyKey: 'duty-123', recipient: '919999999999', type: 'text', payload: { text: 'one' } });
  const second = db.createMessage({ idempotencyKey: 'duty-123', recipient: '919999999999', type: 'text', payload: { text: 'two' } });
  assert.equal(first.id, second.id);
  assert.equal(second.payload.text, 'one');
  const claimed = db.claimNextMessage();
  db.ensureProviderMessageId(claimed.id, 'IDEMPOTENT-1');
  db.markSubmitted(claimed.id, 'IDEMPOTENT-1', { key: { id: 'IDEMPOTENT-1' }, message: { conversation: 'one' } });
});

test('queue lease, deterministic ID and status ordering are durable', () => {
  const created = db.createMessage({ recipient: '919888888888', type: 'text', payload: { text: 'hello' } });
  const claimed = db.claimNextMessage();
  assert.equal(claimed.id, created.id);
  assert.equal(claimed.status, 'sending');
  assert.equal(db.ensureProviderMessageId(created.id, 'PROVIDER-1'), 'PROVIDER-1');
  db.markSubmitted(created.id, 'PROVIDER-1', { key: { id: 'PROVIDER-1' }, message: { conversation: 'hello' } });
  assert.equal(db.markAck('PROVIDER-1', 'delivered').status, 'delivered');
  assert.equal(db.markAck('PROVIDER-1', 'sent').status, 'delivered');
  assert.equal(db.markAck('PROVIDER-1', 'read').status, 'read');
});

test('failed messages can be manually retried', () => {
  const created = db.createMessage({ recipient: '919777777777', type: 'text', payload: { text: 'retry' } });
  const claimed = db.claimNextMessage();
  assert.equal(claimed.id, created.id);
  let record;
  for (let index = 0; index < 5; index += 1) {
    record = db.markFailure(created.id, 'permanent', { retryable: false });
  }
  assert.equal(record.status, 'failed');
  assert.equal(db.retryMessage(created.id).status, 'retry');
});

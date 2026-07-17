'use strict';

process.env.API_KEY = 'a'.repeat(64);
process.env.ADMIN_TOKEN = 'b'.repeat(64);
process.env.WEBHOOK_SECRET = 'c'.repeat(64);
process.env.DATA_DIR = '/tmp/nitu-wa-test';
process.env.DEFAULT_COUNTRY_CODE = '91';

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const { normalizePhone, signPayload } = require('../src/security');

test('normalizes a ten-digit Indian phone number', () => {
  assert.equal(normalizePhone('98100 00000'), '919810000000@c.us');
});

test('keeps an international number', () => {
  assert.equal(normalizePhone('+44 7700 900123'), '447700900123@c.us');
});

test('rejects an invalid recipient', () => {
  assert.throws(() => normalizePhone('123'), /8-15 digits/);
});

test('signs webhook body with configured HMAC secret', () => {
  const body = '{"event":"message.sent"}';
  const expected = `sha256=${crypto.createHmac('sha256', 'c'.repeat(64)).update(body).digest('hex')}`;
  assert.equal(signPayload(body), expected);
});

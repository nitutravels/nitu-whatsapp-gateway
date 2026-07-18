import crypto from 'node:crypto';
import config from './config.js';

const source = config.AUTH_ENCRYPTION_KEY || `${config.WEBHOOK_SECRET}:${config.ADMIN_TOKEN}:${config.API_KEY}`;
const key = crypto.createHash('sha256').update(source).digest();

export function encryptString(plaintext) {
  const iv = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv('aes-256-gcm', key, iv);
  const encrypted = Buffer.concat([cipher.update(String(plaintext), 'utf8'), cipher.final()]);
  const tag = cipher.getAuthTag();
  return `v1:${iv.toString('base64')}:${tag.toString('base64')}:${encrypted.toString('base64')}`;
}

export function decryptString(value) {
  const input = String(value || '');
  if (!input.startsWith('v1:')) return input;
  const [, iv64, tag64, data64] = input.split(':');
  if (!iv64 || !tag64 || !data64) throw new Error('Invalid encrypted value');
  const decipher = crypto.createDecipheriv('aes-256-gcm', key, Buffer.from(iv64, 'base64'));
  decipher.setAuthTag(Buffer.from(tag64, 'base64'));
  return Buffer.concat([decipher.update(Buffer.from(data64, 'base64')), decipher.final()]).toString('utf8');
}

export function signPayload(body) {
  return crypto.createHmac('sha256', config.WEBHOOK_SECRET).update(body).digest('hex');
}

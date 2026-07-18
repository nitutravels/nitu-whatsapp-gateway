import crypto from 'node:crypto';
import dns from 'node:dns/promises';
import net from 'node:net';
import config from './config.js';
import { signPayload } from './crypto.js';

function timingSafeMatch(actual, expected) {
  const a = Buffer.from(String(actual || ''));
  const b = Buffer.from(String(expected || ''));
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}

export async function requireApiKey(request, reply) {
  const presented = request.headers['x-api-key'] || String(request.headers.authorization || '').replace(/^Bearer\s+/i, '');
  if (!timingSafeMatch(presented, config.API_KEY)) return reply.code(401).send({ error: 'Unauthorized' });
}

export async function requireAdmin(request, reply) {
  const presented = String(request.headers.authorization || '').replace(/^Bearer\s+/i, '');
  if (!timingSafeMatch(presented, config.ADMIN_TOKEN)) return reply.code(401).send({ error: 'Unauthorized' });
}

export function normalizePhone(value) {
  let digits = String(value || '').replace(/\D/g, '');
  if (digits.length === 10) digits = `${config.DEFAULT_COUNTRY_CODE}${digits}`;
  if (!/^\d{8,15}$/.test(digits)) throw new Error('Use a valid mobile number with country code');
  return digits;
}

function isPrivateAddress(address) {
  if (net.isIPv4(address)) {
    const parts = address.split('.').map(Number);
    return parts[0] === 10 || parts[0] === 127 || parts[0] === 0 ||
      (parts[0] === 169 && parts[1] === 254) ||
      (parts[0] === 172 && parts[1] >= 16 && parts[1] <= 31) ||
      (parts[0] === 192 && parts[1] === 168) ||
      (parts[0] === 100 && parts[1] >= 64 && parts[1] <= 127) ||
      parts[0] >= 224;
  }
  if (net.isIPv6(address)) {
    const normalized = address.toLowerCase();
    return normalized === '::1' || normalized === '::' || normalized.startsWith('fc') ||
      normalized.startsWith('fd') || normalized.startsWith('fe8') || normalized.startsWith('fe9') ||
      normalized.startsWith('fea') || normalized.startsWith('feb');
  }
  return true;
}

export async function validateMediaUrl(value) {
  const url = new URL(value);
  if (url.protocol !== 'https:') throw new Error('Media URL must use HTTPS');
  const hostname = url.hostname.toLowerCase();
  if (config.MEDIA_ALLOWED_HOSTS_SET.size && !config.MEDIA_ALLOWED_HOSTS_SET.has(hostname)) {
    throw new Error('Media host is not allowlisted');
  }
  const addresses = await dns.lookup(hostname, { all: true, verbatim: true });
  if (!addresses.length || addresses.some(item => isPrivateAddress(item.address))) {
    throw new Error('Media URL resolves to a private or unsafe address');
  }
  return url.toString();
}

export { signPayload };

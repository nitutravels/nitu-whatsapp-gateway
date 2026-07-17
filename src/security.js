const crypto = require('node:crypto');
const dns = require('node:dns').promises;
const net = require('node:net');
const config = require('./config');

function timingSafeEqualText(a, b) {
  const aa = Buffer.from(String(a || ''));
  const bb = Buffer.from(String(b || ''));
  if (aa.length !== bb.length) return false;
  return crypto.timingSafeEqual(aa, bb);
}
function getBearer(request) {
  const value = request.headers.authorization || '';
  return value.startsWith('Bearer ') ? value.slice(7) : '';
}
function requireApiKey(request, reply, done) {
  const supplied = request.headers['x-api-key'] || getBearer(request);
  if (!timingSafeEqualText(supplied, config.API_KEY)) return reply.code(401).send({ error: 'Unauthorized' });
  done();
}
function requireAdmin(request, reply, done) {
  if (!timingSafeEqualText(getBearer(request), config.ADMIN_TOKEN)) return reply.code(401).send({ error: 'Unauthorized' });
  done();
}
function normalizePhone(input) {
  let digits = String(input || '').replace(/\D/g, '');
  if (digits.length === 10) digits = config.DEFAULT_COUNTRY_CODE + digits;
  if (!/^\d{8,15}$/.test(digits)) throw new Error('Recipient must contain 8-15 digits including country code');
  return `${digits}@c.us`;
}
function isPrivateIp(ip) {
  if (net.isIP(ip) === 4) {
    const [a,b] = ip.split('.').map(Number);
    return a === 10 || a === 127 || a === 0 || (a === 169 && b === 254) || (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168);
  }
  if (net.isIP(ip) === 6) return ip === '::1' || ip.startsWith('fc') || ip.startsWith('fd') || ip.startsWith('fe80:');
  return true;
}
async function validateMediaUrl(raw) {
  const url = new URL(raw);
  if (url.protocol !== 'https:') throw new Error('Media URL must use HTTPS');
  const host = url.hostname.toLowerCase();
  if (config.MEDIA_ALLOWED_HOSTS_SET.size && !config.MEDIA_ALLOWED_HOSTS_SET.has(host)) {
    throw new Error('Media host is not allow-listed');
  }
  const addresses = await dns.lookup(host, { all: true });
  if (!addresses.length || addresses.some(x => isPrivateIp(x.address))) throw new Error('Media URL resolves to a private or invalid address');
  return url.toString();
}
function signPayload(body) {
  return `sha256=${crypto.createHmac('sha256', config.WEBHOOK_SECRET).update(body).digest('hex')}`;
}
module.exports = { requireApiKey, requireAdmin, normalizePhone, validateMediaUrl, signPayload };

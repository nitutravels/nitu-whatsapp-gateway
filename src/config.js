const path = require('node:path');
const { z } = require('zod');

const schema = z.object({
  PORT: z.coerce.number().int().min(1).max(65535).default(3000),
  DATA_DIR: z.string().default('/data'),
  API_KEY: z.string().min(32),
  ADMIN_TOKEN: z.string().min(32),
  WEBHOOK_URL: z.string().url().or(z.literal('')).default(''),
  WEBHOOK_SECRET: z.string().min(32),
  DEFAULT_COUNTRY_CODE: z.string().regex(/^\d{1,4}$/).default('91'),
  SEND_INTERVAL_MS: z.coerce.number().int().min(5000).max(600000).default(6000),
  MAX_ATTEMPTS: z.coerce.number().int().min(1).max(10).default(3),
  MEDIA_ALLOWED_HOSTS: z.string().default(''),
  PUBLIC_BASE_URL: z.string().url().or(z.literal('')).default(''),
  LOG_LEVEL: z.enum(['fatal', 'error', 'warn', 'info', 'debug', 'trace', 'silent']).default('info'),
  CHROME_PATH: z.string().default('/usr/bin/chromium')
});

const parsed = schema.safeParse(process.env);
if (!parsed.success) {
  console.error('Invalid environment configuration:', parsed.error.flatten().fieldErrors);
  process.exit(1);
}

const env = parsed.data;
module.exports = {
  ...env,
  DB_PATH: path.join(env.DATA_DIR, 'gateway.sqlite'),
  AUTH_PATH: path.join(env.DATA_DIR, 'auth'),
  MEDIA_ALLOWED_HOSTS_SET: new Set(
    env.MEDIA_ALLOWED_HOSTS.split(',').map(v => v.trim().toLowerCase()).filter(Boolean)
  )
};

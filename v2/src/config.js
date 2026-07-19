import path from 'node:path';
import { z } from 'zod';

const schema = z.object({
  PORT: z.coerce.number().int().min(1).max(65535).default(3000),
  DATA_DIR: z.string().default('/data'),
  API_KEY: z.string().min(32),
  ADMIN_TOKEN: z.string().min(32),
  WEBHOOK_URL: z.string().url().or(z.literal('')).default(''),
  WEBHOOK_SECRET: z.string().min(32),
  WEBSITE_WORKER_URL: z.string().url().or(z.literal('')).default(''),
  WEBSITE_WORKER_INTERVAL_MS: z.coerce.number().int().min(60000).max(900000).default(60000),
  AUTH_ENCRYPTION_KEY: z.string().min(32).optional(),
  DEFAULT_COUNTRY_CODE: z.string().regex(/^\d{1,4}$/).default('91'),
  SEND_INTERVAL_MS: z.coerce.number().int().min(2000).max(600000).default(6000),
  MAX_ATTEMPTS: z.coerce.number().int().min(1).max(10).default(5),
  MESSAGE_TIMEOUT_MS: z.coerce.number().int().min(10000).max(180000).default(45000),
  MEDIA_TIMEOUT_MS: z.coerce.number().int().min(15000).max(300000).default(90000),
  LEASE_MS: z.coerce.number().int().min(30000).max(600000).default(120000),
  HEARTBEAT_MS: z.coerce.number().int().min(15000).max(300000).default(45000),
  RECONNECT_BASE_MS: z.coerce.number().int().min(1000).max(60000).default(3000),
  MAX_QUEUE_DEPTH: z.coerce.number().int().min(10).max(100000).default(10000),
  MEDIA_ALLOWED_HOSTS: z.string().default(''),
  PUBLIC_BASE_URL: z.string().url().or(z.literal('')).default(''),
  LOG_LEVEL: z.enum(['fatal', 'error', 'warn', 'info', 'debug', 'trace', 'silent']).default('info')
});

const parsed = schema.safeParse(process.env);
if (!parsed.success) {
  console.error('Invalid environment configuration:', parsed.error.flatten().fieldErrors);
  process.exit(1);
}

const env = parsed.data;
export default Object.freeze({
  ...env,
  DB_PATH: path.join(env.DATA_DIR, 'gateway.sqlite'),
  MEDIA_ALLOWED_HOSTS_SET: new Set(
    env.MEDIA_ALLOWED_HOSTS.split(',').map(value => value.trim().toLowerCase()).filter(Boolean)
  )
});

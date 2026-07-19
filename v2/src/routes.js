import path from 'node:path';
import { fileURLToPath } from 'node:url';
import fastifyStatic from '@fastify/static';
import { z } from 'zod';
import {
  createMessage,
  getMessage,
  healthCheck,
  listInbound,
  listMessages,
  retryMessage,
  stats
} from './db.js';
import { normalizePhone, requireAdmin, requireApiKey, validateMediaUrl } from './security.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const messageSchema = z.object({
  to: z.string().min(8).max(30),
  text: z.string().min(1).max(5000).optional(),
  mediaUrl: z.string().url().optional(),
  mimetype: z.string().max(150).optional(),
  caption: z.string().max(2000).optional(),
  filename: z.string().max(255).optional(),
  asDocument: z.boolean().optional().default(false),
  idempotencyKey: z.string().min(3).max(200).optional(),
  scheduledAt: z.string().datetime({ offset: true }).optional(),
  metadata: z.record(z.string(), z.unknown()).optional().default({})
}).superRefine((value, ctx) => {
  if (!value.text && !value.mediaUrl) ctx.addIssue({ code: 'custom', message: 'text or mediaUrl is required' });
  if (value.text && value.mediaUrl) ctx.addIssue({ code: 'custom', message: 'Send text or media in one request, not both' });
});

function validationError(reply, parsed) {
  return reply.code(400).send({ error: 'Validation failed', details: parsed.error.flatten() });
}

export async function registerRoutes(app, transport, queueWorker) {
  await app.register(fastifyStatic, { root: path.join(__dirname, '..', 'public'), prefix: '/' });

  app.get('/healthz', async (request, reply) => {
    const ok = healthCheck();
    return reply.code(ok ? 200 : 503).send({ ok, service: 'nitu-whatsapp-gateway', engine: 'baileys-websocket', time: new Date().toISOString() });
  });

  app.get('/readyz', async (request, reply) => {
    const ready = transport.isReady();
    const status = transport.status();
    return reply.code(ready ? 200 : 503).send({ ready, status: status.status, phase: status.phase, connected: status.connected, registered: status.registered });
  });

  app.post('/api/v1/messages', { preHandler: requireApiKey }, async (request, reply) => {
    const parsed = messageSchema.safeParse(request.body);
    if (!parsed.success) return validationError(reply, parsed);
    const body = parsed.data;
    let recipient;
    try { recipient = normalizePhone(body.to); } catch (error) { return reply.code(400).send({ error: error.message }); }
    if (body.mediaUrl) {
      try { await validateMediaUrl(body.mediaUrl); } catch (error) { return reply.code(400).send({ error: error.message }); }
    }
    try {
      const record = createMessage({
        idempotencyKey: body.idempotencyKey,
        recipient,
        type: body.mediaUrl ? 'media' : 'text',
        payload: body.mediaUrl
          ? { mediaUrl: body.mediaUrl, mimetype: body.mimetype || '', caption: body.caption || '', filename: body.filename || '', asDocument: body.asDocument }
          : { text: body.text },
        metadata: body.metadata,
        scheduledAt: body.scheduledAt
      });
      return reply.code(202).send(record);
    } catch (error) {
      const code = String(error.message).includes('capacity') ? 503 : 400;
      return reply.code(code).send({ error: error.message });
    }
  });

  app.post('/api/v1/messages/statuses', { preHandler: requireApiKey }, async (request, reply) => {
    const parsed = z.object({ ids: z.array(z.string().uuid()).min(1).max(100) }).safeParse(request.body);
    if (!parsed.success) return reply.code(400).send({ error: 'Provide between 1 and 100 valid message IDs' });
    const messages = parsed.data.ids.map(id => getMessage(id)).filter(Boolean);
    return { messages };
  });

  app.get('/api/v1/messages/:id', { preHandler: requireApiKey }, async (request, reply) => {
    const record = getMessage(request.params.id);
    return record || reply.code(404).send({ error: 'Not found' });
  });

  app.get('/admin/api/status', { preHandler: requireAdmin }, async () => ({ ...transport.status(), worker: queueWorker.status() }));
  app.get('/admin/api/messages', { preHandler: requireAdmin }, async request => listMessages(request.query.limit, request.query.status || null));
  app.get('/admin/api/inbound', { preHandler: requireAdmin }, async request => listInbound(request.query.limit));

  app.post('/admin/api/messages/:id/retry', { preHandler: requireAdmin }, async (request, reply) => {
    const record = retryMessage(request.params.id);
    return record ? reply.code(202).send(record) : reply.code(409).send({ error: 'Only failed messages can be retried' });
  });

  app.post('/admin/api/pair', { preHandler: requireAdmin }, async (request, reply) => {
    const parsed = z.object({ phoneNumber: z.string().min(8).max(30) }).safeParse(request.body);
    if (!parsed.success) return reply.code(400).send({ error: 'Enter the full international phone number' });
    try {
      const pairingCode = await transport.requestPairingCode(parsed.data.phoneNumber);
      return { pairingCode };
    } catch (error) {
      return reply.code(409).send({ error: error.message });
    }
  });

  app.post('/admin/api/reconnect', { preHandler: requireAdmin }, async (request, reply) => {
    transport.forceReconnect('administrator request').catch(error => app.log.error({ err: error }, 'Administrator reconnect failed'));
    return reply.code(202).send({ accepted: true });
  });

  app.post('/admin/api/reset', { preHandler: requireAdmin }, async (request, reply) => {
    transport.resetSession().catch(error => app.log.error({ err: error }, 'Administrator session reset failed'));
    return reply.code(202).send({ accepted: true, destructive: true });
  });

  app.post('/admin/api/logout', { preHandler: requireAdmin }, async (request, reply) => {
    transport.resetSession().catch(error => app.log.error({ err: error }, 'Administrator logout/reset failed'));
    return reply.code(202).send({ accepted: true });
  });

  app.post('/admin/api/test', { preHandler: requireAdmin }, async (request, reply) => {
    const parsed = z.object({ to: z.string().min(8), text: z.string().min(1).max(1000) }).safeParse(request.body);
    if (!parsed.success) return reply.code(400).send({ error: 'Recipient and text are required' });
    let recipient;
    try { recipient = normalizePhone(parsed.data.to); } catch (error) { return reply.code(400).send({ error: error.message }); }
    const record = createMessage({ recipient, type: 'text', payload: { text: parsed.data.text }, metadata: { source: 'admin-test' } });
    return reply.code(202).send(record);
  });

  app.get('/admin/api/metrics', { preHandler: requireAdmin }, async () => ({ transport: transport.status(), worker: queueWorker.status(), queue: stats() }));
  app.get('/', async (request, reply) => reply.sendFile('index.html'));
  app.get('/admin', async (request, reply) => reply.sendFile('index.html'));
}

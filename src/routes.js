const path = require('node:path');
const { z } = require('zod');
const fastifyStatic = require('@fastify/static');
const config = require('./config');
const db = require('./db');
const { requireApiKey, requireAdmin, normalizePhone, validateMediaUrl } = require('./security');

const messageSchema = z.object({
  to: z.string().min(8).max(30),
  text: z.string().min(1).max(5000).optional(),
  mediaUrl: z.string().url().optional(),
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

function parseOrReply(schema, body, reply) {
  const parsed = schema.safeParse(body);
  if (!parsed.success) {
    reply.code(400).send({ error: 'Validation failed', details: parsed.error.flatten() });
    return null;
  }
  return parsed.data;
}

async function registerRoutes(app, gateway) {
  await app.register(fastifyStatic, { root: path.join(__dirname, '..', 'public'), prefix: '/' });

  app.get('/healthz', async () => ({ ok: true, service: 'nitu-whatsapp-gateway', time: new Date().toISOString() }));
  app.get('/readyz', async (request, reply) => {
    const ready = gateway.getStatus().ready;
    return reply.code(ready ? 200 : 503).send({ ready, status: gateway.getStatus().status });
  });

  app.post('/api/v1/messages', { preHandler: requireApiKey }, async (request, reply) => {
    const body = parseOrReply(messageSchema, request.body, reply);
    if (!body) return;
    let recipient;
    try { recipient = normalizePhone(body.to); } catch (error) { return reply.code(400).send({ error: error.message }); }
    if (body.mediaUrl) {
      try { await validateMediaUrl(body.mediaUrl); } catch (error) { return reply.code(400).send({ error: error.message }); }
    }
    const type = body.mediaUrl ? 'media' : 'text';
    const payload = type === 'text'
      ? { text: body.text }
      : { mediaUrl: body.mediaUrl, caption: body.caption || '', filename: body.filename || '', asDocument: body.asDocument };
    const record = db.createMessage({
      idempotencyKey: body.idempotencyKey,
      recipient,
      type,
      payload,
      metadata: body.metadata,
      scheduledAt: body.scheduledAt
    });
    return reply.code(202).send(record);
  });

  app.get('/api/v1/messages/:id', { preHandler: requireApiKey }, async (request, reply) => {
    const record = db.getMessage(request.params.id);
    return record ? record : reply.code(404).send({ error: 'Not found' });
  });

  app.get('/admin/api/status', { preHandler: requireAdmin }, async () => gateway.getStatus());
  app.get('/admin/api/messages', { preHandler: requireAdmin }, async request => db.listMessages(Math.min(Number(request.query.limit) || 100, 500), request.query.status || null));
  app.get('/admin/api/inbound', { preHandler: requireAdmin }, async request => db.listInbound(Math.min(Number(request.query.limit) || 100, 500)));
  app.post('/admin/api/messages/:id/retry', { preHandler: requireAdmin }, async (request, reply) => {
    const record = db.retryMessage(request.params.id);
    if (!record) return reply.code(409).send({ error: 'Only failed messages can be retried' });
    db.addEvent(record.id, 'message.manual_retry', record);
    return reply.code(202).send(record);
  });
  app.post('/admin/api/pair', { preHandler: requireAdmin }, async (request, reply) => {
    const parsed = z.object({ phoneNumber: z.string().min(8).max(30) }).safeParse(request.body);
    if (!parsed.success) return reply.code(400).send({ error: 'Enter the full international phone number' });
    try {
      const code = await gateway.requestPairingCode(parsed.data.phoneNumber);
      return { pairingCode: code };
    } catch (error) {
      return reply.code(409).send({ error: error.message });
    }
  });
  app.post('/admin/api/logout', { preHandler: requireAdmin }, async () => {
    await gateway.logout();
    return { ok: true };
  });
  app.post('/admin/api/test', { preHandler: requireAdmin }, async (request, reply) => {
    const parsed = z.object({ to: z.string().min(8), text: z.string().min(1).max(1000) }).safeParse(request.body);
    if (!parsed.success) return reply.code(400).send({ error: 'Recipient and text are required' });
    let recipient;
    try { recipient = normalizePhone(parsed.data.to); } catch (error) { return reply.code(400).send({ error: error.message }); }
    const record = db.createMessage({ recipient, type: 'text', payload: { text: parsed.data.text }, metadata: { source: 'admin-test' } });
    return reply.code(202).send(record);
  });

  app.get('/', async (request, reply) => reply.sendFile('index.html'));
  app.get('/admin', async (request, reply) => reply.sendFile('index.html'));
}
module.exports = { registerRoutes };

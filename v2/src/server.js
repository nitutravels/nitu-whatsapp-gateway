import Fastify from 'fastify';
import helmet from '@fastify/helmet';
import rateLimit from '@fastify/rate-limit';
import config from './config.js';
import { closeDatabase } from './db.js';
import { QueueWorker } from './queue.js';
import { registerRoutes } from './routes.js';
import { WebhookWorker } from './webhook.js';
import { WhatsAppTransport } from './whatsapp.js';

async function main() {
  const app = Fastify({
    logger: {
      level: config.LOG_LEVEL,
      redact: {
        paths: ['req.headers.authorization', 'req.headers.x-api-key', 'body.token', '*.qrDataUrl', '*.pairingCode'],
        censor: '[REDACTED]'
      }
    },
    trustProxy: true,
    bodyLimit: 2 * 1024 * 1024,
    requestTimeout: 30_000
  });

  await app.register(helmet, {
    contentSecurityPolicy: {
      directives: {
        defaultSrc: ["'self'"],
        imgSrc: ["'self'", 'data:'],
        scriptSrc: ["'self'"],
        styleSrc: ["'self'"],
        connectSrc: ["'self'"],
        objectSrc: ["'none'"],
        baseUri: ["'none'"],
        frameAncestors: ["'none'"]
      }
    }
  });
  await app.register(rateLimit, { max: 180, timeWindow: '1 minute', ban: 3 });

  const transport = new WhatsAppTransport(app.log);
  const queueWorker = new QueueWorker(transport, app.log);
  const webhookWorker = new WebhookWorker(app.log);
  await registerRoutes(app, transport, queueWorker);

  app.setErrorHandler((error, request, reply) => {
    request.log.error({ err: error }, 'Unhandled request error');
    const status = error.statusCode && error.statusCode < 500 ? error.statusCode : 500;
    reply.code(status).send({ error: status < 500 ? error.message : 'Internal server error' });
  });

  let shuttingDown = false;
  const shutdown = async signal => {
    if (shuttingDown) return;
    shuttingDown = true;
    app.log.info({ signal }, 'Shutting down gateway');
    queueWorker.stop();
    webhookWorker.stop();
    await transport.close();
    await app.close();
    closeDatabase();
    process.exit(0);
  };

  process.on('SIGTERM', () => shutdown('SIGTERM'));
  process.on('SIGINT', () => shutdown('SIGINT'));
  process.on('uncaughtException', error => {
    app.log.fatal({ err: error }, 'Uncaught exception');
    setTimeout(() => process.exit(1), 500).unref();
  });
  process.on('unhandledRejection', error => {
    app.log.error({ err: error }, 'Unhandled rejection');
  });

  await app.listen({ host: '0.0.0.0', port: config.PORT });
  queueWorker.start();
  webhookWorker.start();
  transport.start().catch(error => {
    app.log.error({ err: error }, 'Initial WhatsApp connection failed');
    transport.scheduleReconnect();
  });
}

main().catch(error => {
  console.error(error);
  process.exit(1);
});

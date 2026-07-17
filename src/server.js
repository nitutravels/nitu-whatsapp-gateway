const Fastify = require('fastify');
const helmet = require('@fastify/helmet');
const rateLimit = require('@fastify/rate-limit');
const config = require('./config');
const { WhatsAppGateway } = require('./gateway');
const { registerRoutes } = require('./routes');

async function main() {
  const app = Fastify({
    logger: { level: config.LOG_LEVEL, redact: ['req.headers.authorization', 'req.headers.x-api-key'] },
    trustProxy: true,
    bodyLimit: 1024 * 1024,
    requestTimeout: 90000
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
  await app.register(rateLimit, { max: 120, timeWindow: '1 minute', ban: 3 });

  const gateway = new WhatsAppGateway(app.log);
  await registerRoutes(app, gateway);

  app.setErrorHandler((error, request, reply) => {
    request.log.error({ err: error }, 'Unhandled request error');
    reply.code(error.statusCode && error.statusCode < 500 ? error.statusCode : 500).send({ error: error.statusCode && error.statusCode < 500 ? error.message : 'Internal server error' });
  });

  const shutdown = async signal => {
    app.log.info({ signal }, 'Shutting down');
    await gateway.close();
    await app.close();
    process.exit(0);
  };
  process.on('SIGTERM', () => shutdown('SIGTERM'));
  process.on('SIGINT', () => shutdown('SIGINT'));

  await app.listen({ host: '0.0.0.0', port: config.PORT });
  await gateway.start();
}

main().catch(error => {
  console.error(error);
  process.exit(1);
});

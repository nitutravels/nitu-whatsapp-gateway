const config = require('./config');
const { signPayload } = require('./security');

async function emitWebhook(event, data, logger) {
  if (!config.WEBHOOK_URL) return;
  const body = JSON.stringify({ event, data, occurredAt: new Date().toISOString() });
  try {
    const response = await fetch(config.WEBHOOK_URL, {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        'user-agent': 'NituWhatsAppGateway/1.0',
        'x-gateway-signature': signPayload(body)
      },
      body,
      signal: AbortSignal.timeout(10000)
    });
    await response.text();
    if (!response.ok) {
      logger.warn({ statusCode: response.status, event }, 'Webhook returned non-success status');
    }
  } catch (error) {
    logger.warn({ err: error, event }, 'Webhook delivery failed');
  }
}
module.exports = { emitWebhook };

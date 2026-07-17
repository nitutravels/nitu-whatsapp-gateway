<?php
declare(strict_types=1);

$secret = (string) getenv('NITU_WA_WEBHOOK_SECRET');
if ($secret === '') {
    http_response_code(500);
    exit('Webhook secret is not configured');
}

$rawBody = file_get_contents('php://input');
$received = (string) ($_SERVER['HTTP_X_GATEWAY_SIGNATURE'] ?? '');
$expected = 'sha256=' . hash_hmac('sha256', $rawBody, $secret);

if (!hash_equals($expected, $received)) {
    http_response_code(401);
    exit('Invalid signature');
}

$event = json_decode($rawBody, true, 512, JSON_THROW_ON_ERROR);

// Store the event idempotently in your database before returning success.
// Use $event['event'], $event['data'] and $event['occurredAt'].

http_response_code(204);

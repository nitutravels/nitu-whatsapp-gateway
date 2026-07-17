<?php
declare(strict_types=1);

/**
 * Server-side example. Never expose GATEWAY_API_KEY in frontend JavaScript.
 */

$gatewayUrl = rtrim((string) getenv('NITU_WA_GATEWAY_URL'), '/');
$apiKey = (string) getenv('NITU_WA_GATEWAY_API_KEY');

if ($gatewayUrl === '' || $apiKey === '') {
    throw new RuntimeException('Set NITU_WA_GATEWAY_URL and NITU_WA_GATEWAY_API_KEY.');
}

$payload = [
    'to' => '919810000000',
    'text' => 'Your duty starts tomorrow at 7:00 AM.',
    'idempotencyKey' => 'duty:4821:driver:93:departure:1',
    'metadata' => [
        'dutyId' => '4821',
        'driverId' => '93',
        'category' => 'departure-reminder',
    ],
];

$ch = curl_init($gatewayUrl . '/api/v1/messages');
if ($ch === false) {
    throw new RuntimeException('Could not initialise cURL.');
}

curl_setopt_array($ch, [
    CURLOPT_POST => true,
    CURLOPT_RETURNTRANSFER => true,
    CURLOPT_CONNECTTIMEOUT => 10,
    CURLOPT_TIMEOUT => 30,
    CURLOPT_HTTPHEADER => [
        'Content-Type: application/json',
        'X-API-Key: ' . $apiKey,
    ],
    CURLOPT_POSTFIELDS => json_encode($payload, JSON_THROW_ON_ERROR),
]);

$body = curl_exec($ch);
$status = (int) curl_getinfo($ch, CURLINFO_RESPONSE_CODE);
$error = curl_error($ch);
curl_close($ch);

if ($body === false || $error !== '') {
    throw new RuntimeException('Gateway request failed: ' . $error);
}

$data = json_decode($body, true, 512, JSON_THROW_ON_ERROR);
if ($status !== 202) {
    throw new RuntimeException('Gateway returned HTTP ' . $status . ': ' . $body);
}

printf("Queued message %s with status %s\n", $data['id'], $data['status']);

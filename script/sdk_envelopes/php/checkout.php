<?php

// See ../README.md. Outside vendor/, so sentry-php counts it as your code.

require __DIR__ . '/vendor/autoload.php';

use Sentry\Attachment\Attachment;
use Sentry\Breadcrumb;
use Sentry\State\Scope;

const PROJECTS = ['chained' => 1, 'library_error' => 2, 'message' => 3];
const RECEIPT = "\x89\x50\x4E\x47\x0D\x0A\x1A\x0A\x00\xFF\x0A\x72\x65\x63\x0A\x0A";

class CardNotFound extends RuntimeException {}

class CheckoutError extends RuntimeException {}

function load_card(string $card_id): void
{
    throw new CardNotFound("card {$card_id} not found");
}

function charge(string $card_id): void
{
    try {
        load_card($card_id);
    } catch (CardNotFound $e) {
        throw new CheckoutError('checkout failed', 0, $e);
    }
}

function parse_order(string $body): mixed
{
    return json_decode($body, true, 512, JSON_THROW_ON_ERROR);
}

function parse_refund(string $body): mixed
{
    return json_decode($body, true, 512, JSON_THROW_ON_ERROR);
}

$scenario = getenv('SCENARIO');
\Sentry\init([
    'dsn' => getenv('SPLAT_DSN_BASE') . '/' . PROJECTS[$scenario],
    'release' => 'fixture@1.0.0',
    'environment' => 'fixture',
    'server_name' => 'fixture-host',
]);

switch ($scenario) {
    case 'chained':
        \Sentry\withScope(function (Scope $scope): void {
            $scope->addAttachment(Attachment::fromBytes('receipt.bin', RECEIPT, 'application/octet-stream'));
            \Sentry\addBreadcrumb(new Breadcrumb(Breadcrumb::LEVEL_INFO, Breadcrumb::TYPE_DEFAULT, 'checkout', 'charging card 4412'));
            try {
                charge('4412');
            } catch (CheckoutError $e) {
                \Sentry\captureException($e);
            }
        });
        break;
    case 'library_error':
        foreach (['parse_order', 'parse_refund'] as $parse) {
            try {
                $parse('{');
            } catch (JsonException $e) {
                \Sentry\captureException($e);
            }
        }
        break;
    case 'message':
        \Sentry\captureMessage('Card 4412 declined');
        \Sentry\captureMessage('Card 9001 declined');
        break;
}

\Sentry\flush();

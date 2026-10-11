# See ../README.md.
import json
import logging
import os

import sentry_sdk

PROJECTS = {"chained": 1, "library_error": 2, "message": 3}
RECEIPT = bytes([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0xFF, 0x0A, 0x72, 0x65, 0x63, 0x0A, 0x0A])


class CardNotFound(Exception):
    pass


class CheckoutError(Exception):
    pass


def load_card(card_id):
    raise CardNotFound(f"card {card_id} not found")


def charge(card_id):
    try:
        load_card(card_id)
    except CardNotFound as e:
        raise CheckoutError("checkout failed") from e


def parse_order(body):
    return json.loads(body)


def parse_refund(body):
    return json.loads(body)


scenario = os.environ["SCENARIO"]
sentry_sdk.init(
    dsn=f"{os.environ['SPLAT_DSN_BASE']}/{PROJECTS[scenario]}",
    release="fixture@1.0.0",
    environment="fixture",
    server_name="fixture-host",
)

if scenario == "chained":
    with sentry_sdk.new_scope() as scope:
        scope.add_attachment(bytes=RECEIPT, filename="receipt.bin", content_type="application/octet-stream")
        sentry_sdk.add_breadcrumb(category="checkout", message="charging card 4412")
        try:
            charge("4412")
        except CheckoutError as e:
            sentry_sdk.capture_exception(e)
elif scenario == "library_error":
    for parse in (parse_order, parse_refund):
        try:
            parse("{")
        except ValueError as e:
            sentry_sdk.capture_exception(e)
elif scenario == "message":
    # The logging integration sends ERROR records as events, template and all.
    log = logging.getLogger("billing")
    log.error("Card %s declined", "4412")
    log.error("Card %s declined", "9001")

sentry_sdk.flush()

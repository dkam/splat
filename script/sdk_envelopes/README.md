# SDK envelopes

What real Sentry SDKs send, recorded for `test/integration/sdk_envelopes_test.rb`.
Splat is tested against these bytes rather than against envelopes written by
hand, which only ever contain what the test's author expected an SDK to send.

```sh
script/sdk_envelopes/capture            # every SDK; needs Docker
script/sdk_envelopes/capture python go  # just these
```

Each directory here is a small program for one SDK, run in a container by its
`run.sh` once per scenario, against a recording server in `capture`. The
envelopes land in `test/fixtures/files/sdk_envelopes/<sdk>/`, exactly as sent:
compressed if the SDK compressed them, with the `Content-Encoding` as the
extension (`.gz`, `.br`, `.zst`, `.deflate`).

SDK versions are pinned in each program's manifest. To move to a newer SDK, bump
the pin, rerun `capture` for it, and see what the test makes of the result.

## The scenarios

Every program does the same three things, in its own language's idiom. The
scenario picks the DSN's project id, which is how the recorder names the files:
`chained` is project 1, `library_error` 2, `message` 3. The DSN is
`$SPLAT_DSN_BASE/<id>`.

Every program sets `release: "fixture@1.0.0"`, `environment: "fixture"` and
`server_name: "fixture-host"`, sends synchronously or flushes before exiting,
and leaves the SDK's other defaults alone — the point is what an SDK sends
out of the box.

1. **`chained`** — an error raised while handling another, sent with a binary
   attachment.
   - `load_card("4412")` raises `CardNotFound` with the message
     `card 4412 not found`.
   - `charge("4412")` calls it, catches that, and raises `CheckoutError` with
     the message `checkout failed`, chained to the `CardNotFound` the
     language's way (a cause, `from`, `%w`, `source()`, an inner exception).
   - Just before calling `charge`, the program records a breadcrumb with the
     category `checkout` and the message `charging card 4412`.
   - The program captures the `CheckoutError` with the SDK's
     capture-exception call, with an attachment `receipt.bin`,
     `application/octet-stream`, of these 16 bytes, which include newlines and
     aren't UTF-8: `89 50 4E 47 0D 0A 1A 0A 00 FF 0A 72 65 63 0A 0A`.

2. **`library_error`** — the same library error from two places in your code.
   `parse_order` and `parse_refund` each pass `{` to the language's standard
   JSON parser. The error the parser raises or returns is captured, from
   `parse_order` first and then from `parse_refund`: two events.

3. **`message`** — the same message with different numbers, twice:
   `Card 4412 declined`, then `Card 9001 declined`. Where the SDK has a
   parameterised form — a logging integration that sends the template and its
   parameters — it's sent that way, with the template `Card %s declined` or the
   language's equivalent (`Card {Card} declined`); otherwise as a plain
   capture-message string.

Function and type names follow the language's conventions (`parse_order`,
`parseOrder`, `ParseOrder`), and the code that matters goes where the SDK
counts frames as your code rather than a library's.

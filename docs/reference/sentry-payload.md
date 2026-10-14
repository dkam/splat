# The Sentry payload, as Splat sees it

What actually arrives at `POST /api/:project_id/envelope/`, and what Splat does
with it. The full spec is [`envelopes.md`](envelopes.md) — this is the subset we
handle, drawn from real payloads rather than from the spec's examples.

Two things trip people up, and they're worth stating before the diagrams:

1. **An envelope is not JSON.** It's newline-delimited JSON — several independent
   documents stacked in one request body. Parsing it as a single object fails.
2. **One envelope carries many items, of different types.** An error event and a
   batch of logs can arrive in the same POST and go to different tubes.

## 1. The wire format

Line 1 is the envelope header; then each item is a header line followed by its
payload. The `length` in an item header is the payload's byte count, which is how
a reader finds the next item without parsing the payload. A payload with a
`length` can hold newlines — an attachment, pretty-printed JSON — so it has to be
read as that many bytes, not as a line; one without runs to the next newline.
sentry-ruby sets `length` on attachments but not on events.

```
{"event_id":"9ec79c33ec9942ab8353589fcb2e04dc","sent_at":"2026-07-17T10:00:00Z"}  ← envelope header
{"type":"event","length":41236}                                                    ← item 1 header
{"event_id":"9ec79c33…","exception":{…},"breadcrumbs":{…}, …}                      ← item 1 payload
{"type":"log","length":892}                                                        ← item 2 header
{"items":[{…},{…}]}                                                                ← item 2 payload
```

The envelope header carries `event_id` and `sent_at`; items carry their own type
and length. Note the `event_id` appears in **both** the envelope header and the
event payload — Splat prefers the payload's and falls back to the envelope's
(`EnvelopeProcessor#process_item`), following GlitchTip.

**Before envelopes**, clients posted a single event to `/api/:project_id/store/`,
and the raven-era ones (raven-ruby, raven-python) as base64 of zlib-compressed
JSON. `Api::StoreController` reads it as Relay does — JSON as sent, else base64,
then JSON or zlib — and makes it a one-item envelope, `event` or, for an event
whose `type` is `transaction`, `transaction`, with a generated `event_id` if it
has none. From there it is an envelope: queued, forwarded, and answered alike,
except that success is `{"id": "<event_id>"}`.

## 2. What Splat does with each item

Five item types reach `process_item`. Three are stored, two are deliberately
dropped. Each stored type is queued to its own tube and drained by its own
consumer into its own database.

```mermaid
flowchart LR
  POST["POST /api/:project_id/envelope/"] --> PARSE["parse_envelope\nread by byte offset"]
  PARSE --> TYPE{"item header\ntype"}

  TYPE -->|"event"| EV["splat.events"]
  TYPE -->|"transaction"| TX["splat.transactions"]
  TYPE -->|"log / otel_log"| LG["splat.logs"]
  TYPE -->|"attachment"| DROP1["dropped"]
  TYPE -->|"session"| DROP2["dropped"]
  TYPE -->|"anything else"| DROP3["logged, dropped"]

  EV --> EVC["EventConsumer"] --> EVT[("events\nissues_events.sqlite3")]
  TX --> TXC["TransactionConsumer"] --> TXT[("transactions\n+ span_trees")]
  LG --> LGC["LogConsumer"] --> LGT[("logs\nlogs.sqlite3")]

  style DROP1 stroke-dasharray: 4 4
  style DROP2 stroke-dasharray: 4 4
  style DROP3 stroke-dasharray: 4 4
```

Three gates sit in front of storage, all in `process_item`:

- **`setting.store_events?` / `store_transactions?` / `store_logs?`** — each type
  can be switched off; the item is dropped at ingest, before the tube. Every
  response also tells the SDK, as a rate limit (below), unless the project
  forwards.
- **`housekeeping_transaction?(name)`** — drops Splat's own noise transactions so
  the instance doesn't fill up watching itself.
- **Missing `event_id`** — events and transactions are dropped and logged. Logs
  are handled *before* this guard, because a log item is a batch (`items: [...]`)
  with no single id.

### What the SDK is told

A server SDK doesn't send an envelope again, whatever the answer; a non-2xx
response only means it records the envelope as lost. (Mobile SDKs keep
envelopes on disk while offline; whether they send one again after a `503`
hasn't been checked.) While it's rate limited,
it throws new items in the limited categories away before sending them.

| Response | When | What the SDK does |
|---|---|---|
| `200` | Everything else, an envelope Splat couldn't read or decompress included. With tuber down, the items and the forward are spooled to disk and replayed once it's back (`Ingest::Spool`). | Counts it as delivered |
| `503` | Tuber didn't answer and the spool is full (`SPLAT_SPOOL_MAX_MB`) or can't be written. The envelope isn't forwarded either. | Counts it as lost |
| `413` | The body is over 20 MB as sent, or over 100 MB decompressed (Sentry's own limits). Decompression stops at the limit. | Counts it as lost |
| `X-Sentry-Rate-Limits: 60:<categories>:organization:disabled`, on any response | A stream is switched off in Settings: `error` for events, `transaction`, `log_item` for logs | Stops sending those for 60 s, then sends again and gets the header again while the stream is still off |

The header follows the [rate-limiting spec](https://develop.sentry.dev/sdk/expected-features/rate-limiting/).
SDKs read it on a `200` as well as on a `429`. Splat never sends a `429`: an
SDK given one with no header stops sending every category, errors included.
The OTLP logs endpoint answers `503` too when tuber is down, and an OTLP
collector does send the batch again after a `503`.

## 3. The event payload

21 top-level keys on a real Booko event. Grouped by what they're for, rather than
alphabetically as they arrive:

```
identity      event_id          "9ec79c33ec9942ab8353589fcb2e04dc"
              timestamp         String (ISO8601 or epoch float — parse both)
              type              "event"
              level             "error" | "warning" | …
              platform          "ruby"

deployment    release           app version
              environment       "production"
              server_name       which box sent it

the error     exception.values[]        ← usually 1, more when causes are chained:
                                          oldest first, so the raised exception is
                                          the LAST and values[0] its root cause
                .type                   "NoMethodError"
                .value                  the message
                .module                 namespace
                .thread_id
                .mechanism              {type, handled}
                .stacktrace.frames[]    ← 65 frames on the sample event
              threads.values[]          ← {id, crashed, current, stacktrace}

grouping      fingerprint       [] — usually empty; Splat derives one (§6)
              transaction       "ProductsController#show"
              transaction_info  {source}

context       contexts.os       {name, version, build, kernel_version, machine}
              contexts.runtime  {name, version}
              contexts.trace    {trace_id, span_id, parent_span_id, op,
                                 status, origin, data}      ← links to a transaction
              user              {} — empty on Booko
              tags              {job_id, provider_job_id, …}
              extra             {active_job, arguments, scheduled_at, …}
              modules           {158 keys}  ← the entire Gemfile.lock (§5)

trail         breadcrumbs.values[]  {category, message, level, timestamp,
                                     type, data}

sdk           sdk               {name, version}
```

`contexts.trace.trace_id` is the join to performance data — the same trace_id
appears on the transaction, which is how an error and the request that caused it
are linked.

## 4. A stack frame

`exception.values[-1].stacktrace.frames[]` is where the bulk of an error payload
lives — 65 frames on the sample event, each carrying source context:

```
abs_path        "/app/controllers/products_controller.rb"   full path
filename        "app/controllers/products_controller.rb"    relative
function        "ProductsController#show"
lineno          42
in_app          true          ← your code vs a gem. Drives the UI's default view.
pre_context     [3 lines]     ← source lines before
context_line    "  @product = Product.find(params[:id])"    ← the line itself
post_context    [3 lines]     ← source lines after
```

Frames are ordered **oldest first** — the innermost call is the *last* frame, not
the first. Splat's grouping walks them from the end for exactly this reason (§6).

`pre_context` / `context_line` / `post_context` mean each frame carries 7 lines of
source. That's why frames dominate the payload, and why they compress so well —
neighbouring events from the same code repeat nearly identical text.

## 5. Where the bytes go

Structure from real payloads; proportions vary hugely by event, so treat these as
the shape of the problem, not constants:

| Part | What it is |
|---|---|
| `exception` + `threads` | Stack frames with 7 lines of source each. The bulk. |
| `modules` | 158 gem→version pairs. **Identical on every event from a release.** |
| `contexts`, `tags`, `extra` | Small, but present on every event. |
| `breadcrumbs` | Usually small; grows with app instrumentation. |

`modules` is the clearest illustration of why dictionary compression earns its
keep here: the same 158 gem names and versions ride along on *every single event*
from a given release. It's near-pure redundancy across rows, which is exactly
what a trained zstd dictionary eats — and why `events` gets ~6× (see the
compression figures on the settings page).

## 6. What Splat extracts, and what stays in the blob

Only nine fields become columns. Everything else stays in the compressed payload
blob and is read back on demand.

```mermaid
flowchart LR
  P["event payload\n(21 top-level keys)"] --> C["indexed columns"]
  P --> B["payload_blob\nzstd + trained dict"]

  C --> C1["event_id · timestamp · platform\nsdk_name · sdk_version\nenvironment · release\nserver_name · transaction_name"]
  B --> B1["everything else:\nexception · threads · breadcrumbs\ncontexts · tags · extra · modules"]
```

The mapping is `Event.create_from_sentry_payload!` (`app/models/event.rb:38`):

| Column | Source |
|---|---|
| `platform` | `payload["platform"]` |
| `sdk_name` / `sdk_version` | `payload.dig("sdk", "name"/"version")` |
| `environment` / `release` / `server_name` | top-level keys of the same name |
| `transaction_name` | `payload["transaction"]` |
| `timestamp` | `parse_timestamp(payload["timestamp"])` — handles both forms |
| `payload` | the whole thing, compressed |

**Grouping happens at ingest, not at query time.** `Issue.group_event` derives
a fingerprint (`Issue::Fingerprint`) and finds-or-creates the issue before the
event row is written. It prefers the SDK's `payload["fingerprint"]` when
present, with `"{{ default }}"` in it standing for Splat's own. Booko's SDK sends
`[]`, so in practice Splat derives one: the raised exception's type and the
function in your code it came from — the innermost frame with `in_app: true`
(§4), named by `module` or `filename` and `function`. Not the line number, which
moves with every edit above it, and not a frame inside a gem, which every caller
shares. An event without an exception groups by its message, with numbers, UUIDs
and hex ids taken out.

Three cases need more than that, all seen in real SDK output (§7):

- **A built-in reported as your code.** sentry-ruby sends a core method written
  in C — `Hash#fetch`, `Integer#/` — as a frame of its own at its caller's file
  and line, so `in_app: true`; sentry-php does the same for `json_decode`. A
  frame at its caller's very file and line is passed over for the caller, or
  every `KeyError` from `fetch` in the app would be one issue.
- **No frame marked as your code.** sentry-java marks none unless
  `inAppIncludes` is set. Then the whole stack groups, still by module and
  function, as Sentry does — the innermost frame would be the JDK's. The JVM
  names the classes it generates with numbers and hashes that change every
  run — `GeneratedMethodAccessor123`, `$Proxy45`,
  `$$EnhancerBySpringCGLIB$$a1b2c3d4`, `$HibernateProxy$…`, `$$Lambda$14/0x…`,
  and `lambda$charge$0` for a lambda's body — so those are taken out first,
  or every restart would open the issue again.
- **No stack trace.** sentry-rust sends none by default. Then the type and the
  message, numbers taken out, as Sentry does — by type alone, every
  `serde_json::Error` (type `Error`) in an app would be one issue.

A compiled template's `function` carries a number that differs in every
process. Rails names the method after the template's path plus
`String#hash` of it, which Ruby seeds per process, and its object id:
`_app_views_books_show_html_erb__1033375417407740265_9816` in one process is
`…__2552903438630504205_9816` in the next. Grouping strips the suffix.

The raised exception is `values[-1]`, not `values[0]`. The protocol orders a
chain oldest to newest, and sentry-ruby reverses Ruby's cause chain to match
(`Sentry::ExceptionInterface.build`). Every `rescue … raise Wrapped` in a Rails
app sends at least two, and so does every template error:
`ActionView::Template::Error` wraps its cause, borrowing its message and
backtrace. `SentryProtocol::Payload.raised_exception` is the one reader.

**The raised exception may have no stack trace.** sentry-ruby sends each
backtrace once per chain, on the oldest exception holding it (it dedupes by the
backtrace array's `object_id`). `ActionView::Template::Error#backtrace` returns
its cause's array, so a template error arrives as a `NoMethodError` with frames
and an `ActionView::Template::Error` with none. Read `values[-1].stacktrace`
alone and every template error in the app has the same location.
`SentryProtocol::Payload.stacktrace` falls back to the nearest cause's.

The message comes in four shapes: `message` or `logentry` (the protocol's
canonical name, which sentry-python's logging integration uses), each either a
string or a `{message, params, formatted}` object (sentry-java, sentry-dotnet).
`message` there is the template, `formatted` the template with its params filled
in. Splat titles by `formatted` and groups by the template.

## 7. Other SDKs

`test/fixtures/files/sdk_envelopes/` holds what eight SDKs — Ruby, Python, Node,
Go, Java, .NET, Rust, PHP — actually send for the same four scenarios, and
`test/integration/sdk_envelopes_test.rb` runs them through ingest and the pages.
`script/sdk_envelopes/README.md` records them again. What differs from the
sentry-ruby shapes above:

| | |
|---|---|
| `exception`, `breadcrumbs` | a bare list rather than `{"values": [...]}` — sentry-go for both; @sentry/node, sentry-java and sentry-dotnet for breadcrumbs. The protocol allows either; `SentryProtocol::Payload` reads both. |
| breadcrumb `timestamp` | epoch seconds or an ISO 8601 string, by SDK |
| frames | sentry-go sends `abs_path` and no `filename`. sentry-java sends no `in_app` at all by default. sentry-dotnet's `function` is a full signature, `void Checkout.Charge(string cardId)`. |
| stack trace | none from sentry-rust unless `attach_stacktrace` is on; a Go error has none of its own, so sentry-go records where it was captured |
| message | `logentry` from sentry-python and sentry-dotnet (the latter without `params`), a `message` object from sentry-java, `logentry` without `formatted` from @sentry/node — Splat fills the params in as Sentry's server does |
| types | as the language names them: `*main.CheckoutError` (Go), `Example.CheckoutError` (.NET) |
| compression | gzip from Python, Java, .NET and PHP; none from Ruby, Node, Go and Rust |
| span `start_timestamp`, `timestamp` | epoch seconds from Ruby, Java and PHP; ISO 8601 strings from Python, Go and .NET; sentry-rust sends the start as seconds and the end as a string |
| transactions | @sentry/node 11 sends none: it streams spans instead, as `span` items in the span v2 format (`application/vnd.sentry.items.span.v2+json`), the transaction as a span with `is_segment: true`. Splat doesn't read these yet, so @sentry/node's performance data is dropped. |

## Reading a real one yourself

Structure, no values — safe to paste into a terminal, nothing sensitive printed:

```ruby
# bin/rails runner
e = Event.order(id: :desc).first
puts e.payload.keys.sort                                  # top-level shape
puts e.payload.dig("exception", "values", -1, "type")     # the error raised
puts e.payload.dig("exception","values",-1,"stacktrace","frames").size
puts e.payload["modules"].keys.size                        # the Gemfile.lock rider
```

## See also

- [`envelopes.md`](envelopes.md) — the full upstream envelope spec.
- [`../decisions/0002-legacy-spans-drop.md`](../decisions/0002-legacy-spans-drop.md)
  — how transaction spans are stored (one zstd blob per trace tree).
- `app/services/sentry_protocol/envelope_processor.rb` — the parser and the
  routing in §2.

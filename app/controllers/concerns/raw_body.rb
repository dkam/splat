# frozen_string_literal: true

# For the ingest endpoints, which read request.body themselves, decompressing
# it first. Rails never gets to parse it into params: a JSON-typed body that's
# gzipped or base64 raises ParseError on the first read of request.params, and
# sentry-rails reads them after every action it traces, so a request already
# acted on was answered 400. pg01's OTLP logs got that from 1.18.3 on.
module RawBody
  extend ActiveSupport::Concern

  included do
    prepend_before_action { request.request_parameters = {} }
  end
end

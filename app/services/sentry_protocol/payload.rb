# frozen_string_literal: true

module SentryProtocol
  # Readers for the parts of an event payload that SDKs send in more than one
  # shape. Grouping, titles, the promoted event columns and the MCP tools all
  # read through here, so they agree on what an event says.
  module Payload
    module_function

    # Chained exceptions are listed oldest to newest — sentry-ruby reverses the
    # cause chain to match — so values[0] is the root cause and the raised
    # exception is last.
    def exceptions(payload)
      values = payload.dig("exception", "values")
      values.is_a?(Array) ? values : []
    end

    # The exception that was raised. For Rails' ActionView::Template::Error
    # that's the wrapper, whose message and backtrace are its cause's anyway.
    def raised_exception(payload) = exceptions(payload).last

    # What the raised exception was caused by, its direct cause first and the
    # root cause last. Empty unless the exception was chained.
    def causes(payload) = exceptions(payload)[0...-1].reverse

    def root_cause(payload) = causes(payload).last

    # The stack trace the raised exception was raised with: its own, or where
    # it has none, the nearest cause's. sentry-ruby sends each backtrace once
    # per chain, on the oldest exception holding it, and a template error's
    # backtrace *is* its cause's — so that's where it arrives.
    def stacktrace(payload)
      exceptions(payload).reverse_each do |exception|
        return exception["stacktrace"] if exception.dig("stacktrace", "frames").present?
      end
      nil
    end

    # The message to show. It arrives as "message" or as "logentry"
    # (sentry-python's logging integration), and as a string or a
    # {message, params, formatted} object (sentry-java, sentry-dotnet), where
    # `formatted` is the template with its params filled in.
    def message(payload)
      raw = raw_message(payload)
      raw.is_a?(Hash) ? (raw["formatted"].presence || raw["message"].presence) : raw.presence
    end

    # The message to group by: the template where there is one, so
    # "Payment %s failed" is one issue whatever the payment.
    def message_template(payload)
      raw = raw_message(payload)
      raw.is_a?(Hash) ? (raw["message"].presence || raw["formatted"].presence) : raw.presence
    end

    def raw_message(payload)
      payload["message"].presence || payload["logentry"].presence
    end
  end
end

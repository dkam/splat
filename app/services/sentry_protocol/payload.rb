# frozen_string_literal: true

module SentryProtocol
  # Readers for the parts of an event payload that SDKs send in more than one
  # shape. Grouping, titles, the promoted event columns, the pages and the MCP
  # tools all read through here, so they agree on what an event says.
  # test/integration/sdk_envelopes_test.rb holds the shapes real SDKs send.
  module Payload
    module_function

    # Chained exceptions are listed oldest to newest — sentry-ruby reverses the
    # cause chain to match — so values[0] is the root cause and the raised
    # exception is last.
    def exceptions(payload) = listed(payload["exception"])

    # Oldest first, as sent.
    def breadcrumbs(payload) = listed(payload["breadcrumbs"])

    # An interface holding a list arrives as {"values": [...]} or, from
    # sentry-go, @sentry/node, sentry-java and sentry-dotnet, as the bare list;
    # the protocol allows both.
    def listed(interface)
      values = interface.is_a?(Hash) ? interface["values"] : interface
      values.is_a?(Array) ? values.grep(Hash) : []
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

    # A frame's file as an SDK names it. sentry-go sends only the absolute path.
    def frame_file(frame) = frame["filename"].presence || frame["abs_path"].presence

    USER_FIELDS = {"id" => "id", "username" => "username", "email" => "email", "ip_address" => "ip"}.freeze

    # Who the event happened to, the way Sentry's sentry:user tag names them:
    # the first of id, username, email and IP address, with its kind, so the
    # user with id 7 isn't the user named "7". Nil when the event doesn't say.
    # "{{auto}}" is the browser SDKs asking the server to fill in the IP
    # address; Splat doesn't, so it names no one.
    def user_key(payload)
      user = payload["user"]
      return unless user.is_a?(Hash)

      USER_FIELDS.each do |field, kind|
        value = user[field]
        next if value.blank? || value == "{{auto}}"
        return "#{kind}:#{value}" if value.is_a?(String) || value.is_a?(Numeric)
      end
      nil
    end

    # A breadcrumb's time, which arrives as epoch seconds or an ISO 8601 string
    # depending on the SDK. Nil when it's neither.
    def time(value)
      case value
      when Numeric then Time.at(value)
      when String then Time.iso8601(value)
      end
    rescue ArgumentError
      nil
    end

    # The message to show. It arrives as "message" or as "logentry"
    # (sentry-python's logging integration), and as a string or a
    # {message, params, formatted} object (sentry-java, sentry-dotnet), where
    # `formatted` is the template with its params filled in. @sentry/node
    # leaves `formatted` out, for the server to fill in.
    def message(payload)
      raw = raw_message(payload)
      return raw.presence unless raw.is_a?(Hash)

      raw["formatted"].presence || fill_in(raw["message"], raw["params"]) || raw["message"].presence
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

    PRINTF_PLACEHOLDER = /%(?:\((\w+)\))?[-#0 +]*\d*(?:\.\d+)?([diouxXeEfFgGcrsa%])/
    CURLY_PLACEHOLDER = /\{(\w*)\}/

    # A template with its params filled in, the way Sentry's server does it
    # (Relay's normalize_logentry): a template with "%" printf-style — "%s",
    # "%(name)s" — or else one with "{" by position or name — "{}", "{0}",
    # "{card}". Nil when a placeholder has no param, as Relay leaves those.
    def fill_in(template, params)
      return unless template.is_a?(String)
      return unless params.is_a?(Array) || params.is_a?(Hash)

      position = -1
      param = ->(name) do
        key = name.presence || (position += 1)
        value = if params.is_a?(Hash)
          params[key.to_s]
        elsif (index = key.is_a?(Integer) ? key : Integer(key, 10, exception: false))
          params[index]
        end
        value.nil? ? throw(:missing) : value.to_s
      end

      catch(:missing) do
        if template.include?("%")
          template.gsub(PRINTF_PLACEHOLDER) { ($2 == "%") ? "%" : param.call($1) }
        elsif template.include?("{")
          template.gsub(CURLY_PLACEHOLDER) { param.call($1) }
        end
      end
    end
  end
end

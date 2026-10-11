# frozen_string_literal: true

class Issue
  # What makes two events one issue.
  #
  # An exception groups by its type and the function in your code it was
  # raised from: the innermost in-app frame (the innermost of all frames when
  # none is in-app), named by module or file and function. Not by line number,
  # which moves whenever the file is edited, and not by a frame inside a gem,
  # which every caller shares — every ActiveRecord::RecordNotFound comes out of
  # the same line of active_record/core.rb.
  #
  # A message groups by its text, with the numbers, UUIDs and hex ids that vary
  # between occurrences taken out: "Timeout after 3021ms for user 4412" is one
  # issue, not one per user.
  #
  # An SDK's own fingerprint wins, with "{{ default }}" standing for the one
  # Splat would have made.
  module Fingerprint
    DEFAULT_VARIABLE = /\A\{\{\s*default\s*\}\}\z/

    # Rails names a compiled template's method after its path plus a number
    # that differs in every process: _app_views_books_show_html_erb__10333…_9816.
    COMPILED_TEMPLATE_SUFFIX = /__+\d+_\d+\z/
    # An anonymous class in a label: "block in #<Class:0x000055d5c3a0>#call".
    OBJECT_ADDRESS = /0x\h+/

    # A hex id is 8 or more hex digits with at least one number among them, so
    # words like "deadbeef" or "accessed" survive.
    HEX_ID = /\b(?:0x\h+|(?=\h*\d)\h{8,})\b/i

    module_function

    def generate(payload)
      sdk = Array.wrap(payload["fingerprint"]).map(&:to_s)
      return default(payload) if sdk.empty?

      sdk.map { |part| part.match?(DEFAULT_VARIABLE) ? default(payload) : part }.join("::")
    end

    def default(payload)
      exception(payload) || message(payload)
    end

    def exception(payload)
      type = SentryProtocol::Payload.raised_exception(payload)&.dig("type")
      return if type.blank?

      frame = culprit_frame(SentryProtocol::Payload.stacktrace(payload)&.dig("frames"))
      [type, (frame_identity(frame) if frame)].compact.join("::")
    end

    def message(payload)
      text = SentryProtocol::Payload.message_template(payload).to_s
      Digest::MD5.hexdigest(text.present? ? normalize_message(text) : "Unknown Error")
    end

    # Frames arrive oldest first, so the innermost is last.
    def culprit_frame(frames)
      return if frames.blank?

      frames.rfind { it["in_app"] == true } || frames.last
    end

    # Module or file, and function: what survives an edit elsewhere in the file
    # and a restart. The line number stands in only for a missing function.
    def frame_identity(frame)
      place = frame["module"].presence || frame["filename"].presence || frame["abs_path"]
      function = frame["function"].to_s.sub(COMPILED_TEMPLATE_SUFFIX, "").gsub(OBJECT_ADDRESS, "0x")
      [place, function.presence || frame["lineno"]].join("::")
    end

    def normalize_message(text)
      text.gsub(Logs::Uuid::CANONICAL, "?")
        .gsub(HEX_ID, "?")
        .gsub(Transaction::SqlNormalizer::NUMERIC_LITERAL, "?")
    end

    # The fingerprints earlier versions gave the same payload, newest first,
    # so their issues can be re-keyed rather than opened again as new.
    def previous(payload)
      [as_of_1_20_0(payload), as_of_1_19_4(payload)].compact.uniq
    end

    # Neither returns a fingerprint for an event with no message it could read:
    # those all went into one "Unknown Error" issue, which nothing should
    # inherit. Nor for a fingerprint sent as a string, which failed ingest.

    # 1.20.0: the raised exception's type and its innermost frame's file and
    # line; a message by its text as sent.
    def as_of_1_20_0(payload)
      sdk = payload["fingerprint"]
      exception = SentryProtocol::Payload.raised_exception(payload)
      template = SentryProtocol::Payload.message_template(payload).to_s

      if sdk.present?
        sdk.join("::") if sdk.is_a?(Array)
      elsif exception.is_a?(Hash) && exception["type"].present?
        innermost = SentryProtocol::Payload.stacktrace(payload)&.dig("frames")&.last || {}
        "#{exception["type"]}::#{innermost["filename"]}::#{innermost["lineno"]}"
      elsif template.present?
        Digest::MD5.hexdigest(template)
      end
    end

    # 1.19.4 and earlier: the same, but the root cause of a chained exception
    # rather than the exception raised, and only a string "message". A message
    # object failed ingest.
    def as_of_1_19_4(payload)
      sdk = payload["fingerprint"]
      root = payload.dig("exception", "values", 0)
      message = payload["message"]

      if sdk.present?
        sdk.join("::") if sdk.is_a?(Array)
      elsif root.is_a?(Hash) && root["type"].present?
        innermost = root.dig("stacktrace", "frames")&.last || {}
        "#{root["type"]}::#{innermost["filename"]}::#{innermost["lineno"]}"
      elsif message.is_a?(String) && message.present?
        Digest::MD5.hexdigest(message)
      end
    end
  end
end

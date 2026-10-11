# frozen_string_literal: true

class Issue
  # What makes two events one issue.
  #
  # An exception groups by its type and the function in your code it was
  # raised from: the innermost in-app frame, named by module or file and
  # function. Not by line number, which moves whenever the file is edited, and
  # not by a frame inside a gem, which every caller shares — every
  # ActiveRecord::RecordNotFound comes out of the same line of
  # active_record/core.rb. With no frame in your code, it groups by the whole
  # stack, and with no stack trace at all by its message, as Sentry does.
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

    # Classes the JVM generates, named with numbers and hashes that differ from
    # one run to the next, and what's kept of each name. Sentry's list, plus
    # $Proxy's number, which Sentry leaves in.
    JVM_GENERATED = [
      [/(Generated(?:Method|(?:Serialization)?Constructor)Accessor)\d+/, '\1'], # reflection
      [/(\$\$\w+?CGLIB\$\$)\h+(?:_\d+)?/, '\1'],                                 # Spring
      [/(\$\$?EnhancerBy\w+?\$?\$)\h+(?:_\d+)?/, '\1'],
      [/(\$\$?FastClassBy\w+?\$?\$)\h+(?:_\d+)?/, '\1'],
      [/(\$\$?HibernateProxy\$?\$)\w+(?:_\d+)?/, '\1'],
      [/(\$\$_javassist)(?:_seam)?(?:_\d+)?/, '\1'],
      [/(\$fn__)\d+/, '\1'],                                                     # Clojure
      [/(\$\$Lambda)\S*/, '\1'],             # $$Lambda$14/0x0000000800c02a00, $$Lambda/0x… on JDK 21
      [/\A(jdk\.proxy)\d+\./, '\1.'],        # jdk.proxy2.$Proxy45
      [/(\$Proxy)\d+/, '\1']
    ].freeze
    # A lambda's body, numbered in the order the class declares its lambdas:
    # lambda$charge$0.
    JAVA_LAMBDA_BODY = /\A(lambda\$.*)\$\d+\z/

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
      raised = SentryProtocol::Payload.raised_exception(payload)
      type = raised&.dig("type")
      return if type.blank?

      frames = SentryProtocol::Payload.stacktrace(payload)&.dig("frames")
      frames = frames.is_a?(Array) ? frames.grep(Hash) : []
      [type, place(frames) || described(raised)].compact.join("::")
    end

    def message(payload)
      text = SentryProtocol::Payload.message_template(payload).to_s
      Digest::MD5.hexdigest(text.present? ? normalize_message(text) : "Unknown Error")
    end

    # Where in the code: the culprit frame, or with none in your code the whole
    # stack — sentry-java marks no frame in-app unless configured to.
    def place(frames)
      return if frames.empty?

      frame = culprit_frame(frames)
      return frame_identity(frame) if frame

      identities = frames.map { frame_identity(it) }.chunk_while { _1 == _2 }.map(&:first) # recursion
      Digest::MD5.hexdigest(identities.join("\n"))
    end

    # The innermost in-app frame. Frames arrive oldest first, so that's the
    # last one marked in_app, unless it sits at its caller's very file and
    # line: a built-in the caller called, which sentry-ruby (Hash#fetch,
    # Integer#/) and sentry-php (json_decode) report as a frame of its own at
    # the caller's place, so as your code. Then it's the caller.
    def culprit_frame(frames)
      index = frames.rindex { it["in_app"] == true }
      return if index.nil?

      index -= 1 while index.positive? && same_place?(frames[index], frames[index - 1])
      frames[index]
    end

    def same_place?(frame, caller)
      file = SentryProtocol::Payload.frame_file(frame)
      file.present? && frame["lineno"].present? &&
        file == SentryProtocol::Payload.frame_file(caller) && frame["lineno"] == caller["lineno"]
    end

    # With no stack trace — sentry-rust's default — its message, without the
    # numbers and ids that vary, and without a Ruby error_highlight snippet.
    def described(exception)
      value = exception["value"]
      return if value.blank? || !value.is_a?(String)

      Digest::MD5.hexdigest(normalize_message(ExceptionMessage.headline(value)))
    end

    # Module or file, and function: what survives an edit elsewhere in the file
    # and a restart. The line number stands in only for a missing function.
    def frame_identity(frame)
      place = without_generated(frame["module"].to_s).presence || frame["filename"].presence || frame["abs_path"]
      function = frame["function"].to_s.sub(COMPILED_TEMPLATE_SUFFIX, "").sub(JAVA_LAMBDA_BODY, '\1').gsub(OBJECT_ADDRESS, "0x")
      [place, function.presence || frame["lineno"]].join("::")
    end

    def without_generated(class_name)
      return class_name unless class_name.include?("$") || class_name.include?("Accessor")

      JVM_GENERATED.reduce(class_name) { |name, (pattern, kept)| name.gsub(pattern, kept) }
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
      root = SentryProtocol::Payload.exceptions(payload).first
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

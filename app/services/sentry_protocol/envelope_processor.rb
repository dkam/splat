# frozen_string_literal: true

module SentryProtocol
  class EnvelopeProcessor
    class InvalidEnvelope < StandardError; end

    # Housekeeping jobs carry no actionable perf data and tend to ship
    # oversized SQL breadcrumbs (e.g. SolidCable INSERTs of broadcast HTML).
    HOUSEKEEPING_TRANSACTION_PREFIXES = %w[
      SolidCable::
      ActiveStorage::
    ].freeze

    # Well-formed envelope items Splat has no use for. They carry no event_id —
    # they aren't occurrences — so they have to be dropped before the event_id
    # guard in process_item, the way logs and check-ins are, or a valid item
    # gets reported as malformed.
    #
    # "sessions" is release health: per-minute counts of requests that exited or
    # errored, which Sentry turns into crash-free rates. Every server SDK sends
    # it by default (sentry-ruby's auto_session_tracking), one envelope per
    # process per minute — ~21 a minute from Booko alone, each of which logged
    # an error here. "session" is the same thing unaggregated.
    IGNORED_ITEM_TYPES = %w[
      session
      sessions
      client_report
      statsd
      metric_buckets
      replay_event
      replay_recording
      profile
      profile_chunk
    ].freeze

    attr_reader :raw_body, :project

    def initialize(raw_body, project)
      @raw_body = raw_body
      @project = project
    end

    def process
      envelope = parse_envelope
      validate_envelope!(envelope)

      envelope[:items].each do |item|
        process_item(item, envelope[:headers])
      end

      true
    rescue InvalidEnvelope => e
      Rails.logger.error "Invalid envelope: #{e.message}"
      false
    rescue JSON::ParserError => e
      Rails.logger.error "Failed to parse envelope JSON: #{e.message}"
      false
    rescue => e
      Rails.logger.error "Error processing envelope: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      true # Return true to avoid client retries on our internal errors
    end

    private

    # One read per envelope, memoized — process_item consults the ingest
    # toggles for every item.
    def setting
      @setting ||= Setting.instance
    end

    def parse_envelope
      lines = raw_body.split("\n")
      raise InvalidEnvelope, "Empty envelope body" if lines.empty?

      # First line is envelope headers
      envelope_headers = JSON.parse(lines[0]).with_indifferent_access

      items = []
      current_item = nil
      payload_lines = []

      # Process remaining lines
      lines[1..].each_with_index do |line, index|
        if line.start_with?("{") && line.end_with?("}") && !current_item
          # This is an item header
          current_item = JSON.parse(line).with_indifferent_access

          # Validate length field immediately if present (before using it)
          if current_item["length"].present?
            unless current_item["length"].is_a?(Integer) && current_item["length"] > 0
              raise InvalidEnvelope, "Invalid length field: #{current_item["length"]}"
            end
          end

          payload_lines = []
        elsif current_item
          # This is part of the payload
          if current_item["length"]
            # Length-prefixed payload
            payload_lines << line
            if payload_lines.join("\n").bytesize + line.bytesize + 1 >= current_item["length"]
              # Last line of payload
              payload = payload_lines.join("\n")

              # Parse payload if it's JSON
              begin
                parsed_payload = JSON.parse(payload).with_indifferent_access
              rescue JSON::ParserError
                parsed_payload = payload
              end

              items << {
                headers: current_item,
                payload: parsed_payload
              }

              current_item = nil
              payload_lines = []
            end
          elsif index == lines[1..].length - 1 || lines[1..][index + 1]&.start_with?("{")
            # Implicit length (terminated by newline or EOF)
            payload_lines << line
            payload = payload_lines.join("\n")

            # Parse payload if it's JSON
            begin
              parsed_payload = JSON.parse(payload).with_indifferent_access
            rescue JSON::ParserError
              parsed_payload = payload
            end

            items << {
              headers: current_item,
              payload: parsed_payload
            }

            current_item = nil
            payload_lines = []
          # Last line of this payload
          else
            payload_lines << line
          end
        end
      end

      # Handle case where payload goes to EOF without newline
      if current_item && payload_lines.any?
        payload = payload_lines.join("\n")

        begin
          parsed_payload = JSON.parse(payload).with_indifferent_access
        rescue JSON::ParserError
          parsed_payload = payload
        end

        items << {
          headers: current_item,
          payload: parsed_payload
        }
      end

      {
        headers: envelope_headers,
        items: items
      }
    end

    def validate_envelope!(envelope)
      # Validate sent_at format if present
      if envelope[:headers][:sent_at].present?
        begin
          Time.parse(envelope[:headers][:sent_at])
        rescue ArgumentError => e
          raise InvalidEnvelope, "Invalid sent_at timestamp: #{e.message}"
        end
      end

      # Must have at least one item
      if envelope[:items].empty?
        raise InvalidEnvelope, "Envelope must contain at least one item"
      end

      # Validate each item
      envelope[:items].each_with_index do |item, index|
        unless item.dig(:headers, :type).present?
          raise InvalidEnvelope, "Item #{index} missing required field: type"
        end

        unless item[:payload].present?
          raise InvalidEnvelope, "Item #{index} missing payload"
        end

        # Validate length field if present
        if item.dig(:headers, :length).present?
          length = item.dig(:headers, :length)
          unless length.is_a?(Integer) && length > 0
            raise InvalidEnvelope, "Item #{index} has invalid length: #{length}"
          end
        end
      end

      true
    end

    def process_item(item, envelope_headers)
      item_type = item.dig(:headers, :type)

      # Logs are a batch ("items": [...]) with no single event_id, so handle
      # them before the event_id guard below.
      if item_type == "log" || item_type == "otel_log"
        unless setting.store_logs?
          Rails.logger.debug "Logs disabled — dropping log item"
          return
        end
        enqueue(
          Ingest::Tuber::LOGS_TUBE,
          {
            format: "sentry",
            payload: item[:payload],
            project_id: project.id
          },
          kind: "log"
        )
        Rails.logger.debug "Queued log batch"
        return
      end

      # Check-ins (Sentry Crons heartbeats) carry a monitor_slug, not an
      # event_id, so handle them before the event_id guard below.
      if item_type == "check_in"
        payload = item[:payload]
        unless payload.is_a?(Hash) && payload["monitor_slug"].present?
          Rails.logger.warn "Check-in item missing monitor_slug — dropping"
          return
        end
        enqueue(
          Ingest::Tuber::CHECKINS_TUBE,
          {
            payload: payload,
            project_id: project.id
          },
          kind: "check_in"
        )
        Rails.logger.debug "Queued check-in for monitor #{payload["monitor_slug"]}"
        return
      end

      if IGNORED_ITEM_TYPES.include?(item_type)
        Rails.logger.debug "Skipping #{item_type} item — not stored by Splat"
        return
      end

      # Get event_id from payload first, then envelope headers, following GlitchTip pattern
      event_id = extract_event_id(item[:payload]) || envelope_headers[:event_id]

      unless event_id
        Rails.logger.error "Missing event_id in both payload and envelope headers for #{item_type} item"
        return # Skip this item but continue processing others
      end

      case item_type
      when "event"
        unless setting.store_events?
          Rails.logger.debug "Events disabled — dropping event #{event_id}"
          return
        end
        enqueue(
          Ingest::Tuber::EVENTS_TUBE,
          {
            event_id: event_id,
            payload: item[:payload],
            project_id: project.id
          },
          kind: "event"
        )
        Rails.logger.debug "Queued event processing: #{event_id}"
      when "transaction"
        unless setting.store_transactions?
          Rails.logger.debug "Transactions disabled — dropping transaction #{event_id}"
          return
        end
        transaction_name = item[:payload].is_a?(Hash) ? item[:payload]["transaction"] : nil
        if housekeeping_transaction?(transaction_name)
          Rails.logger.debug "Skipping housekeeping transaction: #{transaction_name}"
          return
        end

        enqueue(
          Ingest::Tuber::TRANSACTIONS_TUBE,
          {
            transaction_id: event_id,
            payload: item[:payload],
            project_id: project.id
          },
          kind: "transaction"
        )
        Rails.logger.debug "Queued transaction processing: #{event_id}"
      when "attachment"
        # Skip attachments for now - we don't need them for error tracking
        Rails.logger.debug "Skipping attachment item"
      else
        # Unknown item type - log but don't fail
        Rails.logger.info "Unknown item type: #{item_type}"
      end
    end

    def extract_event_id(payload)
      return nil unless payload.is_a?(Hash)
      payload[:event_id] || payload["event_id"]
    end

    def housekeeping_transaction?(name)
      return false unless name.is_a?(String)
      HOUSEKEEPING_TRANSACTION_PREFIXES.any? { |prefix| name.start_with?(prefix) }
    end

    # Enqueue an ingest job, self-reporting instead of silently dropping when the
    # put fails — either tuber rejected the job (too big) or tuber was
    # unreachable. Every failure lights up the local "ingestion degraded"
    # indicator (Ingest::Health, read by the web chrome) so the operator on THIS
    # instance sees it, and — mirroring the OTLP logs path — raises a
    # fingerprint-stable issue on the *upstream* monitoring Splat/Sentry
    # (ntfy/email) rather than the data vanishing with only a log line.
    def enqueue(tube, payload, kind:)
      Ingest::Tuber.put(tube, payload)
      true
    rescue Beaneater::JobTooBigError
      handle_undeliverable(
        tube, payload, kind,
        category: "job_too_big",
        reason: "job too big",
        detail: "exceeds tuber's max job size — raise TUBER_MAX_JOB_SIZE or shrink the payload"
      )
      false
    rescue *Ingest::Tuber::CONNECTION_ERRORS => e
      handle_undeliverable(
        tube, payload, kind,
        category: "tuber_unreachable",
        reason: "Tuber unreachable",
        detail: "could not reach tuber (#{e.class})"
      )
      false
    end

    def handle_undeliverable(tube, payload, kind, category:, reason:, detail:)
      Ingest::Health.record_failure(kind: kind, reason: reason)
      bytes = JSON.generate(payload).bytesize
      Rails.logger.warn(
        "[Envelope] dropped #{kind} (#{bytes} bytes) for project #{project.slug} — #{detail}"
      )

      # An outage produces one failure per inbound event, and if SENTRY_DSN
      # points back at this instance each report is itself an event — so throttle
      # the unreachable case to one upstream report per minute to avoid a storm /
      # feedback loop. A too-big rejection is per-payload (tuber is up), so it
      # reports every time.
      return if category == "tuber_unreachable" && !report_throttle_ok?

      Sentry.capture_message(
        "Ingest #{kind} dropped: #{detail}",
        level: :warning,
        fingerprint: ["ingest", category, kind],
        extra: {job_bytes: bytes, kind: kind, tube: tube, project: project.slug}
      )
    end

    # True at most once per minute across processes (Solid Cache marker).
    def report_throttle_ok?
      Rails.cache.write("ingest_unreachable_report", true, expires_in: 60, unless_exist: true)
    rescue
      true
    end
  end
end

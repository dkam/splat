# frozen_string_literal: true

module SentryProtocol
  class EnvelopeProcessor
    class InvalidEnvelope < StandardError; end

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
            if payload_lines.join("\n").bytesize + line.bytesize + 1 >= current_item["length"]
              # Last line of payload
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
            else
              payload_lines << line
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

      # Get event_id from payload first, then envelope headers, following GlitchTip pattern
      event_id = extract_event_id(item[:payload]) || envelope_headers[:event_id]

      unless event_id
        Rails.logger.error "Missing event_id in both payload and envelope headers for #{item_type} item"
        return # Skip this item but continue processing others
      end

      case item_type
      when "event"
        ProcessEventJob.perform_later(
          event_id: event_id,
          payload: item[:payload],
          project: project
        )
        Rails.logger.debug "Queued event processing: #{event_id}"
      when "transaction"
        ProcessTransactionJob.perform_later(
          transaction_id: event_id,
          payload: item[:payload],
          project: project
        )
        Rails.logger.debug "Queued transaction processing: #{event_id}"
      when "attachment"
        # Skip attachments for now - we don't need them for error tracking
        Rails.logger.debug "Skipping attachment item"
      when "session"
        # Skip session data for now
        Rails.logger.debug "Skipping session item"
      else
        # Unknown item type - log but don't fail
        Rails.logger.info "Unknown item type: #{item_type}"
      end
    end

    def extract_event_id(payload)
      return nil unless payload.is_a?(Hash)
      payload[:event_id] || payload['event_id']
    end
  end
end

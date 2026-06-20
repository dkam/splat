module Compression
  # Concern that gives a model a JSON payload column transparently
  # backed by `payload_blob BLOB` + `dict_id BIGINT NULL`.
  #
  # Usage:
  #   class Event < IssuesEventsRecord
  #     include Compression::CompressedJson
  #     compressed_json :payload,
  #       db: :issues_events,
  #       table: "events",
  #       platform: :platform   # method that returns the segment key, or nil
  #   end
  #
  # Reader is lazy: payload_blob is only decompressed on first access.
  # Writer stashes the value in memory; the encode happens in a before_save,
  # so there's exactly one INSERT and no follow-up UPDATE.
  module CompressedJson
    extend ActiveSupport::Concern

    included do
      class_attribute :_compressed_json_config, instance_accessor: false
      before_save :_encode_compressed_json
    end

    class_methods do
      def compressed_json(name, db:, table:, platform: nil)
        self._compressed_json_config = {
          name: name, db: db, table: table, platform: platform
        }

        define_method(name) do
          @_compressed_json_decoded ||= {}
          return @_compressed_json_decoded[name] if @_compressed_json_decoded.key?(name)
          @_compressed_json_decoded[name] =
            if payload_blob.nil?
              nil
            else
              Compression::Codec.decode_json(payload_blob, db: db, dict_id: dict_id)
            end
        end

        define_method("#{name}=") do |value|
          @_compressed_json_decoded ||= {}
          @_compressed_json_decoded[name] = value
          @_compressed_json_pending ||= {}
          @_compressed_json_pending[name] = true
        end
      end
    end

    private

    def _encode_compressed_json
      cfg = self.class._compressed_json_config
      return unless cfg
      pending = @_compressed_json_pending
      return unless pending && pending[cfg[:name]]

      value = @_compressed_json_decoded[cfg[:name]]
      platform_value = cfg[:platform] ? send(cfg[:platform]) : nil
      chosen = Compression::DictChooser.choose(
        db: cfg[:db],
        table: cfg[:table],
        project_id: respond_to?(:project_id) ? project_id : nil,
        platform: platform_value
      )

      self.payload_blob = value.nil? ? nil :
        Compression::Codec.encode(value.to_json, db: cfg[:db], dict_id: chosen)
      self.dict_id = chosen
      pending[cfg[:name]] = false
    end
  end
end

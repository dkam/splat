# frozen_string_literal: true

# Provides version information
# Reads from REVISION file (created during Docker build) or falls back to git
class VersionProvider
  class << self
    def current_version
      @current_version ||= read_revision_file || read_from_git || "unknown"
    end

    private

    def read_revision_file
      File.read(Rails.root.join("REVISION")).strip if File.exist?(Rails.root.join("REVISION"))
    rescue => e
      Rails.logger.warn "Failed to read REVISION file: #{e.message}"
      nil
    end

    def read_from_git
      `git describe --tags --always --dirty 2>/dev/null`.strip.presence
    rescue => e
      Rails.logger.warn "Failed to get git version: #{e.message}"
      nil
    end
  end
end
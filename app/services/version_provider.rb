# frozen_string_literal: true

# Provides version information based on git tags and commit hash
# Format: "v1.2.3-4-gabc123def" (tag-commits_since_tag-hash)
# Falls back to just hash if no tags exist
class VersionProvider
  class << self
    # Returns version based on git describe format
    # Examples:
    # - "v1.2.3" (exact tag)
    # - "v1.2.3-4-gabc123def" (4 commits after v1.2.3 tag)
    # - "abc123def" (no tags, just hash)
    def current_version
      return git_describe_version if git_available?

      # Fallback when git is not available
      "unknown-#{timestamp_fallback}"
    end

    # Returns git describe format output
    def git_describe_version
      # Get version from git describe --tags --always
      # --tags: finds the most recent tag
      # --always: falls back to commit hash if no tags
      version = `git describe --tags --always --dirty 2>/dev/null`.strip

      # Clean up the output and ensure it's usable
      return version if version.present?

      # Final fallback to just hash
      git_hash || "unknown"
    rescue => e
      Rails.logger.warn "Failed to get git describe version: #{e.message}"
      git_hash || "unknown-#{timestamp_fallback}"
    end

    # Returns just the tag portion (without commits since tag or hash)
    def latest_tag
      return nil unless git_available?

      # Get the most recent tag
      tag = `git describe --tags --abbrev=0 2>/dev/null`.strip
      tag.empty? ? nil : tag
    rescue => e
      Rails.logger.warn "Failed to get latest tag: #{e.message}"
      nil
    end

    # Returns number of commits since the latest tag
    def commits_since_tag
      return 0 unless git_available? && latest_tag.present?

      # Count commits since the latest tag
      count = `git rev-list --count #{latest_tag}..HEAD 2>/dev/null`.strip.to_i
      count
    rescue => e
      Rails.logger.warn "Failed to count commits since tag: #{e.message}"
      0
    end

    # Returns short git hash (7 characters)
    def git_hash
      return nil unless git_available?

      git_hash = `git rev-parse --short HEAD 2>/dev/null`.strip
      git_hash.empty? ? nil : git_hash
    rescue => e
      Rails.logger.warn "Failed to get git hash: #{e.message}"
      nil
    end

    # Check if git command is available and we're in a git repository
    def git_available?
      return @git_available if defined?(@git_available)

      @git_available = system('which git > /dev/null 2>&1') &&
                      system('git rev-parse --git-dir > /dev/null 2>&1')
    end

    # Timestamp fallback when git is not available
    def timestamp_fallback
      @timestamp_fallback ||= Time.current.strftime('%Y%m%d%H%M%S')
    end

    # Returns full version info for debugging
    def version_info
      {
        full_version: current_version,
        latest_tag: latest_tag,
        commits_since_tag: commits_since_tag,
        git_hash: git_hash,
        git_available: git_available?,
        dirty: dirty_working_directory?,
        build_time: Time.current.iso8601
      }
    end

    # Check if working directory has uncommitted changes
    def dirty_working_directory?
      return false unless git_available?

      # Check if there are any uncommitted changes
      !system('git diff --quiet 2>/dev/null') ||
      !system('git diff --cached --quiet 2>/dev/null')
    rescue => e
      Rails.logger.warn "Failed to check git status: #{e.message}"
      false
    end

    # Reset cached values (useful for testing)
    def reset_cache!
      @git_available = nil
    end
  end
end
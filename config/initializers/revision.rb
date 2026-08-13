# frozen_string_literal: true

# The commit this build came from, so "which revision is actually running?" is
# answerable without guessing.
#
# The Dockerfile writes VERSION at build time from a --build-arg GIT_SHA.
# Outside a container there is no such file, so fall back to asking git — but
# only in development, because shelling out on boot is not something a deployed
# container should do, and it has a VERSION file anyway.
#
# See config/version.rb for why this is a separate thing from Splat::VERSION.
Rails.application.config.x.revision = begin
  version_file = Rails.root.join("VERSION")
  from_file = version_file.exist? ? version_file.read.strip.presence : nil

  from_git =
    if from_file.nil? && Rails.env.development?
      `git rev-parse --short HEAD 2>/dev/null`.strip.presence
    end

  from_file || from_git || ENV["GIT_SHA"].presence || "unknown"
end

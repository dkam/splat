# frozen_string_literal: true

# Splat's release version — SemVer, bumped by hand at meaningful milestones.
# Single source of truth: required early from config/application.rb, tagged as
# :vX.Y.Z by bin/build and CI, used as the Sentry release, and shown on the
# Settings → About page. Lives in its own file so build scripts can read it
# (`ruby -e "require './config/version'; puts Splat::VERSION"`) without booting
# Rails.
module Splat
  VERSION = "1.1.0"
end

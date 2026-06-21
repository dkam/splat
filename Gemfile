source "https://rubygems.org"

# Bundle edge Rails instead: gem "rails", github: "rails/rails", branch: "main"
gem "rails", "~> 8.1.3"
# The modern asset pipeline for Rails [https://github.com/rails/propshaft]
gem "propshaft"
# Use sqlite3 as the database for Active Record
gem "sqlite3", ">= 2.1"
# Use the Puma web server [https://github.com/puma/puma]
gem "puma", ">= 5.0"
# Use JavaScript with ESM import maps [https://github.com/rails/importmap-rails]
gem "importmap-rails"
# Hotwire's SPA-like page accelerator [https://turbo.hotwired.dev]
gem "turbo-rails"
# Hotwire's modest JavaScript framework [https://stimulus.hotwired.dev]
gem "stimulus-rails"
# Use Tailwind CSS [https://github.com/rails/tailwindcss-rails]
gem "tailwindcss-rails"
# Build JSON APIs with ease [https://github.com/rails/jbuilder]
gem "jbuilder"

# Use Active Model has_secure_password [https://guides.rubyonrails.org/active_model_basics.html#securepassword]
# gem "bcrypt", "~> 3.1.7"

# Windows does not include zoneinfo files, so bundle the tzinfo-data gem
gem "tzinfo-data", platforms: %i[windows jruby]

# Use the database-backed adapters for Rails.cache and Action Cable.
# Active Job runs on tuber via the custom adapter — see lib/active_job/queue_adapters/tuber_adapter.rb
gem "solid_cache"
gem "solid_cable"

# Tuber/beanstalkd client for batched ingest. Fork adds reserve_batch on top of
# upstream beaneater 1.1.4, so we pin to the branch rather than rubygems.
gem "beaneater", git: "https://github.com/dkam/beaneater.git", branch: "tuber"

# Drives the recurring scheduler (config/schedule.yml → tuber).
gem "rufus-scheduler", "~> 3.9"

# Load environment variables from .env file
gem "dotenv-rails", groups: [:development, :test]

# Pagination
gem "pagy", "~> 9.0"

# Reduces boot times through caching; required in config/boot.rb
gem "bootsnap", require: false

# OpenID Connect authentication (direct approach)
gem "openid_connect"

# JWT token handling and verification
gem "jwt"

# Deploy this application anywhere as a Docker container [https://kamal-deploy.org]
gem "kamal", require: false

# Brotli compression support for Sentry envelopes
gem "brotli"

# Zstandard compression support for Sentry envelopes
gem "zstd-ruby"

# Add HTTP asset caching/compression and X-Sendfile acceleration to Puma [https://github.com/basecamp/thruster/]
gem "thruster", require: false

group :development, :test do
  # See https://guides.rubyonrails.org/debugging_rails_applications.html#debugging-with-the-debug-gem
  gem "debug", platforms: %i[mri windows], require: "debug/prelude"

  # Audits gems for known security defects (use config/bundler-audit.yml to ignore issues)
  gem "bundler-audit", require: false

  # Static analysis for security vulnerabilities [https://brakemanscanner.org/]
  gem "brakeman", require: false

  # Ruby style guide, linter, and formatter [https://github.com/standardrb/standard]
  gem "standard", "~> 1.51", require: false
end

group :development do
  # Use console on exceptions pages [https://github.com/rails/web-console]
  gem "web-console"

  # Preview emails in browser instead of sending
  gem "letter_opener"
end

group :test do
  # Use system testing [https://guides.rubyonrails.org/testing.html#system-testing]
  gem "capybara"
  gem "selenium-webdriver"
end

gem "sentry-rails"

# frozen_string_literal: true

class Current < ActiveSupport::CurrentAttributes
  attribute :splat_host
  attribute :splat_internal_host
  attribute :project
  attribute :ip

  def self.splat_host
    @splat_host || ENV.fetch("SPLAT_HOST", "localhost:3000")
  end

  def self.splat_internal_host
    @splat_internal_host || ENV.fetch("SPLAT_INTERNAL_HOST", nil)
  end
end

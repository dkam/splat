# frozen_string_literal: true

class Current < ActiveSupport::CurrentAttributes
  attribute :splat_host
  attribute :project

  def self.splat_host
    @splat_host || ENV.fetch("SPLAT_HOST", "localhost:3000")
  end
end

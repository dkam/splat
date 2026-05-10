# frozen_string_literal: true

# ActiveJob::QueueAdapters.lookup uses const_get; built-in adapters are
# autoloaded but custom ones must already be defined. Eagerly require ours
# before any deliver_later runs.
require Rails.root.join("lib", "active_job", "queue_adapters", "tuber_adapter")

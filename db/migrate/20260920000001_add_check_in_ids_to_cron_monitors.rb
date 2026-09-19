# frozen_string_literal: true

# Pair the two check-ins of a single run by their check_in_id, so an
# out-of-order envelope can't leave the overrun clock running forever.
#
# A run reports twice — in_progress then ok/error — as two separate envelopes
# sharing one check_in_id. The SDK posts both through a thread pool, so the
# terminal one can reach us first. Latest-writer-wins then set
# in_progress_since back to now with nothing left to clear it, and the sweep
# called that an overrun ~every time it happened.
class AddCheckInIdsToCronMonitors < ActiveRecord::Migration[8.1]
  def change
    add_column :cron_monitors, :in_progress_check_in_id, :string
    add_column :cron_monitors, :last_terminal_check_in_id, :string
  end
end

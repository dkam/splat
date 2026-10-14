# frozen_string_literal: true

module Ingest
  # Runs in the ingest worker beside the tube consumers: puts what the web
  # spooled while tuber was down (Ingest::Spool) back on its tubes once tuber
  # answers again.
  class SpoolReplayer
    # An empty spool costs a directory listing, so checking often is cheap;
    # it's also how long a replayer takes to notice it's been stopped.
    INTERVAL = 2

    def initialize(interval: INTERVAL)
      @interval = interval
      @stop = false
    end

    def stop!
      @stop = true
    end

    def run
      until @stop
        begin
          replayed = Spool.replay
          Rails.logger.info("[SpoolReplayer] put #{replayed} spooled job(s) back on tuber") if replayed.positive?
        rescue => e
          Rails.logger.error("[SpoolReplayer] #{e.class}: #{e.message}")
        end
        sleep @interval
      end
    end
  end
end

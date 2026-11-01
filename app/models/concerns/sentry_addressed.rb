# frozen_string_literal: true

# Events and transactions are addressed by the id their SDK gave them —
# event_id, transaction_id — rather than the row id. It's the id an app has in
# hand (Sentry.last_event_id, an error page's reference), so it's what URLs
# carry and what MCP's get_event and get_transaction take. A row id still finds
# the record: links made before URLs carried the Sentry id use one.
#
# The Sentry id is unique only behind project_id, and its index is usable only
# with project_id pinned, so look records up through a project's relation or
# with project_id given (SplatMcpTools#every_project_id).
module SentryAddressed
  extend ActiveSupport::Concern

  # Sentry ids are 32 hex characters, and about one in 3.4 million is all
  # digits — rare, but splat-booko holds tens of millions of transactions.
  def self.row_id?(id) = id.to_s.match?(/\A\d{1,31}\z/)

  # Ingest keeps whatever id the client sent. One with a dot would route as a
  # format (abc.def is id abc, format def) and an all-digit one as a row id, so
  # those are addressed by row id instead.
  def self.url_safe?(sentry_id) = sentry_id.to_s.match?(/\A[\w-]+\z/) && !row_id?(sentry_id)

  class_methods do
    # Scoped like any finder: @project.events.find_by_param!(params[:id]).
    def find_by_param!(id)
      SentryAddressed.row_id?(id) ? find(id) : find_by!(sentry_id_column => id.to_s)
    end
  end

  def to_param
    sentry_id = self[self.class.sentry_id_column]
    SentryAddressed.url_safe?(sentry_id) ? sentry_id : super
  end
end

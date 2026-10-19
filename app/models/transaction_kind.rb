# frozen_string_literal: true

# What sort of work a transaction measured: a web request, a background job, or
# something else (an Action Cable connection, a browser pageload, an op this
# doesn't recognise). The SDK says so in contexts.trace.op, and Transaction
# keeps it as `op` — but the hourly rollups the performance pages read are keyed
# by name, not op, and outlive the raw rows by a year or more.
#
# A transaction name always measures the same kind of work (a controller action
# is never a job), so instead of an op dimension on the rollups this keeps a
# per-project lookup from name to kind, and filters the rollups by name. It's a
# Facet stream: (project, "transaction_kind", kind, transaction_name), harvested
# at ingest and throttled like the environment facet.
#
# Only the job and other names are stored. Web names are most of a project's
# names — every scanner path a bot tries is one — while jobs are a few dozen
# classes, so web is "everything not listed". That's also the safe default for
# a name nothing classified: one whose raw rows aged out before this lookup
# existed reads as web.
#
# Pruned on the rollup clock, not the raw one, so a name keeps its kind as long
# as any rollup row for it does.
module TransactionKind
  STREAM = "transaction_kind"

  KINDS = %w[web job other].freeze

  LABELS = {"web" => "Web", "job" => "Jobs", "other" => "Other"}.freeze
  NOUNS = {"web" => "requests", "job" => "jobs", "other" => "other"}.freeze

  # http.server is every server SDK's op for a request: Rack and Rails in the
  # Ruby SDK, and Django, Flask, Express, net/http in the others. A job's op
  # changed under sentry-rails 7 — queue.active_job before, queue.process
  # after — and Celery's is queue.task.celery, so jobs match on the prefix.
  def self.classify(op)
    op = op.to_s
    if op == "http.server" then "web"
    elsif op.start_with?("queue.") then "job"
    else "other"
    end
  end

  # Ingest path. A no-op for web, which is the default rather than a stored
  # kind.
  def self.harvest!(project_id:, transaction_name:, op:, seen_at: Time.current)
    kind = classify(op)
    return if kind == "web" || transaction_name.blank?

    Facet.harvest!(project_id: project_id, stream: STREAM, values: {kind => transaction_name}, seen_at: seen_at)
  end

  # The project's lookup. Without a project, every project's names pooled: a
  # name that's a job in one project and a request in another is rare enough
  # not to split the cross-project MCP reads over.
  def self.lookup(project_id)
    scope = Facet.where(stream: STREAM)
    scope = scope.where(project_id: project_id) if project_id
    Lookup.new(scope.distinct.pluck(:name, :value))
  end

  # Nil for "all kinds", so a blank or unknown param reads as no filter.
  def self.normalize(kind)
    kind = kind.to_s
    kind if KINDS.include?(kind)
  end

  class Lookup
    attr_reader :job_names, :other_names

    def initialize(pairs)
      by_kind = pairs.group_by(&:first).transform_values { |rows| rows.map(&:last) }
      @job_names = by_kind.fetch("job", []).uniq
      # A name stored under both wins as a job, so every name has one kind and
      # the three filters partition the rollups.
      @other_names = by_kind.fetch("other", []).uniq - @job_names
      @jobs = @job_names.to_set
      @others = @other_names.to_set
    end

    def kind_of(name)
      if @jobs.include?(name) then "job"
      elsif @others.include?(name) then "other"
      else "web"
      end
    end

    # [sql, binds] restricting `column` to one kind, or nil for no restriction.
    def clause(kind, column: "transaction_name")
      case kind
      when "job" then in_clause(column, @job_names)
      when "other" then in_clause(column, @other_names)
      when "web"
        listed = @job_names + @other_names
        ["#{column} NOT IN (#{placeholders(listed)})", listed] if listed.any?
      end
    end

    private

    # An empty kind matches nothing, rather than dropping the clause and
    # matching everything.
    def in_clause(column, names)
      return ["1 = 0", []] if names.empty?

      ["#{column} IN (#{placeholders(names)})", names]
    end

    def placeholders(names) = (["?"] * names.size).join(", ")
  end
end

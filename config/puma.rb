# This configuration file will be evaluated by Puma. The top-level methods that
# are invoked here are part of Puma's configuration DSL. For more information
# about methods provided by the DSL, see https://puma.io/puma/Puma/DSL.html.
#
# Puma starts a configurable number of processes (workers) and each process
# serves each request in a thread from an internal thread pool.
#
# You can control the number of workers using ENV["WEB_CONCURRENCY"]. You
# should only set this value when you want to run 2 or more workers. The
# default is already 1. You can set it to `auto` to automatically start a worker
# for each available processor.
#
# The ideal number of threads per worker depends both on how much time the
# application spends waiting for IO operations and on how much you wish to
# prioritize throughput over latency.
#
# As a rule of thumb, increasing the number of threads will increase how much
# traffic a given process can handle (throughput), but due to CRuby's
# Global VM Lock (GVL) it has diminishing returns and will degrade the
# response time (latency) of the application.
#
# The default is set to 3 threads as it's deemed a decent compromise between
# throughput and latency for the average Rails application.
#
# Any libraries that use a connection pool or another resource pool should
# be configured to provide at least as many connections as the number of
# threads. This includes Active Record's `pool` parameter in `database.yml`.
threads_count = ENV.fetch("RAILS_MAX_THREADS", 5)
threads threads_count, threads_count

# Specifies the `port` that Puma will listen on to receive requests; default is 3000.
port ENV.fetch("PORT", 3000)

# With WEB_CONCURRENCY above 1, Puma preloads the app and forks a worker per
# process. That's how Splat keeps the UI and ingest answering while a long
# query holds one process: the sqlite3 gem keeps the GVL for a whole statement,
# so more threads in one process wouldn't help. Connections must not cross the
# fork — the same reasons as Ingest::Supervisor#disconnect_all. Only declared
# with workers: in single mode Puma warns at boot about a hook it won't run.
web_concurrency = ENV.fetch("WEB_CONCURRENCY", "0")
if web_concurrency == "auto" || web_concurrency.to_i > 0
  before_fork do
    ActiveRecord::Base.connection_handler.clear_all_connections!(:all)
    Ingest::Tuber.reset_producer!
  end
end

# Sentry's 20 MB limit on a request as sent (Ingest::Decompression::MAX_SENT;
# the app isn't loaded yet to read it), answered with a 413 before Rails sees
# the request. The ingest endpoints check it themselves too, but Rails parses a
# body typed as JSON for its request log before any controller runs.
http_content_length_limit 20 * 1024 * 1024

# Allow puma to be restarted by `bin/rails restart` command.
plugin :tmp_restart

# Specify the PID file. Defaults to tmp/pids/server.pid in development.
# In other environments, only set the PID file if requested.
pidfile ENV["PIDFILE"] if ENV["PIDFILE"]

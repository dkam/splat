ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

# logs_fts (FTS5 virtual table + triggers) can't be represented in schema.rb, so
# rails/test_help's schema maintenance drops what the boot initializer created.
# Recreate it after the harness loads (covers single-process runs); parallel
# workers are covered by parallelize_setup below.
begin
  Logs::Fts.ensure!
rescue => e
  warn "[test_helper] logs_fts ensure skipped: #{e.class}: #{e.message}"
end

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # Each parallel worker gets its own DB loaded from schema.rb, which can't
    # represent the logs_fts FTS5 virtual table/triggers — recreate them per
    # worker so full-text log search works in tests. (The boot initializer only
    # covers the single-process path.)
    parallelize_setup do |_worker|
      Logs::Fts.ensure!
    end

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # The facet write throttles remember a key per process, and a rolled-back
    # test frees its ids for the next one: a later test's issue 3 harvesting
    # "id:1" was skipped as already written by an earlier test's issue 3.
    setup do
      Facet.reset_throttle!
      IssueFacet.reset_throttle!
    end

    # Jobs spooled while tuber is down go to a directory of the test's own, so
    # parallel workers never replay each other's.
    setup { Ingest::Spool.dir = Dir.mktmpdir("spool") }
    teardown do
      FileUtils.rm_rf(Ingest::Spool.dir)
      Ingest::Spool.dir = nil
      Ingest::Spool.max_bytes = nil
    end

    # Temporarily replace a singleton (class) method, restoring the *real* one
    # afterward. Minitest 6 dropped #stub, and the obvious
    # `singleton_class.define_method` + `remove_method` dance deletes the
    # original method for the rest of the worker process — which silently broke
    # whichever test ran next in the same parallel worker (e.g. "undefined
    # method 'put' for Ingest::Tuber"). Capturing and re-installing the original
    # Method object avoids that.
    def with_stub(owner, name, replacement)
      original = owner.method(name)
      owner.singleton_class.define_method(name, replacement)
      yield
    ensure
      owner.singleton_class.define_method(name, original)
    end

    # A request body in one of the Content-Encodings ingest reads.
    def compress(encoding, text)
      compressed(encoding) { |write| write.call(text) }
    end

    # bytes of zeros, compressed a megabyte at a time: a body that's small as
    # sent and enormous once decompressed, built without holding it all.
    def compressed_zeros(encoding, bytes)
      megabyte = "\0" * 1.megabyte
      compressed(encoding) { |write| (bytes / megabyte.bytesize).times { write.call(megabyte) } }
    end

    def compressed(encoding)
      io = StringIO.new(+"".b)
      case encoding
      when "gzip"
        gz = Zlib::GzipWriter.new(io)
        yield ->(data) { gz.write(data) }
        gz.finish
      when "deflate"
        zd = Zlib::Deflate.new
        yield ->(data) { io.write(zd.deflate(data)) }
        io.write(zd.finish)
      when "zstd"
        zs = Zstd::StreamingCompress.new
        yield ->(data) { io.write(zs.compress(data)) }
        io.write(zs.finish)
      end
      io.string
    end
  end
end

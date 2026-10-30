# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "fileutils"
require "socket"
require "timeout"

module Simplefreen
  # Boots the real bin/simplefreen with stdout on a pipe (as under Docker)
  # and checks log lines arrive while it runs, not only at exit. Ruby
  # block-buffers a piped $stdout, so without `$stdout.sync = true` the
  # lambda-logged lines stayed invisible to `docker logs`.
  class BinSimplefreenTest < Minitest::Test
    BIN = File.expand_path("../bin/simplefreen", __dir__)

    def setup
      @root          = Dir.mktmpdir("simplefreen-bin-")
      @workflows_dir = Dir.mktmpdir("simplefreen-bin-wf-")
    end

    def teardown
      if @pid
        Process.kill("KILL", @pid) rescue nil
        Process.wait(@pid) rescue nil
      end
      @out&.close
      FileUtils.rm_rf(@root)
      FileUtils.rm_rf(@workflows_dir)
    end

    def free_port
      s = TCPServer.new("127.0.0.1", 0); port = s.addr[1]; s.close; port
    end

    def test_runtime_log_lines_are_flushed_while_running
      port = free_port
      env = {
        "SIMPLEFREEN_SECRETS_KEY"    => Crypto.generate_master_key_b64,
        "SIMPLEFREEN_ADMIN_PASSWORD" => "admin-pw",
        "SIMPLEFREEN_PUBLIC_URL"     => "http://simplefreen.example",
        "SIMPLEFREEN_ROOT"           => @root,
        # A closed loopback port: the health probe fails fast, no network.
        "FREENTONIC_URL"             => "http://127.0.0.1:#{free_port}",
        "FREENTONIC_INVOKE_TOKEN"    => "t",
        "SIMPLEFREEN_NTFY_URL"       => nil
      }
      @out, writer = IO.pipe
      @pid = Process.spawn(env, RbConfig.ruby, BIN,
                           "--listen-addr", "127.0.0.1", "--listen-port", port.to_s,
                           "--workflows-dir", @workflows_dir,
                           out: writer, err: File::NULL)
      writer.close
      read_until("listening on")

      # Startup lines get flushed incidentally by Server#log; a runtime line
      # from the feature logger (here: a rejected push) has nothing after it
      # to flush the buffer, so it is the one that went missing.
      sock = TCPSocket.new("127.0.0.1", port)
      sock.write("POST /push/simplefreen-acme-1 HTTP/1.1\r\nHost: x\r\n" \
                 "Authorization: Bearer forged\r\nContent-Length: 2\r\n\r\n{}")
      assert_match(/\AHTTP\/1\.1 401/, sock.gets.to_s)
      sock.close

      line = read_until("push rejected")
      assert_includes line, "run_id=simplefreen-acme-1"
      assert_nil Process.wait(@pid, Process::WNOHANG), "line must arrive while the process is still running"
    end

    def read_until(needle, timeout: 10)
      Timeout.timeout(timeout) do
        loop do
          l = @out.gets or flunk("simplefreen exited before logging #{needle.inspect}")
          return l if l.include?(needle)
        end
      end
    end
  end
end

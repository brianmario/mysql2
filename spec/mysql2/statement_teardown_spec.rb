require 'spec_helper'
require 'weakref'
require 'open3'
require 'tmpdir'
require 'shellwords'
require 'rbconfig'

RSpec.describe 'prepared statement teardown' do
  it 'clears the closed connection registry and allows discarded statements to be collected' do
    references = new_thread do
      Array.new(5) { WeakRef.new(@client.prepare('SELECT 1')) }
    end.value
    @client.close
    expect(@client.prepared_statements).to eq([])
    GC.start
    expect(references.none?(&:weakref_alive?)).to eq(true)
  end

  it 'allows an application-held statement to close after its connection' do
    statement = @client.prepare('SELECT 1')
    @client.close
    expect { statement.close }.not_to raise_error
    expect(statement.closed?).to eq(true)
    expect { statement.close }.not_to raise_error
  end

  it 'clears the statement registry after discarding a connection' do
    statement = @client.prepare('SELECT 1')
    @client.discard!
    expect(@client.prepared_statements).to eq([])
    expect { statement.close }.not_to raise_error
  end

  context 'native allocation balance' do
    before(:context) do
      skip 'native allocation interposition fixture requires macOS' unless RUBY_PLATFORM.include?('darwin')

      @probe_directory = Dir.mktmpdir('mysql2-statement-lifetime')
      @probe_library = File.join(@probe_directory, 'statement-lifetime.dylib')
      config = ENV.fetch('MYSQL_CONFIG', 'mysql_config')
      flags, flag_status = Open3.capture2e(config, '--cflags')
      libraries, library_status = Open3.capture2e(config, '--libs')
      raise 'mysql_config failed for native lifetime fixture' unless flag_status.success? && library_status.success?

      source = File.expand_path('../support/statement_lifetime.c', __dir__)
      # The dynamic client library resolves its own transitive dependencies.
      client_libraries = Shellwords.split(libraries).select do |flag|
        flag.start_with?('-L') || ['-lmysqlclient', '-lmariadb'].include?(flag)
      end
      command = Shellwords.split(RbConfig::CONFIG.fetch('CC')) + ['-dynamiclib'] +
                Shellwords.split(flags) + [source] + client_libraries + ['-o', @probe_library]
      output, status = Open3.capture2e(*command)
      raise "Native lifetime fixture build failed: #{output}" unless status.success?
    end

    after(:context) do
      FileUtils.remove_entry(@probe_directory) if @probe_directory
    end

    %w[gc close discard queued].each do |mode|
      it "releases every native handle after #{mode}" do
        script = <<-'RUBY'
          require 'mysql2'
          require 'yaml'
          require 'fiddle'
          counter = Fiddle::Function.new(Fiddle::Handle::DEFAULT['mysql2_test_live_statements'], [], Fiddle::TYPE_LONG)
          Thread.new do
            connection = Mysql2::Client.new(YAML.load_file('spec/configuration.yml')['root'])
            5.times do
              if ARGV.first == 'queued'
                begin
                  connection.prepare('invalid SQL')
                rescue Mysql2::Error
                end
              else
                connection.prepare('SELECT 1').execute
              end
            end
            GC.start if ARGV.first == 'queued'
            connection.close if ['close', 'queued'].include?(ARGV.first)
            connection.discard! if ARGV.first == 'discard'
            nil
          end.join
          GC.start
          raise "unreleased native statements: #{counter.call}" unless counter.call == 0
        RUBY
        library_file = $LOADED_FEATURES.find { |path| path.end_with?('/lib/mysql2.rb') }
        extension_file = $LOADED_FEATURES.find { |path| path.end_with?('/mysql2/mysql2.bundle') }
        command = [RbConfig.ruby, "-I#{File.dirname(library_file)}",
                   "-I#{File.dirname(File.dirname(extension_file))}", '-e', script, mode,]
        output, status = Open3.capture2e({ 'DYLD_INSERT_LIBRARIES' => @probe_library }, *command)
        expect(status.success?).to eq(true), output
      end
    end
  end
end

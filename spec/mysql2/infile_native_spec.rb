require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'open3'
require 'rbconfig'
require 'shellwords'

RSpec.describe 'LOCAL INFILE native error recovery' do
  before(:context) do
    skip 'the native callback fixture requires a POSIX C compiler' if RUBY_PLATFORM =~ /mswin|mingw/

    @native_directory = Dir.mktmpdir('mysql2-infile-regression')
    @native_binary = File.join(@native_directory, 'infile-regression')
    source = File.expand_path('../native/infile/regression.c', __dir__)
    include_dir = File.dirname(source)
    driver = ENV.fetch('MYSQL2_INFILE_SOURCE', File.expand_path('../../ext/mysql2/infile.c', __dir__))
    command = Shellwords.split(RbConfig::CONFIG.fetch('CC')) +
              ['-I', include_dir, "-DMYSQL2_INFILE_SOURCE=\"#{driver}\"", source, '-o', @native_binary]
    output, status = Open3.capture2e(*command)
    raise "Cannot compile LOCAL INFILE regression: #{output}" unless status.success?
  end

  after(:context) do
    FileUtils.remove_entry(@native_directory) if @native_directory
  end

  %w[malloc strdup open_eintr open_error read_eintr read_error eof success].each do |scenario|
    it "handles #{scenario} without touching unrelated descriptors or retrying an interrupted call" do
      output, status = Open3.capture2e(@native_binary, scenario)
      expect(status.success?).to eq(true), output
    end
  end
end

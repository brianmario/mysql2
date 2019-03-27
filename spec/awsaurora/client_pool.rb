# frozen_string_literal: true

require 'mysql2'
require 'mysql2/awsaurora'
require 'yaml'

class ClientPool
  YAML_PATH = 'spec/configuration.yml'

  def self.client_class
    Mysql2::AWSAurora::Client
  end

  def self.setup!
    reload_default_options!
  end

  def self.reload_default_options!
    @default_options = nil
  end

  def self.default_options
    @default_options ||= YAML.safe_load(File.read(YAML_PATH))['aws']
  end

  def initialize(options = {})
    @options = self.class.default_options.dup.tap do |opt|
      options.each { |k, v| opt[k.to_s] = v }
    end
  end

  def with_clients(&block)
    clients = Array.new(block.arity) { self.class.client_class.new(@options) }
    yield(*clients)
  ensure
    clients&.each(&:close)
  end
end

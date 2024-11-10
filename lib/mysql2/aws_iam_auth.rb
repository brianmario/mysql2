require 'singleton'

module Mysql2
  # Generates and caches AWS IAM Authentication tokens to use in place of MySQL user passwords
  class AwsIamAuth
    include Singleton
    attr_reader :mutex
    attr_accessor :passwords

    # Tokens are valid for up to 15 minutes.
    # We will assume ours expire in 14 minutes to be safe.
    TOKEN_EXPIRES_IN = (60 * 14) # 14 minutes

    def initialize
      begin
        require 'aws-sdk-rds'
      rescue LoadError
        puts "gem aws-sdk-rds was not found.  Please add this gem to your bundle to use AWS IAM Authentication."
        exit
      end

      @mutex = Mutex.new
      # Key identifies a unique set of authentication parameters
      # Value is a Hash
      # :password is the token value
      # :expires_at is (just before) the token was generated plus 14 minutes
      @passwords = {}
      instance_credentials = Aws::InstanceProfileCredentials.new
      @generator = Aws::RDS::AuthTokenGenerator.new(:credentials => instance_credentials)
    end

    def password(user, host, port, opts)
      params = to_params(user, host, port, opts)
      key = key_from_params(params)
      passwd = nil
      AwsIamAuth.instance.mutex.synchronize do
        begin
          passwd = @passwords[key][:password] if @passwords.dig(key, :password) && Time.now.utc < @passwords.dig(key, :expires_at)
        rescue KeyError
          passwd = nil
        end
      end
      return passwd unless passwd.nil?

      AwsIamAuth.instance.mutex.synchronize do
        @passwords[key] = {}
        @passwords[key][:expires_at] = Time.now.utc + TOKEN_EXPIRES_IN
        @passwords[key][:password] = password_from_iam(params)
      end
    end

    def password_from_iam(params)
      @generator.auth_token(params)
    end

    def to_params(user, host, port, opts)
      params = {}
      params[:region] = opts[:host_region] || ENV['AWS_REGION']
      params[:endpoint] = "#{host}:#{port}"
      params[:user_name] = user
      params
    end

    def key_from_params(params)
      "#{params[:user_name]}/#{params[:endpoint]}/#{params[:region]}"
    end
  end
end

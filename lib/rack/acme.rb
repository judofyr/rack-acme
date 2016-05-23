require "rack/acme/version"
require "acme-client"
require "json"

module Rack
  class Acme
    def initialize(app, options = {})
      @app = app
      @on_setup = options.delete(:on_setup)
      @on_challenge = options.delete(:on_challenge)
      @challenge_store = options.delete(:challenge_store)
      if @challenge_store.nil?
        raise ArgumentError, ":challenge_store option is required"
      end
      @client = ::Acme::Client.new(options)

      instance_eval(&@on_setup) if @on_setup
    end

    CHALLENGE_PREFIX = '/.well-known/acme-challenge/'.freeze

    NOT_FOUND = [404, {'Content-Type' => 'text/plain'}, ['Challenge not found']]

    def call(env)
      env['rack-acme'.freeze] = self

      path = env['PATH_INFO'.freeze]

      if path.start_with?(CHALLENGE_PREFIX)
        token = path[CHALLENGE_PREFIX.size..-1]
        challenge_str = @challenge_store[token]
        if challenge_str.nil?
          return NOT_FOUND
        end

        challenge = @client.challenge_from_hash(JSON.parse(challenge_str))

        status = 200
        headers = {'Content-Type' => challenge.content_type}
        body = [challenge.file_content]
        poll_for_response(challenge)
        return [status, headers, body]
      end

      @app.call(env)
    end

    def poll_for_response(challenge)
      Thread.new do
        status = nil
        5.times do |n|
          sleep(1 + n**2)
          status = challenge.verify_status
          if status != 'pending'.freeze
            break
          end
        end

        @challenge_store.delete(challenge.token)
        @on_challenge.call(challenge, status) if @on_challenge
      end
    end

    def authorize(options)
      authorization = @client.authorize(options)
      challenge = authorization.http01
      @challenge_store[challenge.token] = challenge.to_h.to_json
      challenge.request_verification
      challenge
    end

    def register(options)
      @client.register(options)
    end

    def new_certificate(csr)
      @client.new_certificate(csr)
    end

    class RedisStore
      def initialize(redis, prefix = "rackacme:")
        @redis = redis
        @prefix = prefix
      end

      def [](key)
        @redis.get(@prefix+key)
      end

      def []=(key, value)
        @redis.set(@prefix+key, value)
      end

      def delete(key)
        @redis.del(@prefix+key)
      end
    end
  end
end


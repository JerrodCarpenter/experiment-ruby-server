require 'net/http'
require 'json'
require 'uri'
require 'logger'

module Experiment
  # Main client for fetching variant data.
  class Client
    # Creates a new Experiment Client instance.
    #
    # @param [String] api_key The environment API Key
    # @param [Config] config
    def initialize(api_key, config = nil)
      @api_key = api_key
      @config = config || Config.new
      @logger = Logger.new($stdout)
      @logger.level = if @config.debug
                        Logger::DEBUG
                      else
                        Logger::INFO
                      end
      raise ArgumentError, 'Experiment API key is empty' if @api_key.nil? || @api_key.empty?
    end

    # Fetch all variants for a user.
    #
    # This method will automatically retry if configured (default).
    # @param [User] user
    def fetch(user, &callback)
      thread = Thread.new do
        variants = fetch_internal(user)
        yield(user, variants) unless callback.nil?
        return variants
      rescue StandardError => e
        @logger.error("[Experiment] Failed to fetch variants: #{e.message}")
        yield(user, {}) unless callback.nil?
        return {}
      end
      thread.begin
    end

    private

    # @param [User] user
    def fetch_internal(user)
      @logger.debug("[Experiment] Fetching variants for user: #{user}")
      do_fetch(user, @config.fetch_timeout_millis)
    rescue StandardError => e
      @logger.error("[Experiment] Fetch failed: #{e.message}")
      begin
        return retry_fetch(user)
      rescue StandardError => err
        @logger.error(err.message)
      end
      throw e
    end

    # @param [User] user
    def retry_fetch(user)
      return {} if @config.fetch_retries.zero?

      @logger.debug('[Experiment] Retrying fetch')
      delay_millis = @config.fetch_retry_backoff_min_millis
      err = nil
      @config.fetch_retries.times do
        sleep(delay_millis)
        begin
          return do_fetch(user, @config.fetch_retry_timeout_millis)
        rescue StandardError => e
          @logger.error("[Experiment] Retry failed: #{e.message}")
          err = e
        end
        delay_millis = [delay_millis * @config.fetch_retry_backoff_scalar, @config.fetch_retry_backoff_max_millis].min
      end
      throw err unless err.nil?
    end

    # @param [User] user
    # @param [Integer] timeout_millis
    def do_fetch(user, timeout_millis)
      start_time = Time.now
      user_context = add_context(user)
      endpoint = "#{@config.server_url}/sdk/vardata"
      headers = {
        'Authorization' => "Api-Key #{@api_key}",
        'Content-Type' => 'application/json;charset=utf-8'
      }
      uri = URI(endpoint)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.read_timeout = timeout_millis / 1000 if (timeout_millis / 1000) > 0
      request = Net::HTTP::Post.new(uri, headers)
      request.body = user_context.to_json
      if request.body.length > 8000
        @logger.warn("[Experiment] encoded user object length #{request.body.length} cannot be cached by CDN; must be < 8KB")
      end
      @logger.debug("[Experiment] Fetch variants for user: #{request.body}")
      response = http.request(request)
      end_time = Time.now
      elapsed = (end_time - start_time) * 1000.0
      @logger.debug("[Experiment] Fetch complete in #{elapsed.round(3)} ms")
      json = JSON.parse(response.body)
      variants = parse_json_variants(json)
      @logger.debug("[Experiment] Fetched variants: #{variants}")
      variants
    end

    # Parse JSON response hash
    #
    # @param [Hash] json
    # @return [Hash] Hash with String => Variant
    def parse_json_variants(json)
      variants = {}
      json.each do |key, value|
        variant_value = ''
        if value.key?('value')
          variant_value = value.fetch('value')
        elsif value.key?('key')
          # value was previously under the "key" field
          variant_value = value.fetch('key')
        end
        variants.store(key, Variant.new(variant_value, value.fetch('payload')))
      end
      variants
    end

    # @param [User] user
    # @return [User, Hash] user with library context
    def add_context(user)
      user = {} if user.nil?
      user.library = "experiment-ruby-server/#{VERSION}" if user.library.nil?
      user
    end
  end
end
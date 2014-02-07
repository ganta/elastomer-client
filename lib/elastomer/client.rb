require 'addressable/template'
require 'faraday'
require 'multi_json'

require 'elastomer/version'

module Elastomer

  class Client

    # Create a new client that can be used to make HTTP requests to the
    # ElasticSearch server.
    #
    # opts - The options Hash
    #   :host - the host as a String
    #   :port - the port number of the server
    #   :url  - the URL as a String (overrides :host and :port)
    #   :read_timeout - the timeout in seconds when reading from an HTTP connection
    #   :open_timeout - the timeout in seconds when opening an HTTP connection
    #   :adapter      - the Faraday adapter to use (defaults to :excon)
    #   :opaque_id    - set to `true` to use the 'X-Opaque-Id' request header
    #
    def initialize( opts = {} )
      host = opts.fetch :host, 'localhost'
      port = opts.fetch :port, 9200
      @url = opts.fetch :url,  "http://#{host}:#{port}"

      uri = Addressable::URI.parse @url
      @host = uri.host
      @port = uri.port

      @read_timeout = opts.fetch :read_timeout, 5
      @open_timeout = opts.fetch :open_timeout, 2
      @adapter      = opts.fetch :adapter, Faraday.default_adapter
      @opaque_id    = opts.fetch :opaque_id, false
    end

    attr_reader :host, :port, :url
    attr_reader :read_timeout, :open_timeout

    # Returns true if the server is available; returns false otherwise.
    def available?
      response = head '/', :action => 'cluster.available'
      response.success?
    rescue StandardError
      false
    end

    # Returns the version String of the attached ElasticSearch instance.
    def version
      info['version']['number']
    end

    # Returns the information Hash from the attached ElasticSearch instance.
    def info
      response = get '/', :action => 'cluster.info'
      response.body
    end

    # Internal: Provides access to the Faraday::Connection used by this client
    # for all requests to the server.
    #
    # Returns a Faraday::Connection
    def connection
      @connection ||= Faraday.new(url) do |conn|
        conn.request  :encode_json
        conn.response :parse_json
        conn.request  :opaque_id if @opaque_id

        Array === @adapter ?
          conn.adapter(*@adapter) :
          conn.adapter(@adapter)

        conn.options[:timeout]      = read_timeout
        conn.options[:open_timeout] = open_timeout
      end
    end

    # Internal: Sends an HTTP HEAD request to the server.
    #
    # path   - The path as a String
    # params - Parameters Hash
    #
    # Returns a Faraday::Response
    def head( path, params = {} )
      request :head, path, params
    end

    # Internal: Sends an HTTP GET request to the server.
    #
    # path   - The path as a String
    # params - Parameters Hash
    #
    # Returns a Faraday::Response
    # Raises an Elastomer::Client::Error on 4XX and 5XX responses
    def get( path, params = {} )
      request :get, path, params
    end

    # Internal: Sends an HTTP PUT request to the server.
    #
    # path   - The path as a String
    # params - Parameters Hash
    #
    # Returns a Faraday::Response
    # Raises an Elastomer::Client::Error on 4XX and 5XX responses
    def put( path, params = {} )
      request :put, path, params
    end

    # Internal: Sends an HTTP POST request to the server.
    #
    # path   - The path as a String
    # params - Parameters Hash
    #
    # Returns a Faraday::Response
    # Raises an Elastomer::Client::Error on 4XX and 5XX responses
    def post( path, params = {} )
      request :post, path, params
    end

    # Internal: Sends an HTTP DELETE request to the server.
    #
    # path   - The path as a String
    # params - Parameters Hash
    #
    # Returns a Faraday::Response
    # Raises an Elastomer::Client::Error on 4XX and 5XX responses
    def delete( path, params = {} )
      request :delete, path, params
    end

    # Internal: Sends an HTTP request to the server. If the `params` Hash
    # contains a :body key, it will be deleted from the Hash and the value
    # will be used as the body of the request.
    #
    # method - The HTTP method to send [:head, :get, :put, :post, :delete]
    # path   - The path as a String
    # params - Parameters Hash
    #   :body         - Will be used as the request body
    #   :read_timeout - Optional read timeout (in seconds) for the request
    #
    # Returns a Faraday::Response
    # Raises an Elastomer::Client::Error on 4XX and 5XX responses
    def request( method, path, params )
      body = params.delete :body
      body = MultiJson.dump body if Hash === body

      read_timeout = params.delete :read_timeout

      path = expand_path path, params

      response = instrument(path, body, params) do
        case method
        when :head
          connection.head(path) { |req| req.options[:timeout] = read_timeout if read_timeout }

        when :get
          connection.get(path) { |req|
            req.body = body if body
            req.options[:timeout] = read_timeout if read_timeout
          }

        when :put
          connection.put(path, body) { |req| req.options[:timeout] = read_timeout if read_timeout }

        when :post
          connection.post(path, body) { |req| req.options[:timeout] = read_timeout if read_timeout }

        when :delete
          connection.delete(path) { |req|
            req.body = body if body
            req.options[:timeout] = read_timeout if read_timeout
          }

        else
          raise ArgumentError, "unknown HTTP request method: #{method.inspect}"
        end
      end

      handle_errors response

    rescue Faraday::Error::TimeoutError => boom
      raise ::Elastomer::Client::TimeoutError.new(boom, path)

    # ensure
    #   # FIXME: this is here until we get a real logger in place
    #   STDERR.puts "[#{response.status.inspect}] curl -X#{method.to_s.upcase} '#{url}#{path}'" unless response.nil?
    end

    # Internal: Apply path expansions to the `path` and append query
    # parameters to the `path`. We are using an Addressable::Template to
    # replace '{expansion}' fields found in the path with the values extracted
    # from the `params` Hash. Any remaining elements in the `params` hash are
    # treated as query parameters and appended to the end of the path.
    #
    # path   - The path as a String
    # params - Parameters Hash
    #
    # Examples
    #
    #   expand_path('/foo{/bar}', {:bar => 'hello', :q => 'what', :p => 2})
    #   #=> '/foo/hello?q=what&p=2'
    #
    #   expand_path('/foo{/bar}{/baz}', {:baz => 'no bar'}
    #   #=> '/foo/no%20bar'
    #
    # Returns an Addressable::Uri
    def expand_path( path, params )
      template = Addressable::Template.new path

      expansions = {}
      query_values = params.dup
      query_values.delete :action
      query_values.delete :context

      template.keys.map(&:to_sym).each do |key|
        value = query_values.delete key
        value = assert_param_presence(value, key) unless path =~ /{\/#{key}}/ && value.nil?
        expansions[key] = value
      end

      uri = template.expand(expansions)
      uri.query_values = query_values unless query_values.empty?
      uri.to_s
    end

    # Internal: A noop method that simply yields to the block. This method
    # will be replaced when the 'elastomer/notifications' module is included.
    #
    # path   - The full request path as a String
    # body   - The request body as a String or `nil`
    # params - The request params Hash
    # block  - The block that will be instrumented
    #
    # Returns the response from the block
    def instrument( path, body, params )
      yield
    end

    # Internal: Inspect the Faraday::Response and raise an error if the status
    # is in the 5XX range or if the response body contains an 'error' field.
    # In the latter case, the value of the 'error' field becomes our exception
    # message. In the absence of an 'error' field the response body is used
    # as the exception message.
    #
    # The raised exception will contain the response object.
    #
    # response - The Faraday::Response object.
    #
    # Returns the response.
    # Raises an Elastomer::Client::Error on 500 responses or responses
    # containing and 'error' field.
    def handle_errors( response )
      raise Error, response if response.status >= 500
      raise Error, response if Hash === response.body && response.body['error']

      response
    end

    # Internal: Ensure that the parameter has a valid value. Things like `nil`
    # and empty strings are right out. This method also performs a little
    # formating on the parameter:
    #
    # * leading and trailing whitespace is removed
    # * arrays are flattend
    # * and then joined into a String
    # * numerics are converted to their string equivalents
    #
    # param - The param Object to validate
    # name  - Optional param name as a String (used in exception messages)
    #
    # Returns the validated param as a String.
    # Raises an ArgumentError if the param is not valid.
    def assert_param_presence( param, name = 'input value' )
      case param
      when String, Numeric
        param = param.to_s.strip
        raise ArgumentError, "#{name} cannot be blank: #{param.inspect}" if param =~ /\A\s*\z/
        param

      when Array
        param.flatten.map { |item| assert_param_presence(item, name) }.join(',')

      when nil
        raise ArgumentError, "#{name} cannot be nil"

      else
        raise ArgumentError, "#{name} is invalid: #{param.inspect}"
      end
    end

  end  # Client
end  # Elastomer

# require all files in the `client` sub-directory
Dir.glob(File.expand_path('../client/*.rb', __FILE__)).each { |fn| require fn }

# require all files in the `middleware` sub-directory
Dir.glob(File.expand_path('../middleware/*.rb', __FILE__)).each { |fn| require fn }

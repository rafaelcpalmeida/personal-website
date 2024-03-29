# frozen_string_literal: true
module GitHubPages
  module HealthCheck
    class Domain < Checkable
      attr_reader :host

      LEGACY_IP_ADDRESSES = [
        # Legacy GitHub Datacenter
        "207.97.227.245",
        "204.232.175.78",

        # Aug. 2016 Fastly datacenter deprecation
        "199.27.73.133",
        "199.27.76.133",

        # Feb. 2017 Fastly datacenter deprecation
        "185.31.17.133",
        "185.31.18.133",
        "185.31.19.133",
        "199.27.74.133",
        "199.27.75.133",
        "199.27.79.133",
        "23.235.39.133",
        "23.235.43.133",
        "23.235.44.133",
        "23.235.46.133",
        "23.235.47.133",
        "45.32.88.68",
        "43.249.75.133"
      ].freeze

      CURRENT_IP_ADDRESSES = %w(
        192.30.252.153
        192.30.252.154
      ).freeze

      HASH_METHODS = [
        :host, :uri, :dns_resolves?, :proxied?, :cloudflare_ip?, :fastly_ip?,
        :old_ip_address?, :a_record?, :cname_record?, :mx_records_present?,
        :valid_domain?, :apex_domain?, :should_be_a_record?,
        :cname_to_github_user_domain?, :cname_to_pages_dot_github_dot_com?,
        :cname_to_fastly?, :pointed_to_github_pages_ip?, :pages_domain?,
        :served_by_pages?, :valid_domain?, :https?, :enforces_https?, :https_error
      ].freeze

      def initialize(host)
        unless host.is_a? String
          raise ArgumentError, "Expected string, got #{host.class}"
        end

        @host = normalize_host(host)
      end

      # Runs all checks, raises an error if invalid
      def check!
        raise Errors::InvalidDomainError, :domain => self unless valid_domain?
        raise Errors::InvalidDNSError, :domain => self    unless dns_resolves?
        raise Errors::DeprecatedIPError, :domain => self if deprecated_ip?
        return true if proxied?
        raise Errors::InvalidARecordError, :domain => self    if invalid_a_record?
        raise Errors::InvalidCNAMEError, :domain => self      if invalid_cname?
        raise Errors::NotServedByPagesError, :domain => self  unless served_by_pages?
        true
      end

      def deprecated_ip?
        return @deprecated_ip if defined? @deprecated_ip
        @deprecated_ip = (valid_domain? && a_record? && old_ip_address?)
      end

      def invalid_a_record?
        return @invalid_a_record if defined? @invalid_a_record
        @invalid_a_record = (valid_domain? && a_record? && !should_be_a_record?)
      end

      def invalid_cname?
        return @invalid_cname if defined? @invalid_cname
        @invalid_cname = begin
          return false unless valid_domain?
          return false if github_domain? || apex_domain?
          return true  if cname_to_pages_dot_github_dot_com? || cname_to_fastly?
          !cname_to_github_user_domain? && should_be_cname_record?
        end
      end

      # Is this a valid domain that PublicSuffix recognizes?
      # Used as an escape hatch to prevent false positives on DNS checkes
      def valid_domain?
        return @valid if defined? @valid
        @valid = PublicSuffix.valid?(host, :default_rule => nil)
      end

      # Is this domain an apex domain, meaning a CNAME would be innapropriate
      def apex_domain?
        return @apex_domain if defined?(@apex_domain)
        return unless valid_domain?

        answers = begin
          Resolv::DNS.open do |dns|
            dns.timeouts = TIMEOUT
            dns.getresources(absolute_domain, Resolv::DNS::Resource::IN::NS)
          end
        rescue Timeout::Error, NoMethodError
          []
        end

        @apex_domain = answers.any?
      end

      # Should the domain be an apex record?
      def should_be_a_record?
        !pages_domain? && (apex_domain? || mx_records_present?)
      end

      def should_be_cname_record?
        !should_be_a_record?
      end

      # Is the domain's first response an A record to a valid GitHub Pages IP?
      def pointed_to_github_pages_ip?
        a_record? && CURRENT_IP_ADDRESSES.include?(dns.first.value)
      end

      # Is the domain's first response a CNAME to a pages domain?
      def cname_to_github_user_domain?
        cname? && !cname_to_pages_dot_github_dot_com? && cname.pages_domain?
      end

      # Is the given domain a CNAME to pages.github.(io|com)
      # instead of being CNAME'd to the user's subdomain?
      #
      # domain - the domain to check, generaly the target of a cname
      def cname_to_pages_dot_github_dot_com?
        cname? && cname.pages_dot_github_dot_com?
      end

      # Is the given domain CNAME'd directly to our Fastly account?
      def cname_to_fastly?
        cname? && !pages_domain? && cname.fastly?
      end

      # Is the host a *.github.io domain?
      def pages_domain?
        !!host.match(/\A[\w-]+\.github\.(io|com)\.?\z/i)
      end

      # Is the host pages.github.com or pages.github.io?
      def pages_dot_github_dot_com?
        !!host.match(/\Apages\.github\.(io|com)\.?\z/i)
      end

      # Is this domain owned by GitHub?
      def github_domain?
        !!host.downcase.end_with?("github.com")
      end

      # Is the host our Fastly CNAME?
      def fastly?
        !!host.match(/\Agithub\.map\.fastly\.net\.?\z/i)
      end

      # Does the domain resolve to a CloudFlare-owned IP
      def cloudflare_ip?
        cdn_ip?(CloudFlare)
      end

      # Does the domain resolve to a Fastly-owned IP
      def fastly_ip?
        cdn_ip?(Fastly)
      end

      # Does this non-GitHub-pages domain proxy a GitHub Pages site?
      #
      # This can be:
      #   1. A Cloudflare-owned IP address
      #   2. A site that returns GitHub.com server headers, but
      #      isn't CNAME'd to a GitHub domain
      #   3. A site that returns GitHub.com server headers, but
      #      isn't CNAME'd to a GitHub IP
      def proxied?
        return unless dns?
        return true if cloudflare_ip?
        return false if pointed_to_github_pages_ip?
        return false if cname_to_github_user_domain?
        return false if cname_to_pages_dot_github_dot_com?
        return false if cname_to_fastly? || fastly_ip?
        served_by_pages?
      end

      # Returns an array of DNS answers
      def dns
        return @dns if defined? @dns
        return unless valid_domain?
        @dns = Timeout.timeout(TIMEOUT) do
          GitHubPages::HealthCheck.without_warnings do
            unless host.nil?
              resolver.search(absolute_domain, Net::DNS::A).answer +
                resolver.search(absolute_domain, Net::DNS::MX).answer
            end
          end
        end
      rescue StandardError
        @dns = nil
      end

      def resolver
        @resolver ||= Net::DNS::Resolver.new
      end

      # Are we even able to get the DNS record?
      def dns?
        !(dns.nil? || dns.empty?)
      end
      alias dns_resolves? dns?

      # Does this domain have *any* A record that points to the legacy IPs?
      def old_ip_address?
        return unless dns?

        dns.any? do |answer|
          answer.is_a?(Net::DNS::RR::A) && legacy_ip?(answer.address.to_s)
        end
      end

      # Is this domain's first response an A record?
      def a_record?
        return unless dns?
        dns.first.class == Net::DNS::RR::A
      end

      # Is this domain's first response a CNAME record?
      def cname_record?
        return unless dns?
        return false unless cname
        cname.valid_domain?
      end
      alias cname? cname_record?

      # The domain to which this domain's CNAME resolves
      # Returns nil if the domain is not a CNAME
      def cname
        return unless dns.first.class == Net::DNS::RR::CNAME
        @cname ||= Domain.new(dns.first.cname.to_s)
      end

      def mx_records_present?
        return unless dns?
        dns.any? { |answer| answer.class == Net::DNS::RR::MX }
      end

      def served_by_pages?
        return @served_by_pages if defined? @served_by_pages
        return unless dns_resolves?

        @served_by_pages = begin
          return false unless response.mock? || response.return_code == :ok
          return true if response.headers["Server"] == "GitHub.com"

          # Typhoeus mangles the case of the header, compare insensitively
          response.headers.any? { |k, _v| k =~ /X-GitHub-Request-Id/i }
        end
      end

      def uri(overrides = {})
        options = { :host => host, :scheme => scheme, :path => "/" }
        options = options.merge(overrides)
        Addressable::URI.new(options).normalize.to_s
      end

      # Does this domain respond to HTTPS requests with a valid cert?
      def https?
        https_response.return_code == :ok
      end

      # The response code of the HTTPS request, if it failed.
      # Useful for diagnosing cert errors
      def https_error
        https_response.return_code unless https?
      end

      # Does this domain redirect HTTP requests to HTTPS?
      def enforces_https?
        return false unless https? && http_response.headers["Location"]
        redirect = Addressable::URI.parse(http_response.headers["Location"])
        redirect.scheme == "https" && redirect.host == host
      end

      private

      # The domain's response to HTTP(S) requests, following redirects
      def response
        return @response if defined? @response

        @response = Typhoeus.head(uri, TYPHOEUS_OPTIONS)

        # Workaround for webmock not playing nicely with Typhoeus redirects
        # See https://github.com/bblimke/webmock/issues/237
        if @response.mock? && @response.headers["Location"]
          @response = Typhoeus.head(response.headers["Location"], TYPHOEUS_OPTIONS)
        end

        @response
      end

      # The domain's response to HTTP requests, without following redirects
      def http_response
        options = TYPHOEUS_OPTIONS.merge(:followlocation => false)
        @http_response ||= Typhoeus.head(uri(:scheme => "http"), options)
      end

      # The domain's response to HTTPS requests, without following redirects
      def https_response
        options = TYPHOEUS_OPTIONS.merge(:followlocation => false)
        @https_response ||= Typhoeus.head(uri(:scheme => "https"), options)
      end

      # Parse the URI. Accept either domain names or full URI's.
      # Used by the initializer so we can be more flexible with inputs.
      #
      # domain - a URI or domain name.
      #
      # Examples
      #
      #   normalize_host("benbalter.github.com")
      #   # => 'benbalter.github.com'
      #   normalize_host("https://benbalter.github.com")
      #   # => 'benbalter.github.com'
      #   normalize_host("benbalter.github.com/help-me-im-a-path/")
      #   # => 'benbalter.github.com'
      #
      # Return the hostname.
      def normalize_host(domain)
        domain = domain.strip.chomp(".")
        host = Addressable::URI.parse(domain).host
        host ||= Addressable::URI.parse("http://#{domain}").host
        host unless host.to_s.empty?
      rescue Addressable::URI::InvalidURIError
        nil
      end

      # Adjust `domain` so that it won't be searched for with /etc/resolv.conf
      #
      #     GitHubPages::HealthCheck.new("anything.io").absolute_domain
      #     => "anything.io."
      def absolute_domain
        host.end_with?(".") ? host : "#{host}."
      end

      def scheme
        @scheme ||= github_domain? ? "https" : "http"
      end

      # Does the domain resolve to a CDN-owned IP
      def cdn_ip?(cdn)
        return unless dns?
        dns.all? do |answer|
          answer.class == Net::DNS::RR::A && cdn.controls_ip?(answer.address)
        end
      end

      def legacy_ip?(ip)
        LEGACY_IP_ADDRESSES.include?(ip)
      end
    end
  end
end

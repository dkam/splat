# frozen_string_literal: true

require "ipaddr"

module SentryProtocol
  # Who an event happened to: the client of the request it was raised in, read
  # from the payload. Every reader returns nil when the event doesn't say —
  # raised outside a request, or the SDK left it out.
  module Client
    module_function

    # Values an SDK puts where it won't say: sentry-ruby 7 without
    # send_default_pii keeps the IP headers and filters their values, and the
    # browser SDKs send {{auto}} asking the server to fill in the address
    # (Splat doesn't).
    WITHHELD = ["[Filtered]", "{{auto}}"].freeze

    # Where the client's address is, best first. user.ip_address is the SDK's
    # own answer, made from the headers below; REMOTE_ADDR behind a proxy is
    # the proxy, so it comes last.
    IP_HEADERS = %w[CF-Connecting-IP X-Real-Ip X-Forwarded-For].freeze

    def ip(payload)
      candidates = [payload.dig("user", "ip_address")]
      candidates += IP_HEADERS.map { header(payload, it)&.split(",")&.first }
      candidates << env(payload)["REMOTE_ADDR"]
      candidates.each do |value|
        value = value.to_s.strip
        next if value.empty? || WITHHELD.include?(value)
        return value if IPAddr.new(value)
      rescue IPAddr::Error
        next
      end
      nil
    end

    # The block an address is in: a /24 for IPv4, a /48 for IPv6 — what one
    # ISP customer, office or cloud tenant usually holds. Not an ASN; that
    # needs a database Splat doesn't carry.
    def network(ip)
      return if ip.blank?

      addr = IPAddr.new(ip)
      prefix = addr.ipv4? ? 24 : 48
      "#{addr.mask(prefix)}/#{prefix}"
    rescue IPAddr::Error
      nil
    end

    USER_FIELDS = {"id" => "id", "username" => "username", "email" => "email"}.freeze

    # The user the SDK names, by the first of id, username and email, with its
    # kind so the user with id 7 isn't the user named "7". An IP address alone
    # isn't a user here; #ip has it.
    def user(payload)
      user = payload["user"]
      return unless user.is_a?(Hash)

      USER_FIELDS.each do |field, kind|
        value = user[field]
        next if value.blank? || WITHHELD.include?(value)
        return "#{kind}:#{value}" if value.is_a?(String) || value.is_a?(Numeric)
      end
      nil
    end

    def user_agent(payload) = header(payload, "User-Agent")

    # The request header, whatever case it was sent in. Headers arrive as an
    # object or, from some SDKs, as a list of [name, value] pairs.
    def header(payload, name)
      headers = payload.dig("request", "headers")
      pairs = case headers
      when Hash then headers
      when Array then headers.select { it.is_a?(Array) && it.size == 2 }
      else return
      end
      pairs.each { |key, value| return value.to_s if key.to_s.casecmp?(name) }
      nil
    end

    def env(payload)
      env = payload.dig("request", "env")
      env.is_a?(Hash) ? env : {}
    end

    # Browser family and major version from a User-Agent, or a crawler's
    # name. Order matters: Edge and Opera claim to be Chrome, Chrome claims to
    # be Safari, and everything claims to be Mozilla.
    BROWSERS = [
      [/\b(?:Edg|EdgA|EdgiOS)\/(\d+)/, "Edge"],
      [/\bOPR\/(\d+)/, "Opera"],
      [/\bSamsungBrowser\/(\d+)/, "Samsung Internet"],
      [/\b(?:Firefox|FxiOS)\/(\d+)/, "Firefox"],
      [/\b(?:Chrome|CriOS)\/(\d+)/, "Chrome"],
      [/\bVersion\/(\d+)[.\d]* (?:Mobile\/\S+ )?Safari\//, "Safari"]
    ].freeze

    CRAWLER = /([\w.-]*(?:bot|crawler|spider|slurp)[\w.-]*)\//i

    def browser(user_agent)
      return if user_agent.blank?

      if (crawler = user_agent[CRAWLER, 1])
        return crawler
      end
      BROWSERS.each do |pattern, name|
        if (major = user_agent[pattern, 1])
          return "#{name} #{major}"
        end
      end
      # A tool, not a browser: curl/8.7.1, python-requests/2.32 — the name
      # without its version.
      user_agent[/\A([\w.-]+)\/[\d.]+/, 1] unless user_agent.start_with?("Mozilla/")
    end

    SYSTEMS = [
      [/\b(?:iPhone|iPad|iPod)\b/, "iOS"],
      [/\bAndroid\b/, "Android"],
      [/\bCrOS\b/, "ChromeOS"],
      [/\bWindows\b/, "Windows"],
      [/\bMac OS X\b|\bMacintosh\b/, "macOS"],
      [/\bLinux\b|\bX11\b/, "Linux"]
    ].freeze

    def os(user_agent)
      return if user_agent.blank? || user_agent.match?(CRAWLER)

      SYSTEMS.each { |pattern, name| return name if user_agent.match?(pattern) }
      nil
    end
  end
end

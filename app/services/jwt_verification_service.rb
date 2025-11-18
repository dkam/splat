# frozen_string_literal: true

# Service for verifying JWT signatures using OIDC provider's JSON Web Key Set (JWKS)
# Provides secure token validation to ensure tokens haven't been tampered with
class JwtVerificationService
  class << self
    # Cache JWKS keys for performance (refresh every hour)
    def jwks_keys
      @jwks_keys ||= {}
      @jwks_last_fetch ||= {}

      provider_key = oidc_provider_key
      return @jwks_keys[provider_key] if @jwks_keys[provider_key] &&
                                      @jwks_last_fetch[provider_key] &&
                                      @jwks_last_fetch[provider_key] > 1.hour.ago

      fetch_and_cache_jwks_keys(provider_key)
    end

    # Verify JWT token signature and claims
    def verify_token(token, options = {})
      return false if token.blank?

      begin
        # Decode JWT without verification first to get header
        decoded_header = JWT.decode(token, nil, false).first
        key_id = decoded_header['kid']

        return false if key_id.blank?

        # Get the public key for verification
        public_key = find_public_key(key_id)
        return false if public_key.nil?

        # Verify JWT with public key and standard claims
        decoded = JWT.decode(
          token,
          public_key,
          true,
          verification_options(options)
        )

        # Additional custom validations
        return false unless validate_claims(decoded.first, options)

        Rails.logger.debug "JWT token verified successfully"
        decoded.first
      rescue JWT::ExpiredSignature
        Rails.logger.warn "JWT token has expired"
        false
      rescue JWT::InvalidIssuerError
        Rails.logger.warn "JWT token has invalid issuer"
        false
      rescue JWT::InvalidAudienceError
        Rails.logger.warn "JWT token has invalid audience"
        false
      rescue JWT::VerificationError => e
        Rails.logger.warn "JWT token signature verification failed: #{e.message}"
        false
      rescue JWT::DecodeError => e
        Rails.logger.warn "JWT token decode error: #{e.message}"
        false
      rescue => e
        Rails.logger.error "JWT verification error: #{e.message}"
        false
      end
    end

    # Verify access token specifically
    def verify_access_token(token)
      verify_token(token, {
        issuer: oidc_issuer,
        audience: oidc_client_id
      })
    end

    # Verify ID token specifically
    def verify_id_token(token, nonce = nil)
      options = {
        issuer: oidc_issuer,
        audience: oidc_client_id
      }
      options[:nonce] = nonce if nonce.present?

      verify_token(token, options)
    end

    # Check if token is from expected issuer
    def valid_issuer?(token)
      return false if token.blank?

      begin
        decoded = JWT.decode(token, nil, false).first
        decoded['iss'] == oidc_issuer
      rescue JWT::DecodeError
        false
      end
    end

    # Extract token expiration time
    def token_expiration(token)
      return nil if token.blank?

      begin
        decoded = JWT.decode(token, nil, false).first
        Time.at(decoded['exp']) if decoded['exp']
      rescue JWT::DecodeError
        nil
      end
    end

    # Extract token issuer
    def token_issuer(token)
      return nil if token.blank?

      begin
        decoded = JWT.decode(token, nil, false).first
        decoded['iss']
      rescue JWT::DecodeError
        nil
      end
    end

    private

    def fetch_and_cache_jwks_keys(provider_key)
      return {} unless oidc_jwks_uri.present?

      begin
        uri = URI.parse(oidc_jwks_uri)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == 'https'
        http.open_timeout = 5
        http.read_timeout = 5

        response = http.get(uri.request_uri)
        response.raise_for_status

        jwks_data = JSON.parse(response.body)
        keys = parse_jwks_keys(jwks_data)

        @jwks_keys[provider_key] = keys
        @jwks_last_fetch[provider_key] = Time.current

        Rails.logger.debug "Successfully cached JWKS keys from #{oidc_jwks_uri}"
        keys
      rescue => e
        Rails.logger.error "Failed to fetch JWKS keys: #{e.message}"
        {}
      end
    end

    def parse_jwks_keys(jwks_data)
      return {} unless jwks_data['keys'].is_a?(Array)

      keys = {}
      jwks_data['keys'].each do |key_data|
        next unless key_data['kid'].present? && key_data['kty'].present?

        begin
          case key_data['kty']
          when 'RSA'
            public_key = parse_rsa_key(key_data)
            keys[key_data['kid']] = public_key if public_key
          when 'EC'
            public_key = parse_ec_key(key_data)
            keys[key_data['kid']] = public_key if public_key
          else
            Rails.logger.warn "Unsupported key type: #{key_data['kty']}"
          end
        rescue => e
          Rails.logger.error "Failed to parse key #{key_data['kid']}: #{e.message}"
        end
      end

      keys
    end

    def parse_rsa_key(key_data)
      require 'openssl'

      n = Base64.urlsafe_decode64(key_data['n'])
      e = Base64.urlsafe_decode64(key_data['e'])

      sequence = OpenSSL::ASN1::Sequence([
        OpenSSL::ASN1::Integer(OpenSSL::BN.new(n, 2)),
        OpenSSL::ASN1::Integer(OpenSSL::BN.new(e, 2))
      ])

      OpenSSL::PKey::RSA.new(sequence.to_der)
    end

    def parse_ec_key(key_data)
      require 'openssl'

      curve_name = case key_data['crv']
                   when 'P-256' then 'prime256v1'
                   when 'P-384' then 'secp384r1'
                   when 'P-521' then 'secp521r1'
                   else
                     Rails.logger.warn "Unsupported EC curve: #{key_data['crv']}"
                     return nil
                   end

      x = Base64.urlsafe_decode64(key_data['x'])
      y = Base64.urlsafe_decode64(key_data['y'])

      # Create EC public key from x and y coordinates
      group = OpenSSL::PKey::EC::Group.new(curve_name)
      bn_point = OpenSSL::BN.new("04#{x.unpack('H*').first}#{y.unpack('H*').first}", 16)
      point = OpenSSL::PKey::EC::Point.new(group, bn_point)

      ec_key = OpenSSL::PKey::EC.new(group)
      ec_key.public_key = point
      ec_key
    end

    def find_public_key(key_id)
      keys = jwks_keys
      keys[key_id]
    end

    def verification_options(options = {})
      default_options = {
        algorithm: 'RS256',  # Most common, but could be others
        verify_expiration: true,
        verify_not_before: true,
        verify_iat: true
      }

      default_options.merge(options)
    end

    def validate_claims(decoded_token, options = {})
      # Standard claims are already validated by JWT.decode
      # Add any custom validations here if needed

      # Validate token is not too old (optional)
      if options[:max_age]
        iat = decoded_token['iat']
        return false if iat.blank? || Time.at(iat) < options[:max_age].ago
      end

      true
    end

    def oidc_provider_key
      "#{oidc_issuer}:#{oidc_jwks_uri}"
    end

    def oidc_issuer
      @oidc_issuer ||= ENV.fetch('OIDC_ISSUER', nil) ||
                       begin
                         # Try to derive from discovery URL
                         discovery_url = ENV['OIDC_DISCOVERY_URL']
                         return nil if discovery_url.blank?

                         URI.parse(discovery_url).tap { |uri| uri.path = '' }.to_s
                       end
    end

    def oidc_jwks_uri
      @oidc_jwks_uri ||= ENV.fetch('OIDC_JWKS_ENDPOINT', nil) ||
                        begin
                          # Try to get from discovery URL
                          discovery_url = ENV['OIDC_DISCOVERY_URL']
                          return nil if discovery_url.blank?

                          "#{discovery_url.chomp('/')}/.well-known/jwks.json"
                        end
    end

    def oidc_client_id
      ENV.fetch('OIDC_CLIENT_ID', nil)
    end
  end
end
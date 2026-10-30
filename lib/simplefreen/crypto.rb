# frozen_string_literal: true

require "openssl"
require "securerandom"
require "base64"
require "digest"

module Simplefreen
  # Stdlib-only crypto primitives for the SimpleFIN bridge:
  #
  #   - AES-256-GCM encryption of bank credentials at rest. The master key
  #     lives in FREENTONIC_SECRETS_KEY; per-profile subkeys are derived via
  #     PBKDF2-HMAC-SHA256 from the master + a per-profile salt.
  #   - PBKDF2-HMAC-SHA256 hashing of access-URL passwords (600k iterations,
  #     16-byte salt). Verified with a constant-time compare.
  #   - Random ID + password generation.
  #
  # Kept dependency-free; the framework's zero-runtime-deps invariant rules
  # out bcrypt / scrypt / argon2 gems.
  module Crypto
    MASTER_KEY_BYTES   = 32
    AES_KEY_BYTES      = 32
    AES_IV_BYTES       = 12
    AES_TAG_BYTES      = 16
    PBKDF2_ITERATIONS  = 600_000
    PBKDF2_SALT_BYTES  = 16
    PBKDF2_HASH_BYTES  = 32
    SUBKEY_SALT_BYTES  = 16
    # AES subkey derivation uses a lower iteration count than password
    # hashing because the master key is already high-entropy (32 random
    # bytes). 100k still dominates any offline attack on a leaked salt.
    SUBKEY_ITERATIONS  = 100_000

    module_function

    # Decodes FREENTONIC_SECRETS_KEY. Accepts base64 (standard or url-safe),
    # with or without padding. Returns 32 raw bytes, or raises ArgumentError
    # if the decoded length is wrong.
    def decode_master_key(encoded)
      raise ArgumentError, "master key is empty" if encoded.nil? || encoded.empty?
      stripped = encoded.strip
      raw = begin
        Base64.urlsafe_decode64(stripped)
      rescue ArgumentError
        Base64.strict_decode64(stripped.tr("-_", "+/").ljust((stripped.bytesize + 3) & ~3, "="))
      end
      unless raw.bytesize == MASTER_KEY_BYTES
        raise ArgumentError,
          "master key must decode to #{MASTER_KEY_BYTES} bytes (got #{raw.bytesize})"
      end
      raw
    end

    # Returns a fresh 32-byte key, base64-encoded. Useful for generating
    # FREENTONIC_SECRETS_KEY in docs and tests.
    def generate_master_key_b64
      Base64.strict_encode64(SecureRandom.random_bytes(MASTER_KEY_BYTES))
    end

    # Encrypt a string value with AES-256-GCM under a subkey derived from
    # (master_key, salt). Returns a Hash:
    #   { "salt" => b64, "iv" => b64, "ct" => b64, "tag" => b64 }
    # All components are needed to decrypt; store them together.
    def encrypt(master_key, salt, plaintext)
      raise ArgumentError, "plaintext must be a String" unless plaintext.is_a?(String)
      subkey = derive_subkey(master_key, salt)
      cipher = OpenSSL::Cipher.new("aes-256-gcm").encrypt
      cipher.key = subkey
      iv = SecureRandom.random_bytes(AES_IV_BYTES)
      cipher.iv = iv
      ct = cipher.update(plaintext.dup.force_encoding(Encoding::BINARY)) + cipher.final
      {
        "salt" => Base64.strict_encode64(salt),
        "iv"   => Base64.strict_encode64(iv),
        "ct"   => Base64.strict_encode64(ct),
        "tag"  => Base64.strict_encode64(cipher.auth_tag)
      }
    end

    # Inverse of encrypt. Raises on tamper / wrong key.
    def decrypt(master_key, envelope)
      salt = Base64.strict_decode64(envelope.fetch("salt"))
      iv   = Base64.strict_decode64(envelope.fetch("iv"))
      ct   = Base64.strict_decode64(envelope.fetch("ct"))
      tag  = Base64.strict_decode64(envelope.fetch("tag"))
      subkey = derive_subkey(master_key, salt)
      cipher = OpenSSL::Cipher.new("aes-256-gcm").decrypt
      cipher.key = subkey
      cipher.iv  = iv
      cipher.auth_tag = tag
      (cipher.update(ct) + cipher.final).force_encoding(Encoding::UTF_8)
    rescue OpenSSL::Cipher::CipherError => e
      raise ArgumentError, "ciphertext failed AES-GCM verification: #{e.message}"
    end

    def random_salt
      SecureRandom.random_bytes(SUBKEY_SALT_BYTES)
    end

    def derive_subkey(master_key, salt)
      OpenSSL::KDF.pbkdf2_hmac(
        master_key,
        salt: salt,
        iterations: SUBKEY_ITERATIONS,
        length: AES_KEY_BYTES,
        hash: "sha256"
      )
    end

    # Hash an access-URL password for storage. Returns a Hash of b64 fields.
    def hash_password(plain)
      salt = SecureRandom.random_bytes(PBKDF2_SALT_BYTES)
      hash = OpenSSL::KDF.pbkdf2_hmac(
        plain,
        salt: salt,
        iterations: PBKDF2_ITERATIONS,
        length: PBKDF2_HASH_BYTES,
        hash: "sha256"
      )
      {
        "algo"       => "pbkdf2-hmac-sha256",
        "iterations" => PBKDF2_ITERATIONS,
        "salt"       => Base64.strict_encode64(salt),
        "hash"       => Base64.strict_encode64(hash)
      }
    end

    def verify_password(plain, record)
      return false unless record.is_a?(Hash)
      return false unless record["algo"] == "pbkdf2-hmac-sha256"
      iterations = record["iterations"]
      return false unless iterations.is_a?(Integer) && iterations.positive?
      salt = Base64.strict_decode64(record.fetch("salt"))
      expected = Base64.strict_decode64(record.fetch("hash"))
      actual = OpenSSL::KDF.pbkdf2_hmac(
        plain,
        salt: salt,
        iterations: iterations,
        length: expected.bytesize,
        hash: "sha256"
      )
      secure_compare(expected, actual)
    rescue ArgumentError, KeyError
      false
    end

    # Constant-time byte-string compare. Uses OpenSSL's built-in when
    # available (Ruby 3.2+), falls back to a manual loop otherwise.
    def secure_compare(a, b)
      if OpenSSL.respond_to?(:fixed_length_secure_compare)
        return false if a.bytesize != b.bytesize
        OpenSSL.fixed_length_secure_compare(a, b)
      else
        return false if a.bytesize != b.bytesize
        diff = 0
        a.each_byte.with_index { |byte, i| diff |= byte ^ b.getbyte(i) }
        diff.zero?
      end
    end

    # URL-safe base64 random string. Used for access-URL passwords and
    # claim IDs. 32 bytes → ~43 chars.
    def random_token(bytes: 32)
      Base64.urlsafe_encode64(SecureRandom.random_bytes(bytes), padding: false)
    end

    # 32-hex-char id for claim URLs (matches the plan). Good enough entropy
    # (128 bits) and fits cleanly in filename / URL contexts.
    def random_hex_id(bytes: 16)
      SecureRandom.hex(bytes)
    end
  end
end

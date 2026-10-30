# frozen_string_literal: true

require_relative "test_helper"
require "simplefreen/crypto"

module Simplefreen
  class CryptoTest < Minitest::Test
    def master_key
      @master_key ||= Crypto.decode_master_key(Crypto.generate_master_key_b64)
    end

    def test_encrypt_round_trips
      salt = Crypto.random_salt
      env  = Crypto.encrypt(master_key, salt, "hello world")
      assert_equal "hello world", Crypto.decrypt(master_key, env)
    end

    def test_encrypt_with_wrong_key_raises
      salt = Crypto.random_salt
      env = Crypto.encrypt(master_key, salt, "secret")
      other = Crypto.decode_master_key(Crypto.generate_master_key_b64)
      assert_raises(ArgumentError) { Crypto.decrypt(other, env) }
    end

    def test_decrypt_rejects_tampered_ciphertext
      salt = Crypto.random_salt
      env  = Crypto.encrypt(master_key, salt, "value")
      tampered = env.merge("ct" => Base64.strict_encode64("nope"))
      assert_raises(ArgumentError) { Crypto.decrypt(master_key, tampered) }
    end

    def test_decode_master_key_rejects_wrong_length
      bad = Base64.strict_encode64("not 32 bytes")
      assert_raises(ArgumentError) { Crypto.decode_master_key(bad) }
    end

    def test_password_hash_verifies_and_rejects
      rec = Crypto.hash_password("correct horse")
      assert Crypto.verify_password("correct horse", rec)
      refute Crypto.verify_password("wrong", rec)
      refute Crypto.verify_password("correct horse ", rec)
    end

    def test_password_hash_includes_expected_fields
      rec = Crypto.hash_password("x")
      assert_equal "pbkdf2-hmac-sha256", rec["algo"]
      assert rec["iterations"].is_a?(Integer) && rec["iterations"] >= 100_000
      assert rec["salt"].is_a?(String) && !rec["salt"].empty?
      assert rec["hash"].is_a?(String) && !rec["hash"].empty?
    end

    def test_secure_compare_constant_time_shape
      assert Crypto.secure_compare("abcd", "abcd")
      refute Crypto.secure_compare("abcd", "abce")
      refute Crypto.secure_compare("abc", "abcd")
    end

    def test_random_token_is_url_safe
      token = Crypto.random_token(bytes: 16)
      assert_match(/\A[A-Za-z0-9_\-]+\z/, token)
    end
  end
end

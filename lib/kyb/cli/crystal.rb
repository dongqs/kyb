# frozen_string_literal: true

module Kyb::CLI
  module_function

  CRYSTAL_DIR = File.expand_path('~/.kyb/.secrets')
  PRIVKEY = File.join(CRYSTAL_DIR, 'crystal_private.pem')

  PUBKEY = <<~PUB.strip
    -----BEGIN PUBLIC KEY-----
    MCowBQYDK2VwAyEAIfQU4C8fLGONftO2xWlg70IvCgOn0uRlFWOnRdvuuR0=
    -----END PUBLIC KEY-----
  PUB

  def crystal(args)
    sub = args.first || 'help'

    case sub
    when 'proof'
      crystal_proof
    when 'verify'
      msg = args[1]
      sig = args[2]
      if msg.nil? || sig.nil?
        puts "Usage: kyb crystal verify <message> <signature>"
        return
      end
      crystal_verify(msg, sig)
    when 'pubkey'
      puts PUBKEY
    else
      puts <<~USAGE
        Usage: kyb crystal <proof|verify|pubkey>

          proof         生成架构师身份证明
          verify MSG SG 验证签名
          pubkey        查看公钥
      USAGE
    end
  end

  def crystal_proof
    unless File.exist?(PRIVKEY)
      puts "ERROR: Crystal private key not found."
      puts "       Only the architect (青山) has this key."
      return
    end

    msg = "crystal-#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}"
    msgfile = "/tmp/crystal_msg_#{$$}.bin"
    File.write(msgfile, msg)
    sig = `openssl pkeyutl -sign -in "#{msgfile}" -inkey "#{PRIVKEY}" -rawin 2>/dev/null | base64`.strip
    File.unlink(msgfile)

    if sig.empty?
      puts "ERROR: Signing failed."
      return
    end

    puts "=== 负熵晶体 · 架构师身份证明 ==="
    puts "消息: #{msg}"
    puts "签名: #{sig}"
    puts
    puts "验真: kyb crystal verify #{msg} #{sig}"
  end

  def crystal_verify(msg, sig)
    sigfile = "/tmp/crystal_sig_#{$$}.bin"
    pubfile = "/tmp/crystal_pub_#{$$}.pem"
    msgfile = "/tmp/crystal_msg_#{$$}.bin"

    File.write(pubfile, PUBKEY + "\n")
    File.write(msgfile, msg)

    # Decode base64 signature to binary via Ruby
    raw_sig = sig.unpack1('m')
    File.write(sigfile, raw_sig, mode: 'wb')

    # Verify
    result = `openssl pkeyutl -verify -in "#{msgfile}" -sigfile "#{sigfile}" -pubin -inkey "#{pubfile}" -rawin 2>&1`.strip

    # Cleanup
    [sigfile, pubfile, msgfile].each { |f| File.unlink(f) rescue nil }

    if result.include?('Signature Verified Successfully')
      puts "✅ 签名有效 —— 由负熵晶体（青山）签发"
    else
      puts "❌ 签名无效 (#{result})"
    end
  end
end

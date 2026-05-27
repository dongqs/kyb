# frozen_string_literal: true

module Kyb::CLI
  module_function

  CRYSTAL_DIR = File.expand_path('~/.kyb/.crystal')
  ALLOWED_SIGNERS = File.join(CRYSTAL_DIR, 'crystal_allowed_signers')
  NAMESPACE = 'crystal'

  def crystal(args)
    sub = args.first || 'help'

    case sub
    when 'init'
      crystal_init
    when 'proof'
      crystal_proof
    when 'verify'
      msg_file = args[1]
      sig_file = args[2]
      if msg_file.nil? || sig_file.nil?
        puts "Usage: kyb crystal verify <msg-file> <sig-file>"
        puts "  msg-file  签名的原始消息文件"
        puts "  sig-file  ssh-keygen -Y sign 输出的签名文件"
        return
      end
      crystal_verify(msg_file, sig_file)
    when 'pubkey'
      crystal_pubkey
    else
      puts <<~USAGE
        Usage: kyb crystal <init|proof|verify|pubkey>

          init             注册你的 SSH 公钥为晶体身份
          proof            用你的 SSH 私钥签名一条证明
          verify MSG SIG   验证签名
          pubkey           查看注册的公钥

        验真方只需在任意机器上: kyb crystal verify <msg> <sig>
        不需要私钥，不需要 init。
      USAGE
    end
  end

  def crystal_init
    ssh_key = File.expand_path('~/.ssh/id_ed25519.pub')
    unless File.exist?(ssh_key)
      # Try rsa
      ssh_key = File.expand_path('~/.ssh/id_rsa.pub')
    end
    unless File.exist?(ssh_key)
      puts "未找到 SSH 公钥 (~/.ssh/id_ed25519.pub 或 ~/.ssh/id_rsa.pub)"
      puts "请先用 ssh-keygen -t ed25519 生成"
      return
    end

    pubkey = File.read(ssh_key).strip
    FileUtils.mkdir_p(CRYSTAL_DIR)
    File.write(ALLOWED_SIGNERS, "* #{pubkey}\n")
    File.chmod(0o600, ALLOWED_SIGNERS)

    puts "✅ 晶体身份已注册"
    puts "   公钥: #{ssh_key}"
    puts "   #{pubkey.split.last(2).first(2).join(' ')}"
    puts ""
    puts "   你现在可以运行: kyb crystal proof"
  end

  def crystal_proof
    unless File.exist?(ALLOWED_SIGNERS)
      puts "请先运行 kyb crystal init 注册身份"
      return
    end

    # Find default SSH private key
    privkey = File.expand_path('~/.ssh/id_ed25519')
    privkey = File.expand_path('~/.ssh/id_rsa') unless File.exist?(privkey)

    unless File.exist?(privkey)
      puts "未找到 SSH 私钥"
      return
    end

    ts = Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ')
    msg = "负熵晶体身份证明 —— kyb 架构师\n时间: #{ts}\n消息: 我是青山（负熵晶体），kyb 基础设施的架构师。"

    msgfile = "/tmp/crystal-proof-msg.txt"
    sigfile = "/tmp/crystal-proof-msg.txt.sig"
    File.write(msgfile, msg)

    puts "=== 签名中... ==="
    puts "   使用 SSH 私钥: #{privkey}"
    puts "   注意: 私钥全程在本地操作，不经过任何远程。"
    puts ""
    result = `ssh-keygen -Y sign -f "#{privkey}" -n "#{NAMESPACE}" "#{msgfile}" 2>&1`
    unless $?.success?
      puts "签名失败: #{result}"
      File.unlink(msgfile) rescue nil
      return
    end

    puts ""
    puts "=== 负熵晶体 · 架构师身份证明 ==="
    puts ""
    puts "消息文件: #{msgfile}"
    puts "签名文件: #{sigfile}"
    puts ""
    puts "--- 消息内容 ---"
    puts msg
    puts "---"
    puts ""
    puts "验真命令:"
    puts "  kyb crystal verify #{msgfile} #{sigfile}"
    puts ""
    puts "或在没有 kyb 的机器上:"
    allowed = File.read(ALLOWED_SIGNERS).strip
    puts "  curl -sL git.leyantech.com/quick-n-dirty/kyb/-/raw/master/.crystal/crystal_allowed_signers \\"
    puts "    > /tmp/crystal_allowed_signers"
    puts "  ssh-keygen -Y verify -f /tmp/crystal_allowed_signers -I \"*\" \\"
    puts "    -n \"#{NAMESPACE}\" -s #{sigfile} < #{msgfile}"
  end

  def crystal_verify(msg_file, sig_file)
    unless File.exist?(msg_file)
      puts "❌ 消息文件不存在: #{msg_file}"
      return
    end
    unless File.exist?(sig_file)
      puts "❌ 签名文件不存在: #{sig_file}"
      return
    end

    unless File.exist?(ALLOWED_SIGNERS)
      # First time verify on a new machine — try git repo
      repo_signers = File.join(Kyb::Config.kyb_repo || File.expand_path('~/.kyb'), '.secrets', 'crystal_allowed_signers')
      if File.exist?(repo_signers)
        FileUtils.mkdir_p(CRYSTAL_DIR)
        FileUtils.cp(repo_signers, ALLOWED_SIGNERS)
      else
        puts "❌ 未找到公钥。请先从 git 仓库获取 crystal_allowed_signers 文件。"
        return
      end
    end

    result = `ssh-keygen -Y verify -f "#{ALLOWED_SIGNERS}" -I "*" -n "#{NAMESPACE}" -s "#{sig_file}" < "#{msg_file}" 2>&1`
    if $?.success?
      puts "✅ 签名有效 —— 由负熵晶体（青山）签发"
      puts "   消息: #{File.read(msg_file).lines.first&.strip}"
    else
      puts "❌ 签名无效"
      puts "   #{result.lines.first&.strip}"
    end
  end

  def crystal_pubkey
    unless File.exist?(ALLOWED_SIGNERS)
      puts "尚未注册晶体身份。运行 kyb crystal init"
      return
    end
    puts File.read(ALLOWED_SIGNERS).strip
  end
end

# frozen_string_literal: true

module Kyb::CLI
  DEFAULT_VOICE = 'Zarvox'
  DEFAULT_RATE  = 180
  TTS_PID_FILE  = File.expand_path('~/.cache/kyb/tts.pid')

  module_function

  def tts_start
    server = File.expand_path('../../../tts-server.rb', __dir__)
    Kyb.die("tts-server.rb not found at #{server}") unless File.exist?(server)

    if tts_running?
      puts "==> tts server already running (pid #{File.read(TTS_PID_FILE).strip})"
      return
    end

    FileUtils.mkdir_p(File.dirname(TTS_PID_FILE))
    pid = Process.spawn('ruby', server, %i[out err] => File::NULL)
    Process.detach(pid)
    File.write(TTS_PID_FILE, pid.to_s)
    puts "==> tts server started (pid #{pid}, port 10666)"
  end

  def tts_stop
    unless tts_running?
      puts "==> tts server not running"
      return
    end

    pid = File.read(TTS_PID_FILE).strip.to_i
    Process.kill('TERM', pid)
    File.delete(TTS_PID_FILE)
    puts "==> tts server stopped (pid #{pid})"
  rescue Errno::ESRCH
    File.delete(TTS_PID_FILE)
    puts "==> tts server was already dead, cleaned up"
  end

  def tts_status
    if tts_running?
      pid = File.read(TTS_PID_FILE).strip
      puts "==> tts server running (pid #{pid}, port 10666)"
    else
      puts "==> tts server not running"
      File.delete(TTS_PID_FILE) if File.exist?(TTS_PID_FILE)
    end
  end

  def tts_speak(text, voice: DEFAULT_VOICE, rate: DEFAULT_RATE)
    system('say', '-v', voice.to_s, '-r', rate.to_s, text.to_s)
  end

  def tts_ping
    system('afplay', '/System/Library/Sounds/Ping.aiff')
  end

  def tts_done(text, voice: DEFAULT_VOICE, rate: DEFAULT_RATE)
    tts_speak(text, voice: voice, rate: rate)
    tts_ping
  end

  def tts_running?
    return false unless File.exist?(TTS_PID_FILE)
    pid = File.read(TTS_PID_FILE).strip.to_i
    Process.getpgid(pid)
    true
  rescue Errno::ESRCH
    false
  end
end

# frozen_string_literal: true

require 'webrick'
require 'json'

module Kyb
  module TTSServer
  DEFAULT_VOICE = 'Tingting'
  DEFAULT_RATE  = 180
  PORT = (ENV['TTS_PORT'] || 10666).to_i

  STATIC_DIR = File.join(__dir__, 'tts_server')

  module_function

  def speak(text, voice: DEFAULT_VOICE, rate: DEFAULT_RATE)
    system('say', '-v', voice.to_s, '-r', rate.to_s, text.to_s)
  end

  def ping
    system('afplay', '/System/Library/Sounds/Ping.aiff')
  end

  def voices
    @voices ||= begin
      raw = `say -v '?' 2>/dev/null`.force_encoding('UTF-8')
      raw.lines.map do |line|
        parts = line.split('#')
        name, lang = parts[0].to_s.strip.split(/\s+/, 2)
        comment = parts[1].to_s.strip
        { name: name, language: lang, comment: comment } if name
      end.compact
    end
  end

  def parse_json(req)
    body = req.body
    body.empty? ? {} : JSON.parse(body)
  rescue JSON::ParserError
    {}
  end

  def read_static(file)
    template = File.read(File.join(STATIC_DIR, file))
    template.gsub('__PORT__', PORT.to_s)
  end

  def build_server
    server = WEBrick::HTTPServer.new(
      Port: PORT,
      BindAddress: '0.0.0.0',
      Logger: WEBrick::Log.new($stdout, WEBrick::Log::INFO),
      AccessLog: [[File.open(File::NULL, 'w'), WEBrick::AccessLog::COMMON_LOG_FORMAT]]
    )

    server.mount_proc '/' do |_req, res|
      res['Content-Type'] = 'text/html'
      res.body = read_static('index.html')
    end

    server.mount_proc '/openapi.yml' do |_req, res|
      res['Content-Type'] = 'text/yaml'
      res.body = read_static('openapi.yml')
    end

    server.mount_proc '/health' do |_req, res|
      res['Content-Type'] = 'application/json'
      res.body = { status: 'ok', voices: voices.size, default_voice: DEFAULT_VOICE }.to_json
    end

    server.mount_proc '/voices' do |_req, res|
      res['Content-Type'] = 'application/json'
      res.body = voices.to_json
    end

    server.mount_proc '/ping' do |_req, res|
      ping
      res.body = 'ok'
    end

    server.mount_proc '/speak' do |req, res|
      if req.request_method == 'POST'
        data = parse_json(req)
        text  = data['text'] || 'Agent is calling'
        voice = data['voice'] || DEFAULT_VOICE
        rate  = (data['rate'] || DEFAULT_RATE).to_i
        ping if data['ping']
      else
        text  = req.query['text'] || 'Agent is calling'
        voice = req.query['voice'] || DEFAULT_VOICE
        rate  = (req.query['rate'] || DEFAULT_RATE).to_i
        ping if req.query['ping']
      end
      speak(text, voice: voice, rate: rate)
      res.body = 'ok'
    end

    server.mount_proc '/done' do |req, res|
      text  = req.query['text'] || 'Done'
      voice = req.query['voice'] || DEFAULT_VOICE
      rate  = (req.query['rate'] || DEFAULT_RATE).to_i
      speak(text, voice: voice, rate: rate)
      ping
      res.body = 'ok'
    end

    server.mount_proc '/notify' do |_req, res|
      res['Content-Type'] = 'application/json'
      data = parse_json(_req)

      level = data['level'] || 'done'
      text  = data['text'] || 'Agent is calling'

      unless %w[done blocked urgent].include?(level)
        res.status = 400
        res.body = { status: 'error', message: "level must be done/blocked/urgent" }.to_json
        next
      end

      voice = DEFAULT_VOICE
      rate = case level
             when 'done'    then 180
             when 'blocked' then 160
             else 140
             end

      speak(text, voice: voice, rate: rate)

      pings = case level
              when 'done'    then 1
              when 'blocked' then 2
              else 3
              end
      pings.times { ping }

      retry_hint = "blocked/urgent: notify again after 60s if user hasn't responded (max 3 retries)"
      res.body = {
        status: 'ok',
        level: level,
        retry_hint: (%w[blocked urgent].include?(level) ? retry_hint : nil)
      }.compact.to_json
    end

    server
  end

  def start
    unless RbConfig::CONFIG['host_os'] =~ /darwin/i
      warn "TTS server requires macOS (say/afplay not available)"
      return
    end
    %w[say afplay].each do |cmd|
      unless system("which #{cmd} > /dev/null 2>&1")
        warn "TTS server requires `#{cmd}` command, not found"
        return
      end
    end

    server = build_server
    Thread.new { sleep 2; speak('TTS server started') }
    trap('INT')  { server.shutdown }
    trap('TERM') { server.shutdown }
    puts "TTS server listening on http://0.0.0.0:#{PORT}"
    server.start
  end
  end
end

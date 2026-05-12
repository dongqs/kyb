#!/usr/bin/env ruby
# frozen_string_literal: true
# TTS HTTP server — WEBrick (stdlib), runs on macOS host
# Usage: ruby tts-server.rb

require 'webrick'
require 'json'

DEFAULT_VOICE = 'Zarvox'
DEFAULT_RATE  = 180
PORT = (ENV['TTS_PORT'] || 10666).to_i

def speak(text, voice: DEFAULT_VOICE, rate: DEFAULT_RATE)
  system('say', '-v', voice.to_s, '-r', rate.to_s, text.to_s)
end

def ping
  system('afplay', '/System/Library/Sounds/Ping.aiff')
end

def voices
  raw = `say -v '?' 2>/dev/null`.force_encoding('UTF-8')
  raw.lines.map do |line|
    parts = line.split('#')
    name, lang = parts[0].to_s.strip.split(/\s+/, 2)
    comment = parts[1].to_s.strip
    { name: name, language: lang, comment: comment } if name
  end.compact
end

def parse_json(req)
  body = req.body
  body.empty? ? {} : JSON.parse(body)
rescue JSON::ParserError
  {}
end

server = WEBrick::HTTPServer.new(Port: PORT, BindAddress: '0.0.0.0', Logger: WEBrick::Log.new($stdout, WEBrick::Log::INFO), AccessLog: [[File.open(File::NULL, 'w'), WEBrick::AccessLog::COMMON_LOG_FORMAT]])

# /health
server.mount_proc '/health' do |_req, res|
  res['Content-Type'] = 'application/json'
  res.body = { status: 'ok', voices: voices.size, default_voice: DEFAULT_VOICE }.to_json
end

# /voices
server.mount_proc '/voices' do |_req, res|
  res['Content-Type'] = 'application/json'
  res.body = voices.to_json
end

# /ping
server.mount_proc '/ping' do |_req, res|
  ping
  res.body = 'ok'
end

# /speak
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

# /done
server.mount_proc '/done' do |req, res|
  text  = req.query['text'] || 'Done'
  voice = req.query['voice'] || DEFAULT_VOICE
  rate  = (req.query['rate'] || DEFAULT_RATE).to_i
  speak(text, voice: voice, rate: rate)
  ping
  res.body = 'ok'
end

Thread.new do
  sleep 2
  speak('TTS server started')
end

trap('INT')  { server.shutdown }
trap('TERM') { server.shutdown }

puts "TTS server listening on http://0.0.0.0:#{PORT}"
server.start

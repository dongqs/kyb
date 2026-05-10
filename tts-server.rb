#!/usr/bin/env ruby
# frozen_string_literal: true
# TTS HTTP server — Sinatra, 跑在宿主机 (Mac) 上
# 安装: gem install sinatra
# 启动: ruby tts-server.rb

require 'sinatra/base'
require 'json'
require 'ipaddr'

class TTSServer < Sinatra::Base
  set :port, 10666
  set :bind, '0.0.0.0'
  set :logging, true
  set :show_exceptions, false
  set :host_authorization, permitted_hosts: [
    'localhost',
    '.localhost',
    'host.docker.internal',
    IPAddr.new('0.0.0.0/0'),
    IPAddr.new('::/0'),
  ]

  DEFAULT_VOICE = 'Zarvox'
  DEFAULT_RATE  = 180

  # ---------- helpers ----------

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

  def json_body
    return @json_body if defined?(@json_body)
    body = request.body.read
    @json_body = body.empty? ? {} : JSON.parse(body)
  rescue JSON::ParserError
    @json_body = {}
  end

  # ---------- routes ----------

  # 健康检查
  get '/health' do
    content_type :json
    { status: 'ok', voices: voices.size, default_voice: DEFAULT_VOICE }.to_json
  end

  # 列出可用语音
  get '/voices' do
    content_type :json
    voices.to_json
  end

  # 纯提示音
  get '/ping' do
    ping
    'ok'
  end

  # TTS 朗读 (兼容单声)
  # GET  /speak?text=hello&voice=Samantha&rate=180
  # POST /speak  {"text":"hello","voice":"Samantha","rate":180,"ping":true}
  get '/speak' do
    text  = params[:text] || 'Agent is calling'
    voice = params[:voice] || DEFAULT_VOICE
    rate  = (params[:rate] || DEFAULT_RATE).to_i

    ping if params[:ping]
    speak(text, voice: voice, rate: rate)
    'ok'
  end

  post '/speak' do
    data  = json_body
    text  = data['text'] || 'Agent is calling'
    voice = data['voice'] || DEFAULT_VOICE
    rate  = (data['rate'] || DEFAULT_RATE).to_i

    ping if data['ping']
    speak(text, voice: voice, rate: rate)
    'ok'
  end

  # 便捷: 说完自动提示音
  # GET /done?text=done!&voice=Samantha
  get '/done' do
    text  = params[:text] || 'Done'
    voice = params[:voice] || DEFAULT_VOICE
    rate  = (params[:rate] || DEFAULT_RATE).to_i

    speak(text, voice: voice, rate: rate)
    ping
    'ok'
  end

  # 404
  not_found do
    content_type :text
    "endpoints:\n" \
    "  GET  /ping\n" \
    "  GET  /speak?text=...&voice=...&rate=...&ping=true\n" \
    "  POST /speak  JSON body\n" \
    "  GET  /done?text=...\n" \
    "  GET  /voices\n" \
    "  GET  /health\n"
  end
end

Thread.new do
  sleep 2
  system('say', '-v', DEFAULT_VOICE, '-r', DEFAULT_RATE.to_s, 'TTS server started')
end

TTSServer.run!


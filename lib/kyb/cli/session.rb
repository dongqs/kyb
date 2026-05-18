# frozen_string_literal: true

module Kyb::CLI
  module_function

  def session_wrap(cli, cli_args = [])
    start_time = Time.now
    args = [cli, *cli_args].compact
    system(*args)
    duration = Time.now - start_time

    puts format_session_stats(duration, cli)
    if ENV.key?('TMUX')
      puts "Still inside tmux session. Type 'exit' to close this container."
    end
  end

  def format_session_stats(duration_secs, cli)
    dur = format_duration(duration_secs)
    <<~STATS.strip
      \n━━━ Session ━━━━━━━
      Duration:  #{dur}
      Command:   #{cli}
      ────────────────────
    STATS
  end

  def format_duration(secs)
    secs = secs.to_i
    h = secs / 3600
    m = (secs % 3600) / 60
    s = secs % 60
    if h > 0
      format('%dh %dm %ds', h, m, s)
    elsif m > 0
      format('%dm %ds', m, s)
    else
      format('%ds', s)
    end
  end
end

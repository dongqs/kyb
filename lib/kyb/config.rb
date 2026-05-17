# frozen_string_literal: true

module Kyb::Config
  DEFAULT_SANDBOX_DOMAINS = [
    '*.npmjs.org', '*.npmmirror.com',
    'registry.npmjs.org', 'registry.npmmirror.com',
    'github.com', '*.github.com',
    '*.githubusercontent.com',
    'git.leyantech.com', '*.leyantech.com',
    'nexus.leyantech.com',
    'api.anthropic.com',
    'api.deepseek.com', '*.deepseek.com',
    'localhost', '127.0.0.1'
  ].freeze

  module_function

  def load_config
    Kyb.die("#{Kyb::CONFIG_FILE} not found") unless File.exist?(Kyb::CONFIG_FILE)
    @config ||= YAML.safe_load_file(Kyb::CONFIG_FILE, permitted_classes: [Symbol])
  end
  alias load load_config
  module_function :load

  def save(project_name, project_data)
    config = if File.exist?(Kyb::CONFIG_FILE)
               YAML.safe_load_file(Kyb::CONFIG_FILE, permitted_classes: [Symbol])
             else
               { 'base' => {}, 'projects' => {} }
             end
    config['projects'] ||= {}
    config['projects'][project_name] = project_data
    FileUtils.mkdir_p(File.dirname(Kyb::CONFIG_FILE))
    File.write(Kyb::CONFIG_FILE, YAML.dump(config))
  end

  def base_image_path
    File.expand_path(load_config.dig('base', 'image'))
  end

  def claude_default_model
    load_config.dig('base', 'claude_default_model') || 'flash'
  end

  def proxy
    load_config.dig('base', 'proxy')
  end

  def no_proxy
    load_config.dig('base', 'no_proxy')
  end

  def project(name)
    p = load_config.dig('projects', name)
    Kyb.die("'#{name}' not found in #{Kyb::CONFIG_FILE}") unless p
    base_extra = load_config.dig('base', 'extra_prompt')
    proj_extra = p['extra_prompt']
    extra = [base_extra, proj_extra].compact.join(' ')
    {
      name: name,
      path: File.expand_path(p['path']),
      base_branch: p['base_branch'],
      dockerfile: p['dockerfile'],
      ports: Array(p['ports']).map(&:to_i).reject(&:zero?),
      symlinks: Array(p['symlinks']).map(&:to_s).reject(&:empty?).join(','),
      mounts_rw: Array(p['mounts_rw']).map(&:to_s).reject(&:empty?).join(','),
      mounts_ro: Array(p['mounts_ro']).map(&:to_s).reject(&:empty?).join(','),
      env_template: p['env_template'],
      timezone: p['timezone'] || 'Asia/Shanghai',
      proxy: p['proxy'] || proxy,
      no_proxy: p['no_proxy'] || no_proxy,
      sandbox_allowed_domains: DEFAULT_SANDBOX_DOMAINS + Array(p['sandbox_allowed_domains']).map(&:to_s).reject(&:empty?),
      extra_prompt: extra.empty? ? nil : extra
    }
  end

  def project_names
    (load_config['projects'] || {}).keys.sort
  end
end

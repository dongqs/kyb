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
    path = load_config.dig('base', 'image')
    path = nil if path.is_a?(String) && path.empty?
    File.expand_path(path || '~/.kyb')
  end

  def claude_default_model
    load_config.dig('base', 'claude_default_model') || 'flash'
  end

  def kyb_repo
    path = load_config.dig('base', 'kyb_repo')
    File.expand_path(path) if path
  end

  def proxy
    load_config.dig('base', 'proxy')
  end

  def proxy_in_container
    load_config.dig('base', 'proxy_in_container')
  end

  def no_proxy
    load_config.dig('base', 'no_proxy')
  end

  def project(name)
    p = load_config.dig('projects', name)
    Kyb.die("'#{name}' not found in #{Kyb::CONFIG_FILE}") unless p
    base_cp = load_config.dig('base', 'cp_files')
    base_extra = load_config.dig('base', 'extra_prompt')
    proj_extra = p['extra_prompt']
    extra = [base_extra, proj_extra].compact.join(' ')
    {
      name: name,
      path: File.expand_path(p['path']),
      git_url: p['git_url'],
      base_branch: p['base_branch'],
      dockerfile: p['dockerfile'],
      repo_root: p['repo_root'] || 'shared_host_disk_mount',
      ports: Array(p['ports']).map(&:to_i).reject(&:zero?),
      symlinks: Array(p['symlinks']).map(&:to_s).reject(&:empty?).join(','),
      mounts_rw: Array(p['mounts_rw']).map(&:to_s).reject(&:empty?).join(','),
      mounts_ro: Array(p['mounts_ro']).map(&:to_s).reject(&:empty?).join(','),
      cp_files: build_cp_files(p, base_cp),
      cp_files_base_keys: base_cp.is_a?(Hash) ? base_cp.keys.freeze : [].freeze,
      timezone: p['timezone'] || 'Asia/Shanghai',
      proxy: p['proxy'] || proxy,
      proxy_in_container: p['proxy_in_container'] || proxy_in_container || proxy,
      no_proxy: p['no_proxy'] || no_proxy,
      sandbox_allowed_domains: DEFAULT_SANDBOX_DOMAINS + Array(p['sandbox_allowed_domains']).map(&:to_s).reject(&:empty?),
      extra_prompt: extra.empty? ? nil : extra
    }
  end

  def build_cp_files(config, base_cp_files = nil)
    cp_files = {}
    # Global cp_files from base config (lower priority)
    cp_files.merge!(base_cp_files) if base_cp_files.is_a?(Hash)
    # Project-level cp_files override base (higher priority)
    cp_files.merge!(config['cp_files']) if config['cp_files'].is_a?(Hash)
    # env_template 和 cp_files 重复定义 .env 时报错
    if config['env_template'] && !config['env_template'].to_s.empty?
      Kyb.die("cp_files conflict: '.env' is already defined in cp_files, but env_template is also set.\n" \
              "  Remove env_template and use cp_files instead.") if cp_files.key?('.env')
      cp_files['.env'] = config['env_template']
    end
    cp_files.empty? ? nil : cp_files
  end

  def project_names
    (load_config['projects'] || {}).keys.sort
  end
end

  def reporting_enabled?
    cfg = load_config
    return true unless cfg.is_a?(Hash)
    reporting = cfg["reporting"]
    return true unless reporting.is_a?(Hash)
    reporting["enabled"] != false
  end

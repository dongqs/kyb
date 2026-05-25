# frozen_string_literal: true

require 'tempfile'

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

  DEFAULT_NO_PROXY = '.deepseek.com,localhost,127.0.0.1,host.orb.internal,192.168.0.0/16,100.64.0.0/10,.kyb-net,.internal,.local,kyb-infra-sing-box,kyb-infra-boss,kyb-infra-*'.freeze
  DEFAULT_MEMORY = '8g'.freeze

  module_function

  def load_config(force: false)
    path = Kyb::CONFIG_FILE
    if force || @config_cache.nil?
      Kyb.die("#{path} not found") unless File.exist?(path)
      @config_cache = YAML.safe_load_file(path, permitted_classes: [Symbol]) || {}
      @config_mtime = File.mtime(path)
    elsif @config_mtime && (!File.exist?(path) || File.mtime(path) != @config_mtime)
      Kyb.die("#{path} not found") unless File.exist?(path)
      @config_cache = YAML.safe_load_file(path, permitted_classes: [Symbol]) || {}
      @config_mtime = File.mtime(path)
    end
    @config_cache
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
    tmp = Tempfile.new('.config.yml', File.dirname(Kyb::CONFIG_FILE))
    tmp.write(YAML.dump(config))
    tmp.close
    File.rename(tmp.path, Kyb::CONFIG_FILE)
  end

  def base_image_path
    path = load_config.dig('base', 'image')
    path = nil if path.is_a?(String) && path.empty?
    default = File.exist?(File.expand_path('~/projects/kyb/Dockerfile')) ? '~/projects/kyb' : '~/.kyb'
    File.expand_path(path || default)
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
    load_config.dig('base', 'no_proxy') || DEFAULT_NO_PROXY
  end

  def default_memory
    load_config.dig('base', 'memory') || DEFAULT_MEMORY
  end

  def project(name)
    proj = load_project_config(name)
    merge_defaults(proj)
    resolve_paths(proj)
    setup_cp_files(proj)
    proj
  end

  def load_project_config(name)
    raw = load_config.dig('projects', name)
    Kyb.die("'#{name}' not found in #{Kyb::CONFIG_FILE}") unless raw
    { name: name, raw: raw }
  end

  def merge_defaults(proj)
    raw = proj[:raw]
    base = load_config
    base_extra = base.dig('base', 'extra_prompt')
    proj_extra = raw['extra_prompt']
    extra = [base_extra, proj_extra].compact.join(' ')

    proj[:path] = raw['path']
    proj[:git_url] = raw['git_url']
    proj[:base_branch] = raw['base_branch']
    proj[:dockerfile] = raw['dockerfile']
    proj[:repo_root] = raw['repo_root'] || 'shared_host_disk_mount'
    proj[:ports] = Array(raw['ports']).map(&:to_i).reject(&:zero?)
    proj[:symlinks] = Array(raw['symlinks']).map(&:to_s).reject(&:empty?).join(',')
    proj[:mounts_rw] = Array(raw['mounts_rw']).map(&:to_s).reject(&:empty?).join(',')
    proj[:mounts_ro] = Array(raw['mounts_ro']).map(&:to_s).reject(&:empty?).join(',')
    proj[:timezone] = raw['timezone'] || 'Asia/Shanghai'
    proj[:proxy] = raw['proxy'] || proxy
    proj[:proxy_in_container] = raw['proxy_in_container'] || proxy_in_container || proj[:proxy]
    proj[:no_proxy] = raw['no_proxy'] || no_proxy
    proj[:memory] = raw['memory'] || default_memory
    proj[:docker_sock] = raw['docker_sock'] || false
    proj[:sandbox_allowed_domains] = DEFAULT_SANDBOX_DOMAINS + Array(raw['sandbox_allowed_domains']).map(&:to_s).reject(&:empty?)
    proj[:extra_prompt] = extra.empty? ? nil : extra
    proj
  end

  def resolve_paths(proj)
    proj[:path] = File.expand_path(proj[:path])
    proj
  end

  def setup_cp_files(proj)
    raw = proj.delete(:raw)
    base_cp = load_config.dig('base', 'cp_files')
    proj[:cp_files] = build_cp_files(raw, base_cp)
    proj[:cp_files_base_keys] = base_cp.is_a?(Hash) ? base_cp.keys.freeze : [].freeze
    proj
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

  def reporting_enabled?
    cfg = load_config
    return true unless cfg.is_a?(Hash)
    reporting = cfg['reporting']
    return true unless reporting.is_a?(Hash)
    reporting['enabled'] != false
  end
end

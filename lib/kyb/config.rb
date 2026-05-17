# frozen_string_literal: true

module Kyb::Config
  module_function

  def load
    Kyb.die("#{Kyb::CONFIG_FILE} not found") unless File.exist?(Kyb::CONFIG_FILE)
    @config ||= YAML.safe_load_file(Kyb::CONFIG_FILE, permitted_classes: [Symbol])
  end

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
    File.expand_path(load.dig('base', 'image'))
  end

  def project(name)
    p = load.dig('projects', name)
    Kyb.die("'#{name}' not found in #{Kyb::CONFIG_FILE}") unless p
    base_extra = load.dig('base', 'extra_prompt')
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
      extra_prompt: extra.empty? ? nil : extra
    }
  end

  def project_names
    (load['projects'] || {}).keys.sort
  end
end

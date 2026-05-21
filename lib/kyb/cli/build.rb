# frozen_string_literal: true

module Kyb::CLI
  module_function

  def build
    if Kyb.in_container?
      puts "build 命令不应在容器内运行"
      exit 1
    end
    Kyb::Config.load_config
    path = Kyb::Config.base_image_path
    dockerfile = File.join(path, 'Dockerfile')
    Kyb.die("Dockerfile not found at #{dockerfile}") unless File.exist?(dockerfile)

    Kyb::Check.run_checks

    proxy = Kyb::Proxy.detect
    Kyb::Docker.build(Kyb::Container::BASE_IMAGE, path, proxy: proxy)
    puts "==> Build complete: #{Kyb::Container::BASE_IMAGE}"
  end
end

# frozen_string_literal: true

module Kyb::CLI
  module_function

  def build
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

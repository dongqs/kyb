# frozen_string_literal: true

module Kyb::CLI
  module_function

  def build
    Kyb::Config.load_config
    path = Kyb::Config.base_image_path
    dockerfile = File.join(path, 'Dockerfile')
    Kyb.die("Dockerfile not found at #{dockerfile}") unless File.exist?(dockerfile)
    Kyb::Docker.build(Kyb::Container::BASE_IMAGE, path)
    puts "==> Build complete: #{Kyb::Container::BASE_IMAGE}"
  end
end

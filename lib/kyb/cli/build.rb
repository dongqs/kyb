# frozen_string_literal: true

module Kyb::CLI
  module_function

  def build
    Kyb::Config.load_config
    path = Kyb::Config.base_image_path
    Kyb::Docker.build(Kyb::Container::BASE_IMAGE, path)
    puts "==> Build complete: #{Kyb::Container::BASE_IMAGE}"
  end
end

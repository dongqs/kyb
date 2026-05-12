# frozen_string_literal: true

module Kyb::CLI
  module_function

  def build
    Kyb::Config.load
    path = Kyb::Config.base_image_path
    Kyb::Docker.build(Kyb::BASE_IMAGE, path)
    puts "==> (◕‿‿◕) Build complete: #{Kyb::BASE_IMAGE}"
  end
end

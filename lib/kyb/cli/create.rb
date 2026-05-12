# frozen_string_literal: true

module Kyb::CLI
  module_function

  def create(name, suffix = nil, port_overrides = nil)
    container, ports = Kyb::Docker.create_container(name, suffix, port_overrides)
    proj = Kyb::Config.project(name)
    image = Kyb::BASE_IMAGE
    image = Kyb::Docker.project_image(name, File.join(proj[:path], proj[:dockerfile]), proj[:path]) if proj[:dockerfile]

    puts
    puts "==> (◕‿‿◕) Sandbox ready! Container: #{container}  Image: #{image}  Ports: #{ports || 'none'}"
    puts "    kyb enter #{name}#{suffix ? " #{suffix}" : ''}"
  end
end

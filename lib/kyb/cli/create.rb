# frozen_string_literal: true

module Kyb::CLI
  module_function

  def create(project, branch, port_overrides = nil, model: nil)
    container, ports = Kyb::Docker.create_container(project, branch, port_overrides, model: model)
    proj = Kyb::Config.project(project)
    image = Kyb::Container::BASE_IMAGE
    image = Kyb::Docker.project_image(project, File.join(proj[:path], proj[:dockerfile]), proj[:path]) if proj[:dockerfile]

    puts
    puts "==> ／人◕ ‿‿ ◕人＼ Container ready! Container: #{container}  Image: #{image}  Ports: #{ports || 'none'}"
    puts "    kyb enter #{project}-#{branch}"
  end
end

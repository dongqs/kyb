# frozen_string_literal: true

module Kyb::CLI
  module_function

  def create(project, branch, port_overrides = nil, model: nil)
    container, ports = Kyb::Docker.create_container(project, branch, port_overrides, model: model)
    proj = Kyb::Config.project(project)
    image = Kyb::Container::BASE_IMAGE
    image = Kyb::Docker.project_image(project, File.join(proj[:path], proj[:dockerfile]), proj[:path]) if proj[:dockerfile]

    if Kyb::Docker.image_exists?(Kyb::Container::BASE_IMAGE)
      path = Kyb::Config.base_image_path
      if Kyb::Docker.stale?(Kyb::Container::BASE_IMAGE, path)
        puts
        puts "==> ⚠ kyb-base:latest is outdated (Dockerfile changed)."
        puts "    Run 'kyb build' on host to update."
        print "    Continue? [Y/n] (5s auto: Y) "
        STDOUT.flush
        input = IO.select([STDIN], nil, nil, 5)
        if input
          ans = STDIN.gets.to_s.strip.downcase
          if ans == 'n' || ans == 'no'
            puts "    Aborted."
            exit 0
          end
        else
          puts
        end
      end
    end

    puts
    puts "==> ／人◕ ‿‿ ◕人＼ Container ready! Container: #{container}  Image: #{image}  Ports: #{ports || 'none'}"
    puts "    kyb enter #{project}-#{branch}"
  end
end

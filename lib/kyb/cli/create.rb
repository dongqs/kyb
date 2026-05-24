# frozen_string_literal: true

module Kyb::CLI
  module_function

  def create(project, branch, port_overrides = nil, model: nil, repo_root: nil, worldview: nil, diversity: nil)
    if diversity
      create_diverse(project, branch, port_overrides, model: model, repo_root: repo_root, diversity: diversity)
      return
    end

    if Kyb.in_container?
      puts "⚠️ create 命令不应在容器内运行"
      exit 1
    end
    container, ports = Kyb::Docker.create_container(project, branch, port_overrides, model: model, repo_root: repo_root)

    if worldview
      Kyb::Worldview.assign(container, worldview)
      puts "==> 世界观: #{worldview}"
    end
    proj = Kyb::Config.project(project)
    image = Kyb::Container::BASE_IMAGE
    image = Kyb::Container.new(project, nil).project_image if proj[:dockerfile]

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

    mode = repo_root == 'isolated_local_repo_clone' ? 'clone' : 'mount'
    Kyb::Reporter.emit_container_create(project: project, branch: branch, mode: mode)

    puts
    puts "==> ／人◕ ‿‿ ◕人＼ Container ready! Container: #{container}  Image: #{image}  Ports: #{ports || 'none'}"
    puts "    kyb enter #{project}-#{branch}"
  end
end

def create_diverse(project, branch, port_overrides = nil, model: nil, repo_root: nil, diversity: 1)
  worldviews = Kyb::Worldview.sample_without_replacement(diversity)
  puts "==> Creating #{worldviews.size} containers with diverse worldviews:"
  worldviews.each do |wv_name|
    suffix = wv_name.gsub(/[^a-z0-9-]/, '')
    diverse_branch = "#{branch}-#{suffix}"
    puts "  kyb-#{project}-#{diverse_branch} <- #{wv_name}"
    container_obj = Kyb::Container.new(project, diverse_branch)
    if container_obj.exists?
      puts "    \u26a0 already exists, skipping"
      next
    end
    begin
      cname, ports = Kyb::Docker.create_container(project, diverse_branch, port_overrides, model: model, repo_root: repo_root)
      Kyb::Worldview.assign(cname, wv_name)
      puts "    \u2713 created (ports: #{ports || 'none'})"
    rescue => e
      puts "    \u2717 failed: #{e.message}"
    end
  end
end

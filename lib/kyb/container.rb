# frozen_string_literal: true

module Kyb
  class Container
    BASE_IMAGE = 'kyb-base'
    BRANCH_PREFIX = 'kyb'
    LABEL = 'kyb=true'

    attr_reader :project, :branch

    def self.filter
      'name=kyb-'
    end

    def initialize(project, branch, name: nil)
      @project = project
      @branch = branch
      @name = name || "kyb-#{project}-#{branch}"
    end

    def name
      @name
    end

    def to_s
      name
    end

    def hostname
      name
    end

    def git_branch
      "#{BRANCH_PREFIX}/#{project}-#{branch}" if project
    end

    def worktree_path
      File.join(Kyb::WORKTREE_BASE, project, name) if project
    end

    def claude_volume
      "#{name}-claude"
    end

    def home_volume
      "#{name}-home"
    end

    def node_modules_volume
      "#{project}-node_modules" if project
    end

    def project_image
      "kyb-#{project}" if project
    end

    def running?
      Kyb::Docker.running?(name)
    end

    def exists?
      Kyb::Docker.exists?(name)
    end
  end
end

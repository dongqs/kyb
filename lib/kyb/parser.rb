# frozen_string_literal: true

module Kyb::Parser
  module_function

  VALID_BRANCH_RE = /\A[a-zA-Z0-9][a-zA-Z0-9_.-]*\z/

  def parse(str)
    Kyb::Config.load
    projects = Kyb::Config.project_names

    # try longest prefix match first
    candidates = projects.select { |p| str == p || str.start_with?("#{p}-") }
    if candidates.empty?
      Kyb.die("unknown project in '#{str}'\n  Known projects: #{projects.join(', ')}")
    end

    # longest match wins
    project = candidates.max_by(&:length)

    # warn if multiple candidates could match (ambiguity)
    if candidates.size > 1 && candidates.any? { |c| c != project }
      shorter = candidates.reject { |c| c == project }.join(', ')
      warn "WARNING: '#{str}' matched '#{project}' (longest). Also possible: #{shorter}"
    end

    branch = if str == project
               'kyb'
             else
               str[(project.length + 1)..]
             end

    validate_branch!(branch)

    [project, branch]
  end

  def validate_branch!(branch)
    return if branch.match?(VALID_BRANCH_RE)

    Kyb.die("invalid branch name '#{branch}' — must start with a letter or number" \
            " and contain only letters, numbers, underscores, dots, and hyphens")
  end

  def container(str)
    project, branch = parse(str)
    Kyb::Container.new(project, branch).name
  end

  def auto_detect
    Kyb::Config.load
    cwd = Dir.getwd
    Kyb::Config.project_names.each do |proj_name|
      proj = Kyb::Config.project(proj_name)
      proj_path = proj[:path]
      if cwd == proj_path || cwd.start_with?(proj_path + "/")
        return [proj_name, "kyb"]
      end
    end
    nil
  end
end
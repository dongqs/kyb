# frozen_string_literal: true

module Kyb::Parser
  module_function

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

    [project, branch]
  end

  def container(str)
    project, branch = parse(str)
    Kyb::Container.new(project, branch).name
  end
end

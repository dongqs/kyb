# frozen_string_literal: true

module Kyb::Git
  module_function

  def worktree_path(name, container)
    File.join(Kyb::WORKTREE_BASE, name, container)
  end

  def branch(container)
    "sandbox/#{container.sub('dev-', '')}"
  end

  def setup_worktree(repo_path, base_branch, worktree, container)
    branch_name = branch(container)

    if File.directory?(worktree)
      puts "==> worktree exists, reusing (#{worktree})"
      return
    end

    puts "==> creating worktree from origin/#{base_branch} (#{branch_name})"
    FileUtils.mkdir_p(File.dirname(worktree))
    Dir.chdir(repo_path) do
      system('git', 'fetch', 'origin', base_branch) || Kyb.die('git fetch failed')
      system('git', 'worktree', 'add', worktree, "origin/#{base_branch}", '-b', branch_name) ||
        Kyb.die('git worktree add failed')
    end
  end

  def remove_worktree(repo_path, worktree)
    return unless File.directory?(worktree)

    puts "==> removing worktree #{worktree}"
    Dir.chdir(repo_path) do
      unless system('git', 'worktree', 'remove', worktree)
        warn '     worktree remove failed, pruning...'
        FileUtils.rm_rf(worktree)
        system('git', 'worktree', 'prune')
      end
    end
  end

  def delete_local_branch(repo_path, container)
    branch_name = branch(container)
    Dir.chdir(repo_path) do
      return unless system('git', 'branch', '--list', branch_name, out: File::NULL) &&
                    !`git branch --list #{branch_name}`.strip.empty?
      puts "==> #{branch_name}: deleting local branch"
      system('git', 'branch', '-D', branch_name)
    end
  end

  def delete_remote_branch(repo_path, container)
    branch_name = branch(container)
    Dir.chdir(repo_path) do
      return unless system('git', 'ls-remote', '--heads', 'origin', branch_name, out: File::NULL) &&
                    !`git ls-remote --heads origin #{branch_name}`.strip.empty?
      puts "==> #{branch_name}: deleting remote branch"
      system('git', 'push', 'origin', '--delete', branch_name)
    end
  end
end

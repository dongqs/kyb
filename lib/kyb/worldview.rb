# frozen_string_literal: true

module Kyb
  module Worldview
    WORLDVIEW_DIR = File.expand_path('worldviews', __dir__)
    DESCRIPTIONS = {
      'system-cybernetics' => '系统论+控制论：整体视角、反馈环、涌现、分层抽象。适合分析复杂系统和架构问题。',
      'scientific-empiricism' => '科学实证主义：假设→实验→数据→结论，大胆假设小心求证。适合调试和性能优化。',
      'marxist-dialectics' => '实践论+矛盾论：抓住主要矛盾、实践检验真理、动态发展。适合排期和项目管理。',
      'first-principles' => '第一性原理：拆到不可分再重建、质疑所有默认假设。适合架构设计和创新。',
      'stoic-pragmatism' => '斯多葛实用主义：可控/不可控二分、最小可行、渐进迭代。适合不确定条件下的决策。',
    }.freeze
    module_function
    def list() = DESCRIPTIONS.map { |n, d| { name: n, description: d } }
    def show(name)
      path = File.join(WORLDVIEW_DIR, "#{name}.md")
      (path && File.exist?(path)) ? File.read(path) : nil
    end
    def load_worldview(name) = show(name)
    def random() = list.sample
    def sample_without_replacement(n)
      return [] if n.nil? || n <= 0
      DESCRIPTIONS.keys.sample([n, DESCRIPTIONS.size].min)
    end
    def kyb_dir
      d = File.expand_path('~/.kyb')
      FileUtils.mkdir_p(d) unless File.directory?(d); d
    end
    def assignment_path(c) = File.join(kyb_dir, "#{c}.worldview")
    def assign(c, w)
      p = assignment_path(c)
      w ? File.write(p, "#{w}\n") : FileUtils.rm_f(p)
    end
    def assigned(c)
      p = assignment_path(c)
      File.exist?(p) ? File.read(p).strip : nil
    end
  end
end

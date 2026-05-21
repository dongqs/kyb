# frozen_string_literal: true

module Kyb::CLI
  module_function
  def worldview(args)
    case args.first
    when 'list' then worldview_list
    when 'show' then worldview_show(args[1])
    else worldview_help
    end
  end
  def worldview_list
    puts "Available worldviews:\n\n"
    Kyb::Worldview.list.each { |w| puts "  #{w[:name]}\n    #{w[:description]}\n\n" }
  end
  def worldview_show(name)
    Kyb.die("Usage: kyb worldview show <name>") unless name
    c = Kyb::Worldview.show(name)
    Kyb.die("Unknown: #{name}\n  Run `kyb worldview list`") unless c
    puts c
  end
  def worldview_help
    puts "Usage: kyb worldview <command>\n\nCommands:\n  list       List worldviews\n  show NAME  Show worldview content\n"
  end
  def inject_worldview(prompt, name)
    return prompt unless name
    c = Kyb::Worldview.show(name)
    return prompt unless c
    "#{prompt}\n\n## 世界观（#{name}）\n#{c.strip}"
  end
end

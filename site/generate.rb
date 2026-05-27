#!/usr/bin/env ruby
# Generate kybkyb.com static site from diary/ markdown files.
# Usage: ruby site/generate.rb [output_dir]
# Deps: gem install kramdown

require 'kramdown'
require 'fileutils'

OUTPUT = ARGV[0] || 'public'
DIARY  = File.join(__dir__, '..', 'diary')

# Build navigation tree
def tree(dir, prefix = '')
  entries = []
  Dir.children(dir).sort.each do |name|
    path = File.join(dir, name)
    rel  = prefix.empty? ? name : "#{prefix}/#{name}"
    if File.directory?(path)
      children = tree(path, rel)
      entries << { name: name, path: rel, dir: true, children: children } unless children.empty?
    elsif name.end_with?('.md') && name != 'README.md'
      entries << { name: name.sub(/\.md$/, ''), path: rel, dir: false }
    end
  end
  entries
end

def render_nav(entries, depth = 0)
  html = '<ul class="nav-list">'
  entries.each do |e|
    if e[:dir]
      html += "<li class='nav-dir'><span class='dir-label'>#{e[:name]}</span>"
      html += render_nav(e[:children], depth + 1)
      html += '</li>'
    else
      target = e[:path].sub(/\.md$/, '.html')
      html += "<li class='nav-file'><a href='/#{target}'>#{e[:name]}</a></li>"
    end
  end
  html += '</ul>'
  html
end

NAV_CACHE = nil
def nav_html
  @nav_html ||= render_nav(tree(DIARY))
end

# Convert .md content to HTML body
def md_to_html(content)
  Kramdown::Document.new(content).to_html
rescue => e
  "<p><strong>Error rendering:</strong> #{e.message}</p>"
end

# Extract first h1 as title
def extract_title(content)
  m = content.match(/^#\s+(.+)$/)
  m ? m[1] : 'kyb'
end

LAYOUT = <<~HTML
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>%TITLE% — kyb</title>
<link rel="stylesheet" href="/style.css">
</head>
<body>
<div class="layout">
  <nav class="sidebar">
    <div class="site-name"><a href="/">kyb</a></div>
    %NAV%
  </nav>
  <main class="content">
    <article>%BODY%</article>
    <footer><a href="https://git.leyantech.com/quick-n-dirty/kyb">Source</a></footer>
  </main>
</div>
</body>
</html>
HTML

STYLESHEET = <<~CSS
* { margin: 0; padding: 0; box-sizing: border-box; }
body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', system-ui, sans-serif;
       background: #fafafa; color: #1a1a1a; line-height: 1.7; font-size: 16px; }
.layout { display: flex; min-height: 100vh; }
.sidebar { width: 260px; background: #fff; border-right: 1px solid #e0e0e0;
           padding: 24px; overflow-y: auto; position: sticky; top: 0; height: 100vh; }
.sidebar .site-name { font-size: 20px; font-weight: 700; margin-bottom: 16px; }
.sidebar .site-name a { color: #1a1a1a; text-decoration: none; }
.nav-list { list-style: none; margin: 0; padding-left: 0; }
.nav-dir { margin: 6px 0; }
.dir-label { font-size: 13px; font-weight: 600; text-transform: uppercase;
             color: #666; letter-spacing: 0.05em; }
.nav-dir .nav-list { padding-left: 12px; margin: 2px 0 6px; }
.nav-file { margin: 2px 0; }
.nav-file a { color: #444; text-decoration: none; font-size: 14px; }
.nav-file a:hover { color: #0066cc; }
.content { flex: 1; max-width: 800px; padding: 48px 40px; }
.content h1 { font-size: 28px; margin-bottom: 16px; border-bottom: 1px solid #eee; padding-bottom: 8px; }
.content h2 { font-size: 22px; margin: 24px 0 12px; }
.content h3 { font-size: 18px; margin: 20px 0 10px; }
.content p { margin: 12px 0; }
.content code { background: #f0f0f0; padding: 2px 6px; border-radius: 3px; font-size: 0.9em; }
.content pre { background: #f5f5f5; padding: 16px; border-radius: 6px; overflow-x: auto; margin: 12px 0; }
.content pre code { background: none; padding: 0; }
.content blockquote { border-left: 3px solid #ddd; padding-left: 16px; color: #555; margin: 16px 0; }
.content table { border-collapse: collapse; width: 100%; margin: 12px 0; }
.content th, .content td { border: 1px solid #e0e0e0; padding: 8px 12px; text-align: left; }
.content th { background: #f5f5f5; }
.content img { max-width: 100%; }
footer { margin-top: 48px; padding-top: 16px; border-top: 1px solid #eee; font-size: 13px; color: #888; }
footer a { color: #888; }
@media (max-width: 768px) {
  .layout { flex-direction: column; }
  .sidebar { width: 100%; height: auto; position: static; border-right: none; border-bottom: 1px solid #e0e0e0; padding: 16px 20px; }
  .content { padding: 24px 20px; }
}
CSS

# Convert all markdown files
def convert_all
  # Clean and create output dir
  FileUtils.rm_rf(OUTPUT)
  FileUtils.mkdir_p(OUTPUT)

  # Write stylesheet
  File.write(File.join(OUTPUT, 'style.css'), STYLESHEET)

  # Pre-build nav
  nav = nav_html

  # Walk diary/
  Dir.glob(File.join(DIARY, '**', '*.md')).each do |path|
    rel = path.sub("#{DIARY}/", '').sub(/\.md$/, '.html')
    out_path = File.join(OUTPUT, rel)

    content = File.read(path)
    title   = extract_title(content)
    body    = md_to_html(content)

    page = LAYOUT.gsub('%TITLE%', title).gsub('%NAV%', nav).gsub('%BODY%', body)

    FileUtils.mkdir_p(File.dirname(out_path))
    File.write(out_path, page)
  end

  # Index page
  body = <<~HOME
    <h1>kyb</h1>
    <p>一个 CLI 工具到纯知识的蜕变记录。</p>
    <p>始于 2026-05-21 一场 FizzBuzz，终于 kybkyb.com。<!-- -->95 篇日记，全透明。</p>
    <h2>从哪开始读</h2>
    <ul>
      <li><a href="/reference/concepts/01-负熵晶体.html">01-负熵晶体</a> — 核心理念</li>
      <li><a href="/架构师之旅/01-初次接触.html">架构师之旅 01</a> — 四天四夜叙事</li>
      <li><a href="/reference/concepts/15-全透明.html">全透明</a> — 最终结论</li>
    </ul>
    <p><a href="README.html">查看完整介绍 →</a></p>
  HOME
  index = LAYOUT.gsub('%TITLE%', 'kyb').gsub('%NAV%', nav).gsub('%BODY%', body)
  File.write(File.join(OUTPUT, 'index.html'), index)

  puts "Generated #{OUTPUT}/ (#{Dir.glob(File.join(OUTPUT, '**', '*.html')).size} pages)"
end

convert_all

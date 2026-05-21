# frozen_string_literal: true
module Kyb::Reporter
  module_function
  def enabled?; false; end
  def emit(**); end
  def emit_build_duration(**); end
  def emit_create_event(**); end
  def emit_rm_event(**); end
  def emit_container_count(**); end
  def emit_preflight_result(**); end
  def emit_proxy_status(**); end
end

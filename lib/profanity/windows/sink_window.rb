# frozen_string_literal: true

=begin
Null-object window that silently discards all content.
=end

# Null-object window that silently discards content.
#
# Use this to hide streams without creating a visible window. Inherits
# from {BaseWindow} for LSP compliance and type safety, but all content
# methods are no-ops. Sink windows are excluded from the window registry
# so they never appear in {BaseWindow.find_window_at} or iteration over
# visible windows.
#
# @example Layout XML usage
#   <window class='sink' value='atmospherics'/>
#   <window class='sink' value='combat,assess'/>
class SinkWindow < BaseWindow
  # Don't track sinks in the window list — they should never
  # appear in find_window_at or iteration over visible windows.
  def self.register_instance(_instance); end

  def initialize
    super(1, 1, 0, 0)
  end

  # All content methods are no-ops
  def add_string(*); end
  def add_string_to_tab(*); end
  def route_string(*); end
  def add_line(*); end
  def redraw; end

  def duplicate_prompt?(_prompt_text)
    false
  end
end

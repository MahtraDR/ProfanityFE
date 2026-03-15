# frozen_string_literal: true

# Null-object window that silently discards all content.

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
  # No-op: sinks are excluded from the window registry so they
  # never appear in {BaseWindow.find_window_at} or visible-window iteration.
  #
  # @param _instance [SinkWindow] ignored
  # @return [void]
  def self.register_instance(_instance); end

  # Create a 1x1 off-screen window for stream suppression.
  def initialize
    super(1, 1, 0, 0)
  end

  # No-op: discards incoming text. Stream is suppressed.
  #
  # @return [void]
  def add_string(*); end

  # No-op: discards tab-routed text. Stream is suppressed.
  #
  # @return [void]
  def add_string_to_tab(*); end

  # No-op: discards routed text. Stream is suppressed.
  #
  # @return [void]
  def route_string(*); end

  # No-op: discards rendered lines. Stream is suppressed.
  #
  # @return [void]
  def add_line(*); end

  # No-op: nothing to redraw. Stream is suppressed.
  #
  # @return [void]
  def redraw; end

  # Always returns false since sinks have no buffer content to match.
  #
  # @param _prompt_text [String] ignored
  # @return [Boolean] always false
  def duplicate_prompt?(_prompt_text)
    false
  end
end

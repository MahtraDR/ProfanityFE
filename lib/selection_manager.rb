# frozen_string_literal: true

# selection_manager.rb: Mouse text selection and clipboard operations for ProfanityFE.

# Manages mouse text selection state and clipboard operations.
# Active when .links is enabled (which captures mouse events).
# Selection is per-window: drag coordinates are clamped to the
# active window's bounds so selections never bleed across windows.
#
# The highlight persists after release so the user can see what was
# selected. It is cleared on the next mouse press or link click.
# Selected text is copied to the system clipboard (pbcopy/xclip/wl-copy),
# OSC 52 (for remote/SSH sessions), and /tmp/profanity_selection.txt.
module SelectionManager
  @active_window = nil
  @start_y = nil
  @start_x = nil
  @end_y = nil
  @end_x = nil
  @selecting = false

  class << self
    attr_reader :active_window, :start_y, :start_x, :end_y, :end_x, :selecting

    # Return the starting [y, x] coordinates as a pair, or nil if no selection.
    #
    # @return [Array<Integer>, nil] [y, x] pair or nil
    def start_pos
      @start_y && @start_x ? [@start_y, @start_x] : nil
    end

    # Begin a new text selection at the given window coordinates.
    # Clears any previous selection highlight first.
    #
    # @param window [BaseWindow] the window where selection starts
    # @param y [Integer] starting row (window-relative)
    # @param x [Integer] starting column (window-relative)
    # @return [void]
    def start_selection(window, y, x)
      clear_selection
      @active_window = window
      @start_y = y
      @start_x = x
      @end_y = y
      @end_x = x
      @selecting = true
    end

    # Extend the current selection to a new endpoint and redraw highlights.
    #
    # @param y [Integer] new end row (window-relative)
    # @param x [Integer] new end column (window-relative)
    # @return [void]
    def update_selection(y, x)
      return unless @selecting && @active_window

      @end_y = y
      @end_x = x
      @active_window.highlight_selection(@start_y, @start_x, @end_y, @end_x)
    end

    # Finalize the selection and copy text to the clipboard.
    # The highlight is kept visible until the next selection or click.
    #
    # @return [void]
    def end_selection
      return unless @selecting && @active_window

      @selecting = false
      text = @active_window.extract_selection(@start_y, @start_x, @end_y, @end_x)
      if text && !text.empty?
        copy_to_clipboard(text)
      else
        ProfanityLog.write('SelectionManager', "No text extracted: start=(#{@start_y},#{@start_x}) end=(#{@end_y},#{@end_x})")
      end
      # Keep highlight visible — cleared on next start_selection or clear_selection
    end

    # Reset all selection state and clear any active highlight.
    #
    # @return [void]
    def clear_selection
      @active_window&.clear_highlight
      @active_window = nil
      @start_y = @start_x = @end_y = @end_x = nil
      @selecting = false
    end

    # Copy text to the system clipboard, OSC 52, and a temp file.
    #
    # Tries platform-native clipboard commands first (pbcopy on macOS,
    # xclip or wl-copy on Linux), then OSC 52 for remote/SSH sessions,
    # and always writes to /tmp/profanity_selection.txt as a fallback.
    #
    # @param text [String] the text to copy
    # @return [void]
    def copy_to_clipboard(text)
      # Try platform-native clipboard
      clipboard_cmd = if RbConfig::CONFIG['host_os'] =~ /darwin/
                        'pbcopy'
                      elsif ENV['WAYLAND_DISPLAY']
                        'wl-copy'
                      elsif ENV['DISPLAY']
                        'xclip -selection clipboard'
                      end

      if clipboard_cmd
        IO.popen(clipboard_cmd, 'w') { |io| io.write(text) }
        ProfanityLog.write('Clipboard', "Copied #{text.length} chars via #{clipboard_cmd}")
      end

      # OSC 52 for remote/SSH sessions (write to tty to avoid curses interference)
      encoded = [text].pack('m0')
      begin
        File.open('/dev/tty', 'w') { |tty| tty.write("\e]52;c;#{encoded}\a") }
      rescue StandardError
        nil # /dev/tty may not be available in all environments
      end

      # Always write to file as fallback
      File.write('/tmp/profanity_selection.txt', text)
    rescue StandardError => e
      ProfanityLog.write('Clipboard', "Error: #{e.message}")
    end
  end
end

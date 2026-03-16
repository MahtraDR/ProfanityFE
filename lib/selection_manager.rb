# frozen_string_literal: true

# selection_manager.rb: Mouse text selection and clipboard operations for ProfanityFE.

# Manages mouse text selection state and clipboard operations.
# Active when .links is enabled (which captures mouse events).
# Selection is per-window: drag coordinates are clamped to the
# active window's bounds so selections never bleed across windows.
# Copies selected text via OSC 52 and /tmp/profanity_selection.txt.
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
    #
    # @param window [TextWindow] the window where selection starts
    # @param y [Integer] starting row
    # @param x [Integer] starting column
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
    # @param y [Integer] new end row
    # @param x [Integer] new end column
    # @return [void]
    def update_selection(y, x)
      return unless @selecting && @active_window

      @end_y = y
      @end_x = x
      @active_window.highlight_selection(@start_y, @start_x, @end_y, @end_x)
    end

    # Finalize the selection, copy extracted text to the clipboard, and clear highlights.
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
      @active_window.clear_highlight
      clear_selection
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

    # Copy text to the clipboard via file and OSC 52 escape sequence.
    #
    # @param text [String] the text to copy
    # @return [void]
    def copy_to_clipboard(text)
      # Always write to file for SSH/Screen scenarios
      File.write('/tmp/profanity_selection.txt', text)

      # Also try OSC 52 which might work depending on terminal/Screen config
      encoded = [text].pack('m0')
      print "\e]52;c;#{encoded}\a"
      $stdout.flush

      ProfanityLog.write('Clipboard', "Saved #{text.length} chars to /tmp/profanity_selection.txt")
    rescue StandardError => e
      ProfanityLog.write('Clipboard', "Error: #{e.message}")
    end
  end
end

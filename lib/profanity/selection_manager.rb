# frozen_string_literal: true

# selection_manager.rb: Mouse text selection and clipboard operations for ProfanityFE.
# Currently dormant — mouse tracking is disabled (breaks terminal copy/paste).

# Manages mouse text selection state and clipboard operations
# GNU Screen compatible - uses external clipboard commands (pbcopy/xclip/wl-copy)
module SelectionManager
  @active_window = nil
  @start_y = nil
  @start_x = nil
  @end_y = nil
  @end_x = nil
  @selecting = false

  class << self
    attr_reader :active_window, :start_y, :start_x, :end_y, :end_x, :selecting

    def start_selection(window, y, x)
      clear_selection
      @active_window = window
      @start_y = y
      @start_x = x
      @end_y = y
      @end_x = x
      @selecting = true
    end

    def update_selection(y, x)
      return unless @selecting && @active_window

      @end_y = y
      @end_x = x
      @active_window.highlight_selection(@start_y, @start_x, @end_y, @end_x)
    end

    def end_selection
      return unless @selecting && @active_window

      @selecting = false
      text = @active_window.extract_selection(@start_y, @start_x, @end_y, @end_x)
      if text && !text.empty?
        copy_to_clipboard(text)
      else
        File.open(LOG_FILE, 'a') do |f|
          f.puts "[SelectionManager] No text extracted: start=(#{@start_y},#{@start_x}) end=(#{@end_y},#{@end_x})"
        end
      end
      @active_window.clear_highlight
      clear_selection
    end

    def clear_selection
      @active_window&.clear_highlight
      @active_window = nil
      @start_y = @start_x = @end_y = @end_x = nil
      @selecting = false
    end

    def copy_to_clipboard(text)
      # Always write to file for SSH/Screen scenarios
      File.write('/tmp/profanity_selection.txt', text)

      # Also try OSC 52 which might work depending on terminal/Screen config
      encoded = [text].pack('m0')
      print "\e]52;c;#{encoded}\a"
      $stdout.flush

      File.open(LOG_FILE, 'a') { |f| f.puts "[Clipboard] Saved #{text.length} chars to /tmp/profanity_selection.txt" }
    rescue StandardError => e
      File.open(LOG_FILE, 'a') { |f| f.puts "[Clipboard] Error: #{e.message}" }
    end
  end
end

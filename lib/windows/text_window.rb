# frozen_string_literal: true

# Main scrollable text buffer window with word wrap, timestamps, and selection.

# Scrollable text buffer window.
#
# Displays a reverse-ordered buffer of word-wrapped lines with optional
# timestamps. Supports keyboard scrolling, scrollbar rendering, and
# mouse-based text selection with copy support.
class TextWindow < BaseWindow
  # @return [Array<Array(String, Array<Hash>)>] the line buffer (newest first)
  attr_reader :buffer

  # @return [Integer] maximum number of lines retained in the buffer
  attr_reader :max_buffer_size

  # @return [Boolean] whether continuation lines are indented during word wrap
  attr_accessor :indent_word_wrap

  # @return [Boolean] whether a timestamp is appended to each non-empty line
  attr_accessor :time_stamp

  # Create a new scrollable text window.
  #
  # @param args [Array] arguments forwarded to {BaseWindow#initialize}
  def initialize(*args)
    @buffer = []
    @buffer_pos = 0
    @max_buffer_size = DEFAULT_BUFFER_SIZE
    @indent_word_wrap = true
    super
  end

  # Return the line buffer for selection support.
  #
  # @return [Array<Array(String, Array<Hash>)>] the line buffer (newest first)
  def buffer_content
    @buffer
  end

  # Set the maximum number of lines retained in the buffer.
  #
  # @param val [Integer, #to_i] new buffer size limit
  # @return [void]
  def max_buffer_size=(val)
    @max_buffer_size = val.to_i
  end

  # Append a string to the buffer, word-wrapping to the window width.
  # If the window is not scrolled, the new text is rendered immediately;
  # otherwise the scroll position is adjusted.
  #
  # @param string [String] the text to append
  # @param string_colors [Array<Hash>] color region descriptors
  # @return [void]
  def add_string(string, string_colors = [])
    string += format_timestamp if @time_stamp && string && !string.chomp.empty?
    wrap_text(string, maxx - 1, string_colors, indent: @indent_word_wrap) do |line, line_colors|
      @buffer.unshift([line, line_colors])
      @buffer.pop if @buffer.length > @max_buffer_size
      if @buffer_pos == 0
        addstr "\n" unless line.chomp.empty?
        add_line(line, line_colors)
      else
        @buffer_pos += 1
        scroll(1) if @buffer_pos > (@max_buffer_size - maxy)
        update_scrollbar
      end
    end
    return unless @buffer_pos == 0

    noutrefresh
  end

  # Scroll the buffer by the given number of lines.
  # Negative values scroll up (toward older content), positive values scroll
  # down (toward newer content).
  #
  # @param scroll_num [Integer] lines to scroll (negative = up, positive = down)
  # @return [void]
  def scroll(scroll_num)
    if scroll_num < 0
      scroll_num = 0 - (@buffer.length - @buffer_pos - maxy) if (@buffer_pos + maxy + scroll_num.abs) >= @buffer.length
      if scroll_num < 0
        @buffer_pos += scroll_num.abs
        scrl(scroll_num)
        setpos(0, 0)
        pos = @buffer_pos + maxy - 1
        scroll_num.abs.times do
          add_line(@buffer[pos][0], @buffer[pos][1])
          addstr "\n"
          pos -= 1
        end
        noutrefresh
      end
      update_scrollbar
    elsif scroll_num > 0
      if @buffer_pos > 0
        scroll_num = @buffer_pos if (@buffer_pos - scroll_num) < 0
        @buffer_pos -= scroll_num
        scrl(scroll_num)
        setpos(maxy - scroll_num, 0)
        pos = @buffer_pos + scroll_num - 1
        (scroll_num - 1).times do
          add_line(@buffer[pos][0], @buffer[pos][1])
          addstr "\n"
          pos -= 1
        end
        add_line(@buffer[pos][0], @buffer[pos][1])
        noutrefresh
      end
    end
    update_scrollbar
  end

  # Refresh the scrollbar to reflect current buffer and scroll state.
  #
  # @return [void]
  def update_scrollbar
    render_scrollbar(@buffer.length, @buffer_pos, maxy)
  end

  # Clear (hide) the scrollbar.
  #
  # @return [void]
  def clear_scrollbar
    reset_scrollbar
  end

  # Check if the most recent non-empty line matches the given prompt text.
  # Used to suppress duplicate bare prompts.
  #
  # @param prompt_text [String] the prompt string to check against
  # @return [Boolean] true if the last non-empty buffer line equals prompt_text
  def duplicate_prompt?(prompt_text)
    return false if @buffer.empty?

    recent_line = @buffer.find { |entry| entry[0] && !entry[0].empty? }
    recent_line && recent_line[0] == prompt_text
  end

  # Extract text from buffer for a selection region.
  # Buffer is stored in reverse order: @buffer[0] = newest line.
  # Window y=0 is top, y=maxy-1 is bottom (showing newest when not scrolled).
  #
  # @param start_y [Integer] starting row (window-relative)
  # @param start_x [Integer] starting column
  # @param end_y [Integer] ending row (window-relative)
  # @param end_x [Integer] ending column
  # @return [String] the selected text, lines joined by newlines
  def extract_selection(start_y, start_x, end_y, end_x)
    # Normalize coordinates (ensure start before end)
    if start_y > end_y || (start_y == end_y && start_x > end_x)
      start_y, end_y = end_y, start_y
      start_x, end_x = end_x, start_x
    end

    lines = []
    (start_y..end_y).each do |y|
      buffer_idx = @buffer_pos + (maxy - 1 - y)
      next if buffer_idx >= @buffer.length || buffer_idx < 0

      line_text = @buffer[buffer_idx][0] || ''
      lines << if y == start_y && y == end_y
                 line_text[start_x...end_x]
               elsif y == start_y
                 line_text[start_x..-1]
               elsif y == end_y
                 line_text[0...end_x]
               else
                 line_text
               end
    end
    lines.join("\n")
  end

  # Redraw all visible lines, applying reverse-video to the selected region.
  #
  # @return [void]
  def redraw_with_highlight
    return unless @selection_start && @selection_end

    start_y, start_x = @selection_start
    end_y, end_x = @selection_end

    # Normalize
    if start_y > end_y || (start_y == end_y && start_x > end_x)
      start_y, end_y = end_y, start_y
      start_x, end_x = end_x, start_x
    end

    # Redraw visible lines with highlight
    (0...maxy).each do |y|
      buffer_idx = @buffer_pos + (maxy - 1 - y)
      next if buffer_idx >= @buffer.length || buffer_idx < 0

      line_text, line_colors = @buffer[buffer_idx]
      setpos(y, 0)
      clrtoeol

      if y >= start_y && y <= end_y
        draw_line_with_selection(y, line_text, line_colors, start_y, start_x, end_y, end_x)
      else
        add_line(line_text, line_colors)
      end
    end
    noutrefresh
  end

  private

  # Draw a single line with reverse-video highlighting for the selected region.
  #
  # @param y [Integer] the window row being drawn
  # @param line_text [String] full text of the line
  # @param line_colors [Array<Hash>] color regions for the line
  # @param start_y [Integer] selection start row
  # @param start_x [Integer] selection start column
  # @param end_y [Integer] selection end row
  # @param end_x [Integer] selection end column
  # @return [void]
  # @api private
  def draw_line_with_selection(y, line_text, line_colors, start_y, start_x, end_y, end_x)
    return if line_text.nil?

    sel_start = y == start_y ? start_x : 0
    sel_end = y == end_y ? end_x : line_text.length

    # Draw pre-selection text normally
    if sel_start > 0
      pre_text = line_text[0...sel_start]
      pre_colors = line_colors.map do |h|
        { start: h[:start], end: [h[:end], sel_start].min, fg: h[:fg], bg: h[:bg], ul: h[:ul] }
      end.select { |h| h[:end] > h[:start] }
      add_line(pre_text, pre_colors)
    end

    # Draw selected text with reverse video
    if sel_end > sel_start
      selected_text = line_text[sel_start...sel_end] || ''
      attron(Curses::A_REVERSE) do
        addstr selected_text
      end
    end

    # Draw post-selection text normally
    return unless sel_end < line_text.length

    post_text = line_text[sel_end..-1]
    post_colors = line_colors.map do |h|
      new_start = [h[:start] - sel_end, 0].max
      new_end = h[:end] - sel_end
      { start: new_start, end: new_end, fg: h[:fg], bg: h[:bg], ul: h[:ul] }
    end.select { |h| h[:end] > 0 && h[:end] > h[:start] }
    add_line(post_text, post_colors)
  end
end

# frozen_string_literal: true

# Multi-tab text window sharing one display area with tab bar and keyboard switching.

# Multi-tab text window.
#
# Manages multiple named text buffers that share a single display area.
# A tab bar at the top shows all tabs with an activity indicator (*) for
# background tabs that have received new content. Tabs can be switched by
# name, index, or next/prev cycling. Each tab maintains its own independent
# scroll position.
class TabbedTextWindow < BaseWindow
  # Height in rows reserved for the tab bar at the top of the window.
  TAB_BAR_HEIGHT = 1

  # @return [Hash{String => Array}] tab name to line buffer mapping
  attr_reader :tabs

  # @return [String, nil] name of the currently displayed tab
  attr_reader :active_tab

  # @return [Integer] maximum number of lines retained per tab buffer
  attr_reader :max_buffer_size

  # @return [Boolean] whether continuation lines are indented during word wrap
  attr_accessor :indent_word_wrap

  # @return [Boolean] whether a timestamp is appended to each non-empty line
  attr_accessor :time_stamp

  # Create a new tabbed text window with an empty tab set.
  #
  # @param args [Array] arguments forwarded to {BaseWindow#initialize}
  def initialize(*args)
    @tabs = {}              # { "main" => [[line, colors], ...], ... }
    @buffer_positions = {}  # Per-tab scroll positions
    @tab_activity = {}      # Track unread content in background tabs
    @active_tab = nil
    @max_buffer_size = DEFAULT_BUFFER_SIZE
    @indent_word_wrap = true
    super
    # Set scroll region to exclude tab bar (row 0)
    setscrreg(TAB_BAR_HEIGHT, maxy - 1)
  end

  # Set the maximum number of lines retained per tab buffer.
  #
  # @param val [Integer, #to_i] new buffer size limit
  # @return [void]
  def max_buffer_size=(val)
    @max_buffer_size = val.to_i
  end

  # Add a new named tab to this window.
  # The first tab added becomes the active tab.
  #
  # @param name [String] unique tab name (e.g. "main", "combat")
  # @return [void]
  def add_tab(name)
    @tabs[name] = []
    @buffer_positions[name] = 0
    @tab_activity[name] = false
    @active_tab ||= name
    draw_tab_bar
  end

  # Return the active tab's line buffer for TextWindow-compatible access.
  #
  # @return [Array<Array(String, Array<Hash>)>] line buffer of the active tab
  def buffer
    @tabs[@active_tab] || []
  end

  # Return the active tab's scroll offset.
  #
  # @return [Integer] number of lines scrolled from the bottom
  def buffer_pos
    @buffer_positions[@active_tab] || 0
  end

  # Switch to a specific tab by name.
  # Clears the activity indicator and redraws the content area.
  #
  # @param name [String] the tab name to switch to
  # @return [void]
  def switch_tab(name)
    return unless @tabs.key?(name)
    return if name == @active_tab

    @active_tab = name
    @tab_activity[name] = false
    redraw
    draw_tab_bar
  end

  # Switch to the next tab, cycling back to the first after the last.
  #
  # @return [void]
  def next_tab
    return if @tabs.empty?

    tab_names = @tabs.keys
    current_idx = tab_names.index(@active_tab) || 0
    next_idx = (current_idx + 1) % tab_names.length
    switch_tab(tab_names[next_idx])
  end

  # Switch to the previous tab, cycling to the last after the first.
  #
  # @return [void]
  def prev_tab
    return if @tabs.empty?

    tab_names = @tabs.keys
    current_idx = tab_names.index(@active_tab) || 0
    prev_idx = (current_idx - 1) % tab_names.length
    switch_tab(tab_names[prev_idx])
  end

  # Switch to a tab by its 1-based index.
  #
  # @param index [Integer] 1-based tab position
  # @return [void]
  def switch_tab_by_index(index)
    tab_names = @tabs.keys
    return if index < 1 || index > tab_names.length

    switch_tab(tab_names[index - 1])
  end

  # Draw the tab bar at the top of the window.
  # Active tab is rendered with reverse video; background tabs with
  # unread content show an asterisk (*) activity indicator.
  #
  # @return [void]
  def draw_tab_bar
    setpos(0, 0)
    clrtoeol

    tab_names = @tabs.keys
    x_pos = 0

    tab_names.each_with_index do |name, idx|
      activity = @tab_activity[name] && name != @active_tab ? '*' : ''
      label = " #{idx + 1}:#{name}#{activity} "

      if name == @active_tab
        attron(Curses::A_REVERSE) do
          addstr(label)
        end
      else
        addstr(label)
      end
      x_pos += label.length

      addstr('|') if idx < tab_names.length - 1
      x_pos += 1
    end

    noutrefresh
  end

  # Height of the content area excluding the tab bar.
  #
  # @return [Integer] number of rows available for text content
  def content_height
    maxy - TAB_BAR_HEIGHT
  end

  # Route text to the appropriate tab based on stream name.
  # Falls back to the active tab (or "main") when the stream has no
  # dedicated tab.
  #
  # @param text [String] the text to display
  # @param colors [Array<Hash>] color region descriptors
  # @param stream [String, nil] stream name used for tab routing
  # @return [void]
  def route_string(text, colors, stream = nil)
    target_tab = stream && @tabs.key?(stream) ? stream : (@active_tab || MAIN_STREAM)
    add_string_to_tab(target_tab, text, colors)
  end

  # Check if the most recent non-empty line in the "main" tab matches the
  # given prompt text. Used to suppress duplicate bare prompts.
  #
  # @param prompt_text [String] the prompt string to check against
  # @return [Boolean] true if the last non-empty line in "main" equals prompt_text
  def duplicate_prompt?(prompt_text)
    main_buffer = @tabs[MAIN_STREAM] || []
    return false if main_buffer.empty?

    recent_line = main_buffer.find { |entry| entry[0] && !entry[0].empty? }
    recent_line && recent_line[0] == prompt_text
  end

  # Append a string to a specific tab's buffer.
  # If the tab is active and not scrolled, the text is rendered immediately.
  # Background tabs receive an activity indicator on the tab bar.
  #
  # @param tab_name [String] the target tab name
  # @param string [String] the text to append
  # @param string_colors [Array<Hash>] color region descriptors
  # @return [void]
  def add_string_to_tab(tab_name, string, string_colors = [])
    return unless @tabs.key?(tab_name)
    return if string.nil? || string.chomp.empty?

    string += format_timestamp if @time_stamp

    content_width = maxx - 1
    tab_buffer = @tabs[tab_name]
    tab_buffer_pos = @buffer_positions[tab_name]

    wrap_text(string, content_width, string_colors, indent: @indent_word_wrap) do |line, line_colors|
      tab_buffer.unshift([line, line_colors])
      tab_buffer.pop if tab_buffer.length > @max_buffer_size

      if tab_name == @active_tab
        if tab_buffer_pos == 0
          scrl(1) if tab_buffer.length > content_height
          visible_lines = [tab_buffer.length, content_height].min
          write_row = TAB_BAR_HEIGHT + visible_lines - 1
          setpos(write_row, 0)
          clrtoeol
          add_line(line, line_colors)
        else
          @buffer_positions[tab_name] += 1
          tab_buffer_pos = @buffer_positions[tab_name]
          scrl(1) if @buffer_positions[tab_name] > (@max_buffer_size - content_height)
          update_scrollbar
        end
      else
        unless @tab_activity[tab_name]
          @tab_activity[tab_name] = true
          draw_tab_bar
        end
      end
    end

    return unless tab_name == @active_tab && @buffer_positions[tab_name] == 0

    noutrefresh
  end

  # Append a string to the active tab's buffer.
  #
  # @param string [String] the text to append
  # @param string_colors [Array<Hash>] color region descriptors
  # @return [void]
  def add_string(string, string_colors = [])
    return unless @active_tab

    add_string_to_tab(@active_tab, string, string_colors)
  end

  # Scroll the active tab's buffer by the given number of lines.
  # Negative values scroll up (toward older content), positive values scroll
  # down (toward newer content).
  #
  # @param scroll_num [Integer] lines to scroll (negative = up, positive = down)
  # @return [void]
  def scroll(scroll_num)
    return unless @active_tab

    tab_buffer = @tabs[@active_tab]
    tab_buffer_pos = @buffer_positions[@active_tab]
    ch = content_height

    if scroll_num < 0
      if (tab_buffer_pos + ch + scroll_num.abs) >= tab_buffer.length
        scroll_num = 0 - (tab_buffer.length - tab_buffer_pos - ch)
      end
      if scroll_num < 0
        @buffer_positions[@active_tab] += scroll_num.abs
        setpos(TAB_BAR_HEIGHT, 0)
        scrl(scroll_num)
        setpos(TAB_BAR_HEIGHT, 0)
        pos = @buffer_positions[@active_tab] + ch - 1
        scroll_num.abs.times do
          add_line(tab_buffer[pos][0], tab_buffer[pos][1])
          addstr "\n"
          pos -= 1
        end
        noutrefresh
      end
      update_scrollbar
    elsif scroll_num > 0
      if tab_buffer_pos > 0
        scroll_num = tab_buffer_pos if (tab_buffer_pos - scroll_num) < 0
        @buffer_positions[@active_tab] -= scroll_num
        setpos(TAB_BAR_HEIGHT, 0)
        scrl(scroll_num)
        setpos(TAB_BAR_HEIGHT + ch - scroll_num, 0)
        pos = @buffer_positions[@active_tab] + scroll_num - 1
        (scroll_num - 1).times do
          add_line(tab_buffer[pos][0], tab_buffer[pos][1])
          addstr "\n"
          pos -= 1
        end
        add_line(tab_buffer[pos][0], tab_buffer[pos][1])
        noutrefresh
      end
    end
    update_scrollbar
  end

  # Redraw the active tab's content area and tab bar.
  #
  # @return [void]
  def redraw
    draw_tab_bar
    return unless @active_tab

    tab_buffer = @tabs[@active_tab]
    tab_buffer_pos = @buffer_positions[@active_tab]
    ch = content_height

    (TAB_BAR_HEIGHT...maxy).each do |y|
      setpos(y, 0)
      clrtoeol
    end

    return if tab_buffer.empty?

    visible_lines = [tab_buffer.length - tab_buffer_pos, ch].min
    return if visible_lines <= 0

    visible_lines.times do |i|
      buf_idx = tab_buffer_pos + (visible_lines - 1 - i)
      next if buf_idx >= tab_buffer.length || buf_idx < 0

      setpos(TAB_BAR_HEIGHT + i, 0)
      line_data = tab_buffer[buf_idx]
      add_line(line_data[0], line_data[1]) if line_data
    end

    update_scrollbar
    noutrefresh
  end

  # Refresh the scrollbar to reflect the active tab's buffer and scroll state.
  #
  # @return [void]
  def update_scrollbar
    return unless @active_tab

    render_scrollbar(@tabs[@active_tab].length, @buffer_positions[@active_tab], content_height)
  end

  # Clear (hide) the scrollbar.
  #
  # @return [void]
  def clear_scrollbar
    reset_scrollbar
  end

  # Return the active tab's buffer for selection support.
  #
  # @return [Array<Array(String, Array<Hash>)>] line buffer of the active tab
  def buffer_content
    @tabs[@active_tab] || []
  end

  # Extract selected text from the active tab's buffer.
  # Adjusts coordinates for the tab bar offset before indexing.
  #
  # @param start_y [Integer] starting row (window-relative)
  # @param start_x [Integer] starting column
  # @param end_y [Integer] ending row (window-relative)
  # @param end_x [Integer] ending column
  # @return [String] the selected text, lines joined by newlines
  def extract_selection(start_y, start_x, end_y, end_x)
    start_y -= TAB_BAR_HEIGHT
    end_y -= TAB_BAR_HEIGHT

    return '' if start_y < 0 && end_y < 0

    start_y = [start_y, 0].max
    end_y = [end_y, 0].max

    tab_buffer = @tabs[@active_tab] || []
    tab_buffer_pos = @buffer_positions[@active_tab] || 0
    ch = content_height

    if start_y > end_y || (start_y == end_y && start_x > end_x)
      start_y, end_y = end_y, start_y
      start_x, end_x = end_x, start_x
    end

    lines = []
    (start_y..end_y).each do |y|
      buffer_idx = tab_buffer_pos + (ch - 1 - y)
      next if buffer_idx >= tab_buffer.length || buffer_idx < 0

      line_text = tab_buffer[buffer_idx][0] || ''
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
end

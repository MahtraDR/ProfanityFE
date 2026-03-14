# frozen_string_literal: true

# Base class for all ProfanityFE window types.
# Provides shared rendering, word-wrap, scrollbar, selection, and window registry.

# Base class for all ProfanityFE windows.
#
# Provides shared rendering ({#add_line}, {#wrap_text}), scrollbar management
# ({#render_scrollbar}, {#reset_scrollbar}), polymorphic routing
# ({#route_string}, {#duplicate_prompt?}), selection support, and a window
# class registry used for hit-testing ({.find_window_at}).
class BaseWindow < Curses::Window
  # Bold vertical line character used for the scrollbar when the window is active.
  ACTIVE_SCROLLBAR_CHAR = "\u2503" # bold vertical line

  # Plain pipe character used for the scrollbar when the window is inactive.
  INACTIVE_SCROLLBAR_CHAR = '|'

  # Right-pointing triangle shown at the top of the scrollbar for the active window.
  ACTIVE_INDICATOR = "\u25B6" # right-pointing triangle

  # @return [Hash, nil] layout definition for this window
  attr_accessor :layout

  def initialize(*args)
    @layout = nil
    @active = false
    @scrollbar_pos = nil
    super(*args)
    self.class.register_instance(self)
  end

  # Render a single line with color regions via {HighlightProcessor}.
  #
  # @param line [String] the text to render
  # @param line_colors [Array<Hash>] color region descriptors
  # @param options [Hash] additional rendering options forwarded to the processor
  # @return [void]
  def add_line(line, line_colors = [], options = {})
    HighlightProcessor.render_colored_text(self, line, line_colors, options)
  end

  # All live instances of this window subclass.
  #
  # @return [Array<BaseWindow>]
  def self.list
    @list ||= []
  end

  # Register a window instance in this class's instance list.
  #
  # @param instance [BaseWindow] the window to register
  # @return [void]
  def self.register_instance(instance)
    list.push(instance)
  end

  # Remove a window instance from this class's instance list.
  #
  # @param instance [BaseWindow] the window to unregister
  # @return [void]
  def self.unregister_instance(instance)
    list.delete(instance)
  end

  # --- Word-wrap (DRY: shared by TextWindow, TabbedTextWindow, PercWindow) ---

  # Wrap a string to the given width, splitting color regions across lines.
  # Yields each [line, line_colors] pair to the caller for buffer insertion.
  #
  # @param string [String] the text to wrap (mutated in place)
  # @param width [Integer] maximum line width in characters
  # @param string_colors [Array<Hash>] color region descriptors for the full string
  # @param indent [Boolean] whether continuation lines should be indented
  # @yield [line, line_colors] each wrapped line and its adjusted color regions
  # @yieldparam line [String] one wrapped line of text
  # @yieldparam line_colors [Array<Hash>] color regions scoped to this line
  # @return [void]
  def wrap_text(string, width, string_colors, indent: true)
    while (line = string.slice!(/^.{2,#{width}}(?=\s|$)/)) || (line = string.slice!(0, width))
      line_colors = []
      string_colors.each do |h|
        line_colors.push(h.dup) if h[:start] < line.length
        h[:end] -= line.length
        h[:start] = [(h[:start] - line.length), 0].max
      end
      string_colors.delete_if { |h| h[:end] < 0 }
      line_colors.each { |h| h[:end] = [h[:end], line.length].min }

      yield line, line_colors

      break if string.chomp.empty?

      if indent
        if string[0, 1] == ' '
          string = " #{string}"
          string_colors.each do |h|
            h[:end] += 1
            h[:start] += h[:start] == 0 ? 2 : 1
          end
        else
          string = "  #{string}"
          string_colors.each do |h|
            h[:end] += 2
            h[:start] += 2
          end
        end
      elsif string[0, 1] == ' '
        string = string[1, string.length]
        string_colors.each do |h|
          h[:end] -= 1
          h[:start] -= 1
        end
      end
    end
  end

  # Format a timestamp string for the current time (HH:MM).
  #
  # @return [String] formatted timestamp like " [14:35]"
  # @api private
  def format_timestamp
    " [#{Time.now.hour.to_s.rjust(2, '0')}:#{Time.now.min.to_s.rjust(2, '0')}]"
  end

  # --- Scrollbar rendering (DRY: shared by TextWindow, TabbedTextWindow) ---

  # @return [Curses::Window, nil] companion 1-column curses window for the scrollbar
  attr_accessor :scrollbar

  # Set whether this window is the active (focused) window.
  # Updates the scrollbar appearance accordingly.
  #
  # @param is_active [Boolean] true to mark this window active
  # @return [void]
  def set_active(is_active)
    @active = is_active
    if @active
      update_scrollbar
    else
      clear_scrollbar
    end
  end

  # Whether this window is currently the active (focused) window.
  #
  # @return [Boolean]
  def active?
    @active
  end

  # Render the scrollbar for a buffer with the given metrics.
  # Subclasses call this with their buffer length, scroll position, and visible height.
  #
  # @param buffer_length [Integer] total number of lines in the buffer
  # @param buffer_pos [Integer] current scroll offset from the bottom
  # @param visible_height [Integer] number of visible rows in the content area
  # @return [void]
  def render_scrollbar(buffer_length, buffer_pos, visible_height)
    return unless @scrollbar

    scrollbar_char = @active ? ACTIVE_SCROLLBAR_CHAR : INACTIVE_SCROLLBAR_CHAR
    last_scrollbar_pos = @scrollbar_pos
    @scrollbar_pos = visible_height - ((buffer_pos / [(buffer_length - visible_height),
                                                      1].max.to_f) * (visible_height - 1)).round - 1

    if last_scrollbar_pos
      unless last_scrollbar_pos == @scrollbar_pos
        @scrollbar.setpos(last_scrollbar_pos, 0)
        @scrollbar.addstr scrollbar_char
        @scrollbar.setpos(@scrollbar_pos, 0)
        @scrollbar.attron(Curses::A_REVERSE) do
          @scrollbar.addch ' '
        end
        @scrollbar.noutrefresh
      end
    else
      (0...visible_height).each do |num|
        @scrollbar.setpos(num, 0)
        if num == @scrollbar_pos
          @scrollbar.attron(Curses::A_REVERSE) do
            @scrollbar.addch ' '
          end
        elsif num == 0 && @active
          @scrollbar.attron(Curses::A_BOLD) do
            @scrollbar.addstr ACTIVE_INDICATOR
          end
        else
          @scrollbar.addstr scrollbar_char
        end
      end
      @scrollbar.noutrefresh
    end
  end

  # Reset the scrollbar to its default (cleared) state.
  # Marks the window as inactive and erases the scrollbar column.
  #
  # @return [void]
  def reset_scrollbar
    @active = false
    @scrollbar_pos = nil
    return unless @scrollbar

    @scrollbar.clear
    @scrollbar.noutrefresh
  end

  # --- Polymorphic routing (DRY: eliminates is_a?(TabbedTextWindow) checks) ---

  # Route text to this window. Default: delegates to add_string.
  # TabbedTextWindow overrides to route to the appropriate tab.
  #
  # @param text [String] the text to display
  # @param colors [Array<Hash>] color region descriptors
  # @param _stream [String, nil] stream name (used by TabbedTextWindow override)
  # @return [void]
  def route_string(text, colors, _stream = nil)
    add_string(text, colors)
  end

  # Check if the most recent non-empty line matches the given prompt text.
  # Used to suppress duplicate bare prompts.
  #
  # @param prompt_text [String] the prompt string to check against
  # @return [Boolean] true if the last non-empty buffer line equals prompt_text
  def duplicate_prompt?(prompt_text)
    buf = respond_to?(:buffer) ? buffer : []
    return false if buf.empty?

    recent_line = buf.find { |entry| entry[0] && !entry[0].empty? }
    recent_line && recent_line[0] == prompt_text
  end

  # --- Phase 3 selection support ---

  # Buffer access for selection support - override in subclasses that have buffers.
  #
  # @return [Array] the buffer contents (empty by default)
  def buffer_content
    []
  end

  # Number of lines in the buffer.
  #
  # @return [Integer]
  def buffer_line_count
    buffer_content.length
  end

  # @return [Array<Integer>, nil] [y, x] coordinates where the selection begins
  attr_accessor :selection_start

  # @return [Array<Integer>, nil] [y, x] coordinates where the selection ends
  attr_accessor :selection_end

  # Whether text is currently selected in this window.
  #
  # @return [Boolean]
  def has_selection?
    !@selection_start.nil? && !@selection_end.nil?
  end

  # Clear the current text selection.
  #
  # @return [void]
  def clear_selection
    @selection_start = nil
    @selection_end = nil
  end

  # Set the selection range and trigger a highlight redraw if supported.
  #
  # @param start_y [Integer] starting row
  # @param start_x [Integer] starting column
  # @param end_y [Integer] ending row
  # @param end_x [Integer] ending column
  # @return [void]
  def highlight_selection(start_y, start_x, end_y, end_x)
    @selection_start = [start_y, start_x]
    @selection_end = [end_y, end_x]
    redraw_with_highlight if respond_to?(:redraw_with_highlight)
  end

  # Clear the selection highlight and redraw the window normally.
  #
  # @return [void]
  def clear_highlight
    @selection_start = nil
    @selection_end = nil
    redraw if respond_to?(:redraw)
  end

  # Extract selected text from the buffer.
  # Subclasses override this with buffer-aware implementations.
  #
  # @param _start_y [Integer] starting row
  # @param _start_x [Integer] starting column
  # @param _end_y [Integer] ending row
  # @param _end_x [Integer] ending column
  # @return [String] the selected text (empty string by default)
  def extract_selection(_start_y, _start_x, _end_y, _end_x)
    ''
  end

  # --- Window class registry ---

  # All registered window subclasses.
  #
  # @return [Array<Class>]
  def self.window_classes
    @window_classes ||= []
  end

  # Register a window subclass in the global registry.
  #
  # @param klass [Class] the subclass to register
  # @return [void]
  def self.register_window_class(klass)
    window_classes << klass unless window_classes.include?(klass)
  end

  # Hook called when a subclass is defined. Initializes the subclass instance
  # list and registers it in the window class registry.
  #
  # @param subclass [Class] the newly defined subclass
  # @return [void]
  def self.inherited(subclass)
    super
    subclass.instance_variable_set(:@list, [])
    register_window_class(subclass)
  end

  # Find the window instance whose screen bounds contain the given coordinates.
  #
  # @param screen_y [Integer] absolute screen row
  # @param screen_x [Integer] absolute screen column
  # @return [BaseWindow, nil] the window at those coordinates, or nil
  def self.find_window_at(screen_y, screen_x)
    window_classes.each do |klass|
      next unless klass.respond_to?(:list)

      klass.list.each do |window|
        next unless window.respond_to?(:begy) && window.respond_to?(:maxy)

        if screen_y >= window.begy && screen_y < (window.begy + window.maxy) &&
           screen_x >= window.begx && screen_x < (window.begx + window.maxx)
          return window
        end
      end
    end
    nil
  end
end

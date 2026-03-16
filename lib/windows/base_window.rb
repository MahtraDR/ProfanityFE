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

  # Create a new window and register it in the class instance list.
  #
  # @param args [Array] arguments forwarded to +Curses::Window.new+
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
    string = string.dup if string.frozen?
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

  # Whether a selection highlight is currently active on this window.
  #
  # @return [Boolean]
  def has_highlight?
    !@selection_start.nil? && !@selection_end.nil?
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

  # Find a clickable link command at the given window-relative coordinates.
  # Subclasses override this with buffer-aware implementations.
  #
  # @param _rel_y [Integer] row relative to window top
  # @param _rel_x [Integer] column relative to window left
  # @return [String, nil] the link command string, or nil if no link at that position
  def link_cmd_at(_rel_y, _rel_x)
    nil
  end

  # Draw a single line with reverse-video highlighting for the selected region.
  # Shared by TextWindow and TabbedTextWindow for selection rendering.
  #
  # @param y [Integer] the window row being drawn
  # @param line_text [String] full text of the line
  # @param line_colors [Array<Hash>] color regions for the line
  # @param start_y [Integer] selection start row
  # @param start_x [Integer] selection start column
  # @param end_y [Integer] selection end row
  # @param end_x [Integer] selection end column
  # @return [void]
  protected def draw_line_with_selection(y, line_text, line_colors, start_y, start_x, end_y, end_x)
    return if line_text.nil?

    sel_start = y == start_y ? start_x : 0
    sel_end = y == end_y ? end_x : line_text.length

    if sel_start > 0
      pre_text = line_text[0...sel_start]
      pre_colors = line_colors.map do |h|
        { start: h[:start], end: [h[:end], sel_start].min, fg: h[:fg], bg: h[:bg], ul: h[:ul] }
      end.select { |h| h[:end] > h[:start] }
      add_line(pre_text, pre_colors)
    end

    if sel_end > sel_start
      selected_text = line_text[sel_start...sel_end] || ''
      attron(Curses::A_REVERSE) { addstr selected_text }
    end

    return unless sel_end < line_text.length

    post_text = line_text[sel_end..-1]
    post_colors = line_colors.map do |h|
      new_start = [h[:start] - sel_end, 0].max
      new_end = h[:end] - sel_end
      { start: new_start, end: new_end, fg: h[:fg], bg: h[:bg], ul: h[:ul] }
    end.select { |h| h[:end] > 0 && h[:end] > h[:start] }
    add_line(post_text, post_colors)
  end

  # Render text at the current cursor position using indexed fg/bg color arrays.
  #
  # @param text [String] text to render
  # @param fg_code [String, nil] foreground hex color code
  # @param bg_code [String, nil] background hex color code
  # @return [void]
  protected def render_colored(text, fg_code, bg_code)
    attron(Curses.color_pair(get_color_pair_id(fg_code, bg_code)) | Curses::A_NORMAL) do
      addstr text
    end
  end

  # --- Window type registry (OCP: new types register themselves) ---

  # Registry mapping XML class names to window builder procs.
  # Each builder proc receives (height, width, top, left, element, window_manager)
  # and returns a configured window (or nil).
  #
  # @return [Hash<String, Proc>]
  def self.type_registry
    @type_registry ||= {}
  end

  # Register a window type by its XML class name.
  #
  # @param xml_class [String] the value of class='...' in layout XML
  # @yield [height, width, top, left, element, wm] builder block
  # @yieldparam height [Integer] computed window height
  # @yieldparam width [Integer] computed window width
  # @yieldparam top [Integer] computed top position
  # @yieldparam left [Integer] computed left position
  # @yieldparam element [REXML::Element] the XML element for this window
  # @yieldparam wm [WindowManager] the window manager instance
  # @return [void]
  def self.register_type(xml_class, &builder)
    type_registry[xml_class] = builder
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

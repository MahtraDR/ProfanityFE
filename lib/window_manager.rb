# frozen_string_literal: true

# Manages Curses window creation, layout loading, and handler hash access
# for the profanity terminal UI.

# Manages window creation, layout loading, and handler hash access.
#
# Owns the five handler hashes (stream, indicator, progress, countdown,
# room) that map string keys to their corresponding window objects, plus
# the command input window. Provides mutex-protected layout reloading so
# the server read thread can safely read handler hashes while a layout
# reload replaces them.
#
# @example
#   wm = WindowManager.new
#   wm.load_layout('default')
#   wm.stream['main'].add_string("Hello")
class WindowManager
  attr_reader :command_window, :command_window_layout

  # Previous-layout hashes exposed for builder procs during {#load_layout}.
  # These are only meaningful inside a layout reload; outside that context
  # they are empty hashes.
  #
  # @return [Hash] previous indicator windows keyed by value
  # @api private
  attr_reader :previous_indicator

  # @return [Hash] previous stream windows keyed by stream name
  # @api private
  attr_reader :previous_stream

  # @return [Hash] previous progress windows keyed by value
  # @api private
  attr_reader :previous_progress

  # @return [Hash] previous countdown windows keyed by value
  # @api private
  attr_reader :previous_countdown

  # Windows from the previous layout that have not been reused.
  # Builder procs delete reused windows from this set; remaining
  # windows are closed after the layout loop.
  #
  # @return [Array<BaseWindow>]
  # @api private
  attr_reader :old_windows

  # Create a new window manager with empty handler hashes.
  #
  # @return [WindowManager]
  def initialize
    @stream = {}
    @indicator = {}
    @progress = {}
    @countdown = {}
    @room = {}
    @command_window = nil
    @command_window_layout = nil
    @handler_mutex = Mutex.new
    @previous_indicator = {}
    @previous_stream = {}
    @previous_progress = {}
    @previous_countdown = {}
    @old_windows = []
  end

  # Returns the live stream handler hash mapping stream names to window objects.
  #
  # @return [Hash<String, TextWindow>] the stream handler hash (not a copy)
  # @note Returns the live hash, not a copy. Mutations affect routing.
  attr_reader :stream

  # Returns the live indicator handler hash.
  #
  # @return [Hash<String, IndicatorWindow>] the indicator handler hash (not a copy)
  # @note Returns the live hash, not a copy. Mutations affect indicator display.
  attr_reader :indicator

  # Returns the live progress handler hash.
  #
  # @return [Hash<String, ProgressWindow>] the progress handler hash (not a copy)
  # @note Returns the live hash, not a copy. Mutations affect progress display.
  attr_reader :progress

  # Returns the live countdown handler hash.
  #
  # @return [Hash<String, CountdownWindow>] the countdown handler hash (not a copy)
  # @note Returns the live hash, not a copy. Mutations affect countdown display.
  attr_reader :countdown

  # Returns the live room handler hash.
  #
  # @return [Hash<String, RoomWindow>] the room handler hash (not a copy)
  # @note Returns the live hash, not a copy. Mutations affect room display.
  attr_reader :room

  # Evaluate a layout dimension string to an integer, substituting
  # Curses terminal dimensions for the tokens "lines" and "cols".
  #
  # @param str [String] dimension expression (e.g. "lines-2", "cols/3")
  # @return [Integer] computed pixel/cell dimension value
  def fix_layout_number(str)
    str = str.gsub('lines', Curses.lines.to_s).gsub('cols', Curses.cols.to_s)
    safe_eval_arithmetic(str)
  end

  # Load a layout by ID from the LAYOUT constant and rebuild all windows.
  #
  # Synchronized with +@handler_mutex+ to prevent races with the server
  # read thread that constantly reads the handler hashes. Existing windows
  # whose keys appear in the new layout are reused (moved/resized) rather
  # than recreated, preserving their content buffers. Windows from the
  # previous layout that are not present in the new one are closed.
  #
  # @param layout_id [String] key into the global LAYOUT hash
  # @return [void]
  def load_layout(layout_id)
    xml = LAYOUT[layout_id]
    unless xml
      warn "Warning: layout '#{layout_id}' not found in LAYOUT (available: #{LAYOUT.keys.join(', ')})"
      return
    end

    @handler_mutex.synchronize do
      @old_windows = IndicatorWindow.list | TextWindow.list | CountdownWindow.list | ProgressWindow.list

      @previous_indicator = @indicator
      @indicator = {}

      @previous_stream = @stream
      @stream = {}

      @previous_progress = @progress
      @progress = {}

      @previous_countdown = @countdown
      @countdown = {}
      @room = {}

      xml.elements.each do |e|
        next unless e.name == 'window'

        if e.attributes['class'] == 'sink'
          sink = SinkWindow.new
          e.attributes['value']&.split(',')&.each do |str|
            @stream[str.strip] = sink
          end
          next
        end

        height = fix_layout_number(e.attributes['height'])
        width = fix_layout_number(e.attributes['width'])
        top = fix_layout_number(e.attributes['top'])
        left = fix_layout_number(e.attributes['left'])

        next unless (height > 0) && (width > 0) && (top >= 0) && (left >= 0) &&
                    (top < Curses.lines) && (left < Curses.cols)

        builder = BaseWindow.type_registry[e.attributes['class']]
        builder&.call(height, width, top, left, e, self)
      end

      if (current_scroll_window = SCROLL_WINDOW[0])
        current_scroll_window.set_active(true)
      end

      @old_windows.each do |window|
        IndicatorWindow.list.delete(window)
        TextWindow.list.delete(window)
        TabbedTextWindow.list.delete(window)
        CountdownWindow.list.delete(window)
        ProgressWindow.list.delete(window)
        SCROLL_WINDOW.delete(window)
        window.scrollbar.close if window.respond_to?(:scrollbar) && window.scrollbar
        window.close
      end

      CursesRenderer.doupdate
    end
  end

  # Resize all windows to match the current terminal dimensions.
  #
  # Iterates every managed window class (text, indicator, progress,
  # countdown, command) and recalculates positions and sizes from the
  # stored layout expressions. Triggers a full Curses screen update
  # afterward.
  #
  # @param cmd_buffer [CommandBuffer] the command-line input buffer, used to refresh the command window cursor position
  # @return [void]
  def resize(_cmd_buffer)
    window = Curses::Window.new(0, 0, 0, 0)
    window.refresh
    window.close

    first_text_window = true
    TextWindow.list.to_a.each do |win|
      win.resize(fix_layout_number(win.layout[0]), fix_layout_number(win.layout[1]) - 1)
      win.move(fix_layout_number(win.layout[2]), fix_layout_number(win.layout[3]))
      win.scrollbar.resize(win.maxy, 1)
      win.scrollbar.move(win.begy, win.begx + win.maxx)
      win.scroll(-win.maxy)
      win.scroll(win.maxy)
      win.clear_scrollbar
      if first_text_window
        win.update_scrollbar
        first_text_window = false
      end
      win.noutrefresh
    end

    TabbedTextWindow.list.to_a.each do |win|
      win.resize(fix_layout_number(win.layout[0]), fix_layout_number(win.layout[1]) - 1)
      win.move(fix_layout_number(win.layout[2]), fix_layout_number(win.layout[3]))
      if win.scrollbar
        win.scrollbar.resize(win.maxy, 1)
        win.scrollbar.move(win.begy, win.begx + win.maxx)
      end
      win.scroll(-win.maxy)
      win.scroll(win.maxy)
      win.clear_scrollbar
      win.redraw
      win.noutrefresh
    end

    [ExpWindow, PercWindow, RoomWindow].each do |klass|
      klass.list.to_a.each do |win|
        win.resize(fix_layout_number(win.layout[0]), fix_layout_number(win.layout[1]))
        win.move(fix_layout_number(win.layout[2]), fix_layout_number(win.layout[3]))
        win.redraw
        win.noutrefresh
      end
    end

    [IndicatorWindow.list.to_a, ProgressWindow.list.to_a, CountdownWindow.list.to_a].flatten.each do |win|
      win.resize(fix_layout_number(win.layout[0]), fix_layout_number(win.layout[1]))
      win.move(fix_layout_number(win.layout[2]), fix_layout_number(win.layout[3]))
      win.noutrefresh
    end

    if @command_window
      @command_window.resize(fix_layout_number(@command_window_layout[0]), fix_layout_number(@command_window_layout[1]))
      @command_window.move(fix_layout_number(@command_window_layout[2]), fix_layout_number(@command_window_layout[3]))
      @command_window.noutrefresh
    end

    CursesRenderer.doupdate
  end
end

# Register the command window type. This is a plain Curses::Window (not a
# BaseWindow subclass), so it lives here rather than in a window file.
BaseWindow.register_type('command') do |height, width, top, left, element, wm|
  wm.instance_variable_set(:@command_window, Curses::Window.new(height, width, top, left)) unless wm.command_window
  wm.instance_variable_set(:@command_window_layout, [
    element.attributes['height'], element.attributes['width'],
    element.attributes['top'], element.attributes['left']
  ])
  wm.command_window.scrollok(false)
  wm.command_window.keypad(true)
  wm.command_window
end

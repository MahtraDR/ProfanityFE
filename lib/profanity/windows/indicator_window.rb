# frozen_string_literal: true

# Status indicator display window (kneeling, hidden, bleeding, etc.).

# Single-label status indicator window.
#
# Displays a short label whose color changes based on a boolean or integer
# value. Supports optional highlight overlays via +label_colors+.
# Common uses: kneeling, hidden, stunned, bleeding status indicators.
class IndicatorWindow < BaseWindow
  # @return [Array<String>] foreground hex color codes indexed by value state
  attr_accessor :fg

  # @return [Array<String, nil>] background hex color codes indexed by value state
  attr_accessor :bg

  # @return [Array<Hash>, nil] optional highlight color regions for the label
  attr_accessor :label_colors

  # @return [String] the indicator label text
  attr_reader :label

  # @return [Boolean, Integer, nil] current indicator state
  attr_reader :value

  # Set the label text and trigger a redraw.
  #
  # @param str [String] new label text
  # @return [void]
  def label=(str)
    @label = str
    redraw
  end

  def initialize(*args)
    @fg = %w[444444 ffff00]
    @bg = [nil, nil]
    @label = '*'
    @label_colors = nil
    @value = nil
    super
  end

  # Update the indicator value and redraw if it changed.
  #
  # @param new_value [Boolean, Integer, nil] the new state value
  # @return [Boolean] true if the display was redrawn, false if unchanged
  def update(new_value)
    if new_value == @value
      false
    else
      @value = new_value
      redraw
    end
  end

  # Redraw the indicator label with the appropriate color for the current value.
  #
  # @return [Boolean] always true (the indicator was rendered)
  def redraw
    setpos(0, 0)
    clrtoeol

    # Use label_colors if set (for highlight support), otherwise use single-color mode
    if @label_colors&.any?
      # Determine base color based on value state
      base_fg = @value ? @fg[1] : @fg[0]
      base_bg = @value ? @bg[1] : @bg[0]

      # Create base color region spanning entire label, then overlay highlights
      # Highlights with smaller ranges take priority in render_colored_text
      base_color = { start: 0, end: @label.length, fg: base_fg, bg: base_bg }
      colors = [base_color] + @label_colors
      add_line(@label, colors)
    elsif @value
      # Original single-color behavior
      if @value.is_a?(Integer)
        attron(Curses.color_pair(get_color_pair_id(@fg[@value], @bg[@value])) | Curses::A_NORMAL) { addstr @label }
      else
        attron(Curses.color_pair(get_color_pair_id(@fg[1], @bg[1])) | Curses::A_NORMAL) { addstr @label }
      end
    else
      attron(Curses.color_pair(get_color_pair_id(@fg[0], @bg[0])) | Curses::A_NORMAL) { addstr @label }
    end
    noutrefresh
    true
  end
end

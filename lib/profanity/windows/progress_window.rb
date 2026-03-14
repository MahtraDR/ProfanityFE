# frozen_string_literal: true

# Health/mana/stamina progress bar display window.

# Progress bar window for health, mana, stamina, and similar gauges.
#
# Renders a single-row bar whose filled portion is proportional to
# +value / max_value+. Supports up to four color pairs (left fill,
# middle transition, right background, and zero-value) via the +fg+
# and +bg+ arrays.
class ProgressWindow < BaseWindow
  # @return [Array<String>] foreground hex color codes indexed by bar region
  attr_accessor :fg

  # @return [Array<String>] background hex color codes indexed by bar region
  attr_accessor :bg

  # @return [String] label text displayed at the left of the bar
  attr_accessor :label

  # @return [Integer] current value
  attr_reader :value

  # @return [Integer] maximum value (clamped to >= 1)
  attr_reader :max_value

  def initialize(*args)
    @label = String.new
    @fg = []
    @bg = %w[0000aa 000055]
    @value = 100
    @max_value = 100
    super
  end

  # Update the bar value and optionally the maximum.
  # Triggers a {#redraw} only when a value actually changes.
  #
  # @param new_value [Integer] the new current value
  # @param new_max_value [Integer, nil] the new maximum (kept unchanged when nil)
  # @return [Boolean] true if the display was redrawn, false if unchanged
  def update(new_value, new_max_value = nil)
    new_max_value ||= @max_value
    if (new_value == @value) and (new_max_value == @max_value)
      false
    else
      @value = new_value
      @max_value = [new_max_value, 1].max
      redraw
    end
  end

  # Redraw the progress bar using the current value, max, and color palette.
  #
  # @return [Boolean] always true (the bar was rendered)
  def redraw
    str = "#{@label}#{@value.to_s.rjust(maxx - @label.length)}"
    percent = [[(@value / @max_value.to_f), 0.to_f].max, 1].min
    if (@value == 0) and (fg[3] or bg[3])
      setpos(0, 0)
      attron(Curses.color_pair(get_color_pair_id(@fg[3], @bg[3])) | Curses::A_NORMAL) do
        addstr str
      end
    else
      left_str = str[0, (str.length * percent).floor].to_s
      if (@fg[1] or @bg[1]) and (left_str.length < str.length) and (((left_str.length + 0.5) * (1 / str.length.to_f)) < percent)
        middle_str = str[left_str.length, 1].to_s
      else
        middle_str = ''
      end
      right_str = str[(left_str.length + middle_str.length), (@label.length + (maxx - @label.length))].to_s
      setpos(0, 0)
      unless left_str.empty?
        attron(Curses.color_pair(get_color_pair_id(@fg[0], @bg[0])) | Curses::A_NORMAL) do
          addstr left_str
        end
      end
      unless middle_str.empty?
        attron(Curses.color_pair(get_color_pair_id(@fg[1], @bg[1])) | Curses::A_NORMAL) do
          addstr middle_str
        end
      end
      unless right_str.empty?
        attron(Curses.color_pair(get_color_pair_id(@fg[2], @bg[2])) | Curses::A_NORMAL) do
          addstr right_str
        end
      end
    end
    noutrefresh
    true
  end
end

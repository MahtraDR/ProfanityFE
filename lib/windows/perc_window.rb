# frozen_string_literal: true

# Active spells/effects display with duration-based sorting.

# Active spells and effects display window.
#
# Collects spell/effect lines via {#add_string}, then sorts them by
# remaining duration (highest first) on {#redraw}. Cyclic spells,
# percentage-based effects, and the "Fading" state each receive a
# fixed sort weight so the most important entries appear at the top.
class PercWindow < BaseWindow
  # Create a new active spells window.
  #
  # @param args [Array] arguments forwarded to {BaseWindow#initialize}
  def initialize(*args)
    @spells = {}
    @indent_word_wrap = true
    super
  end

  # Return the spells hash as buffer entries for selection support.
  #
  # @return [Array<Array(String, Array<Hash>)>] spell text/color pairs
  def buffer_content
    @spells.to_a
  end

  # Render a spell line with a trailing newline and immediate refresh.
  #
  # @param line [String] the spell/effect text
  # @param line_colors [Array<Hash>] color region descriptors
  # @return [void]
  def add_line(line, line_colors = [])
    super(line, line_colors, newline: true, refresh: true)
  end

  # Append a spell/effect line to the buffer and spells hash.
  # Word-wraps the text and stores the result for the next {#redraw}.
  #
  # @param string [String] the spell/effect text
  # @param string_colors [Array<Hash>] color region descriptors
  # @return [void]
  def add_string(string, string_colors = [], indent: nil)
    effective_indent = indent.nil? ? @indent_word_wrap : indent
    wrap_text(string, maxx - 1, string_colors, indent: effective_indent) do |line, line_colors|
      @spells.store(line, line_colors) unless line.chomp.empty?
    end
  end

  # Redraw all spells sorted by remaining duration (longest first).
  # Clears the spells hash after rendering so the next batch starts fresh.
  #
  # @return [void]
  def redraw
    erase
    setpos(0, 0)

    begin
      @spells.sort_by do |key, _val|
        # Parse duration from spell text like "Spell Name (5 roisaen)" or "Spell (Cyclic)"
        # Returns sort weight: higher = show first
        duration_part = key.to_s.split(/\s+(?=\()/)[1]
        if duration_part
          duration_part.gsub(/\(|\)/, '')
                       .sub(/\d+%/, '3000')
                       .sub(/Cyclic/, '1500')
                       .sub(/OM/, '2000')
                       .sub(/Fading/, '0')
                       .to_i
        else
          1000
        end
      end.reverse.each do |line, line_colors|
        add_line(line, line_colors)
      end
    rescue StandardError => e
      ProfanityLog.write('perc_window', "Error sorting spells: #{e}", backtrace: e.backtrace)
    end
    @spells = {}
    noutrefresh
  end

  # Clear the display and reset the spells hash.
  #
  # @return [void]
  def clear_spells
    erase
    setpos(0, 0)
    noutrefresh
    redraw
  end
end

BaseWindow.register_type('percWindow') do |height, width, top, left, element, wm|
  window = PercWindow.new(height, width - 1, top, left)
  window.layout = [element.attributes['height'], element.attributes['width'], element.attributes['top'], element.attributes['left']]
  wm.stream['percWindow'] = window
  window
end

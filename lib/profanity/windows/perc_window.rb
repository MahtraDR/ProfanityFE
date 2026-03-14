# frozen_string_literal: true

# Active spells/effects display with duration-based sorting.

# Active spells and effects display window.
#
# Collects spell/effect lines via {#add_string}, then sorts them by
# remaining duration (highest first) on {#redraw}. Cyclic spells,
# percentage-based effects, and the "Fading" state each receive a
# fixed sort weight so the most important entries appear at the top.
class PercWindow < BaseWindow
  def initialize(*args)
    @spells = {}
    @indent_word_wrap = true
    super
  end

  # Phase 3 selection support
  def buffer_content
    @spells.to_a
  end

  # Override to add newline after each spell line and refresh
  def add_line(line, line_colors = [])
    super(line, line_colors, newline: true, refresh: true)
  end

  # Append a spell/effect line to the buffer and spells hash.
  # Word-wraps the text and stores the result for the next {#redraw}.
  #
  # @param string [String] the spell/effect text
  # @param string_colors [Array<Hash>] color region descriptors
  # @return [void]
  def add_string(string, string_colors = [])
    wrap_text(string, maxx - 1, string_colors, indent: @indent_word_wrap) do |line, line_colors|
      @spells.store(line, line_colors) unless line.chomp.empty?
    end
  end

  # Redraw all spells sorted by remaining duration (longest first).
  # Clears the spells hash after rendering so the next batch starts fresh.
  #
  # @return [void]
  def redraw
    clear
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
      File.open(LOG_FILE, 'a') do |f|
        f.puts("Error sorting spells: #{e}")
        f.puts(e.backtrace[0...BACKTRACE_LIMIT])
      end
    end
    @spells = {}
    noutrefresh
  end

  # Clear the display and reset the spells hash.
  #
  # @return [void]
  def clear_spells
    clear
    setpos(0, 0)
    noutrefresh
    redraw
  end
end

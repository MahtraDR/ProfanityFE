# frozen_string_literal: true

# Dedicated room display with atomic updates and creature highlighting.

# Room information display window.
#
# Shows the current room title, description, objects (with creature
# highlighting), players, exits, room number, and string procs.
# Updates arrive incrementally via the +update_*+ methods and a full
# {#render} is triggered when exits arrive (the last component in the
# batch). Mirrors Genie4's room window behavior.
class RoomWindow < BaseWindow
  # @return [String, nil] preset name applied to the room title color
  attr_accessor :title_preset

  # @return [String, nil] preset name applied to the room description color
  attr_accessor :desc_preset

  # @return [String, nil] preset name applied to creature highlight color
  attr_accessor :creatures_preset

  def initialize(*args)
    @title = ''
    @description = ''
    @objects = ''
    @players = ''
    @exits = ''
    @room_number = ''
    @stringprocs = ''
    @extracted_creatures = [] # For highlighting
    super
  end

  # Update the room title text.
  #
  # @param text [String] the raw title text
  # @return [void]
  def update_title(text)
    @title = text.strip
  end

  # Update the room description text.
  #
  # @param text [String] the raw description text
  # @return [void]
  def update_desc(text)
    @description = text.strip
  end

  # Update the room objects text and extract creature names for highlighting.
  #
  # @param text [String] the raw objects text (may contain XML bold tags)
  # @return [void]
  def update_objects(text)
    @objects = text.strip
    extract_creatures(text)
  end

  # Update the room players text.
  #
  # @param text [String] the raw players text
  # @return [void]
  def update_players(text)
    @players = text.strip
  end

  # Update the room exits text and trigger a full render.
  # Exits are typically the last component in a room update batch.
  #
  # @param text [String] the raw exits text
  # @return [void]
  def update_exits(text)
    @exits = normalize_exits(text.strip)
    render # Trigger full redraw on exits (last component)
  end

  # Update the room number text and re-render.
  #
  # @param text [String] the raw room number text
  # @return [void]
  def update_room_number(text)
    @room_number = text.strip
    render # Re-render to include room number
  end

  # Update the string procs text and re-render.
  #
  # @param text [String] the raw string procs text
  # @return [void]
  def update_stringprocs(text)
    @stringprocs = text.strip
    render # Re-render to include stringprocs
  end

  # Clear supplemental fields (room number, stringprocs) between room changes
  # so stale data does not persist.
  #
  # @return [void]
  def clear_supplemental
    @room_number = ''
    @stringprocs = ''
  end

  # Render the complete room display.
  # Clears the window and draws each section (title, description, objects,
  # players, exits, room number, stringprocs) with appropriate presets and
  # highlight processing.
  #
  # @return [void]
  def render
    clear
    setpos(0, 0)

    # Room title with preset
    unless @title.empty?
      # Format: [Room Name] (Room ID) - brackets only around name, not ID
      # But apply preset color to entire line including room ID
      if (match = @title.match(/^(?<room_name>.+?)\s+\((?<room_id>\d+)\)$/))
        formatted_title = "[#{match[:room_name]}] (#{match[:room_id]})"
        render_section(formatted_title, @title_preset)
      else
        # Fallback for titles without room ID
        render_section("[#{@title}]", @title_preset)
      end
      addstr("\n")
    end

    # Room description
    unless @description.empty?
      render_section(@description, @desc_preset)
      addstr("\n")
    end

    # Objects (with creature highlighting)
    unless @objects.empty?
      render_objects_section(@objects)
      addstr("\n")
    end

    # Players
    unless @players.empty?
      render_section(@players, nil)
      addstr("\n")
    end

    # Exits
    unless @exits.empty?
      render_section(@exits, nil)
      addstr("\n")
    end

    # Room number
    unless @room_number.empty?
      render_section(@room_number, nil)
      addstr("\n")
    end

    # StringProcs
    render_section(@stringprocs, nil) unless @stringprocs.empty?

    noutrefresh
  end

  private

  # Extract creature names from bold-tagged XML in the objects text.
  #
  # @param text [String] raw objects text with XML bold tags
  # @return [void]
  # @api private
  def extract_creatures(text)
    # Extract bold-wrapped text: <pushBold/>creature<popBold/>
    @extracted_creatures = text.scan(%r{<pushBold\s*/?>([^<]*)<popBold\s*/?>}).flatten
    # Update global for potential use elsewhere
    ROOM_OBJECTS.replace(@extracted_creatures)
  end

  # Append " none." to exits text that ends with a bare colon.
  #
  # @param text [String] the exits text to normalize
  # @return [String] normalized exits text
  # @api private
  def normalize_exits(text)
    return text unless text.end_with?(':')

    "#{text} none."
  end

  # Render a text section with an optional preset color and highlight processing.
  #
  # @param text [String] the section text
  # @param preset_name [String, nil] preset color key from the PRESET hash
  # @return [void]
  # @api private
  def render_section(text, preset_name)
    line_colors = []

    if preset_name && PRESET[preset_name]
      line_colors.push({
        start: 0,
        end: text.length,
        fg: PRESET[preset_name][0],
        bg: PRESET[preset_name][1]
      })
    end

    HighlightProcessor.apply_highlights(text, line_colors)
    add_line_wrapped(text, line_colors)
  end

  # Render the objects section with creature bold highlighting.
  # Strips XML tags and applies the creatures preset to each creature name.
  #
  # @param text [String] raw objects text with XML bold tags
  # @return [void]
  # @api private
  def render_objects_section(text)
    # Strip XML tags for display
    clean_text = text.gsub(%r{</?(?:pushBold|popBold)\s*/?>}, '')

    line_colors = []
    # Highlight creatures with monsterbold preset
    preset_name = @creatures_preset || 'monsterbold'
    if PRESET[preset_name]
      @extracted_creatures.each do |creature|
        pos = 0
        while (idx = clean_text.index(creature, pos))
          line_colors.push({
            start: idx,
            end: idx + creature.length,
            fg: PRESET[preset_name][0],
            bg: PRESET[preset_name][1]
          })
          pos = idx + creature.length
        end
      end
    end

    HighlightProcessor.apply_highlights(clean_text, line_colors)
    add_line_wrapped(clean_text, line_colors)
  end

  # Word-wrap and render text across multiple lines, splitting color regions.
  #
  # @param text [String] the text to wrap and render
  # @param line_colors [Array<Hash>] color regions spanning the full text
  # @return [void]
  # @api private
  def add_line_wrapped(text, line_colors)
    width = maxx
    pos = 0

    while pos < text.length
      # Calculate line length (word wrap at width)
      remaining = text[pos..]
      if remaining.length <= width
        line = remaining
      else
        # Try to break at word boundary
        line = remaining[0, width]
        if (break_pos = line.rindex(/\s/))
          line = remaining[0, break_pos + 1]
        end
      end

      # Build colors for this line segment
      current_colors = []
      line_colors.each do |c|
        # Check if this color region overlaps with current line segment
        region_start = c[:start] - pos
        region_end = c[:end] - pos

        next unless region_end > 0 && region_start < line.length

        current_colors.push({
          start: [region_start, 0].max,
          end: [region_end, line.length].min,
          fg: c[:fg],
          bg: c[:bg],
          ul: c[:ul]
        })
      end

      add_line(line.rstrip, current_colors)
      pos += line.length

      # Add newline if more content follows
      addstr("\n") if pos < text.length
    end
  end
end

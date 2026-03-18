# frozen_string_literal: true

=begin
Room data capture and assembly for RoomWindow.
Extracts room title, description, objects, players, exits, and room number
from game server XML component streams and inline text patterns.
=end

# Handles room data capture from game server component streams and inline text.
#
# Assembles room information (title, description, objects, players, exits)
# from multiple XML component lines and inline text patterns, updating the
# RoomWindow atomically when all components have arrived.
#
# UI updates are emitted via @event_bus rather than calling window methods
# directly. The @wm.room['room'] reference is retained only as a read-only
# check for whether a RoomWindow is configured in the current layout.
#
# Expects the including class to provide:
# - @wm           [WindowManager]
# - @event_bus    [EventBus]
# - @room_capture_mode, @room_pending_title, @room_pending_title_colors,
#   @room_pending_desc, @room_pending_desc_colors, @room_pending_objects,
#   @room_pending_objects_colors, @room_pending_players, @room_pending_exits,
#   @room_pending_number, @current_raw_line, @current_stream
# - @line_colors   [Array<Hash>]
# - @need_update   [Boolean]
#
# @api private
module RoomDataProcessor
  # Process room-related text from inline game text and update RoomWindow
  # data if applicable.
  #
  # Handles title and description via capture mode, "You also see" objects,
  # "Also here:" players, "Obvious paths/exits:" exits, room number, and
  # StringProcs.  When exits arrive (typically the last component), all
  # pending room data is committed to the RoomWindow atomically.
  #
  # @param text [String] the current line of game text (XML-unescaped)
  # @param line_colors [Array<Hash>] color regions for this line
  # @return [Boolean] true if this line was consumed by the RoomWindow
  #   (caller should not route it to the main window).  Returns false
  #   when title/desc text is captured for the terminal title but the
  #   template has no RoomWindow — the text must still flow to the
  #   main text window for display.
  # @api private
  def process_room_data(text, line_colors)
    return false if text.empty?

    room_data_captured = false

    # Handle room capture mode (roomName/roomDesc styled text).
    # Always update the terminal title from the roomName text since it
    # includes the room number in DR (e.g., "[Room] (230008)").
    # For templates without a RoomWindow, store the title for the
    # terminal but do NOT consume the text — it must still flow to
    # the main text window.
    case @room_capture_mode
    when :title
      room_title = parse_room_subtitle(text)
      @state.room_title = room_title unless room_title.empty?
      if @wm.room['room']
        @room_pending_title = text.sub(/^\[/, '').sub(/\]\s*\(/, ' (').strip
        @room_pending_title_colors = line_colors.dup
        room_data_captured = true
      end
      @room_capture_mode = nil
    when :desc
      if @wm.room['room']
        # Don't overwrite if already set by component stream (preserves raw XML for links)
        @room_pending_desc = text.strip unless @room_pending_desc
        @room_pending_desc_colors = line_colors.dup
        room_data_captured = true
      end
      @room_capture_mode = nil
    end

    # Without a RoomWindow, remaining room-data patterns (objects, players,
    # exits) are not applicable — return early with whatever was captured.
    return room_data_captured unless @wm.room['room']

    # Detect "You also see" for objects (may have leading whitespace)
    if text =~ /^\s*You also see\b/
      # Extract from raw line to preserve <pushBold/> tags for RoomWindow creature highlighting.
      # Use regex here (not REXML) since inline text isn't inside a component element.
      @room_pending_objects = if @current_raw_line && (match = @current_raw_line.match(/You also see\b.*/))
                                match[0].gsub(%r{</?(?:component|compDef)[^>]*>}, '').strip
                              else
                                text.strip
                              end
      @room_pending_objects_colors = line_colors.dup
      room_data_captured = true
    end

    # Detect "Also here:" for players
    if text =~ /^Also here:\s*(.+)$/
      # Don't overwrite if already set by component stream (preserves raw XML for links)
      @room_pending_players = text.strip unless @room_pending_players
      room_data_captured = true
    end

    # Detect "Obvious paths:", "Obvious exits:", or "Room Exits:" for exits
    if text =~ /^(?:Obvious (?:paths|exits)|Room Exits):/
      # Use raw line to preserve <d>/<a> tags for link processing in room window
      @room_pending_exits = if @current_raw_line && (match = @current_raw_line.match(/(?:Obvious (?:paths|exits)|Room Exits):.*/))
                               match[0].strip
                             else
                               text.strip
                             end
      room_data_captured = true
      # Trigger room render since exits are typically last
      commit_room_data_batch
    end

    # Detect "Room Number:" or "StringProcs:" lines (come after exits)
    if text =~ /^Room Number:\s*\d+/
      @event_bus.emit(:room_number, text: text.strip)
      room_data_captured = true
      @need_update = true
    elsif text =~ /^StringProcs:/
      @event_bus.emit(:room_stringprocs, text: text.strip)
      room_data_captured = true
      @need_update = true
    end

    room_data_captured
  end

  # Process room-related data arriving via XML component streams.
  #
  # Dispatches text from room component streams (room title, room desc,
  # room objs, room players, room exits) to the appropriate pending slot.
  # When exits arrive, commits all pending data to the RoomWindow.
  #
  # @param text [String] component text content
  # @return [Symbol, nil] :consumed if text was fully handled (caller should
  #   return), :continue if caller should keep processing (room players
  #   also needs indicator handling), or nil if not a room stream
  # @api private
  def process_room_stream(text)
    return nil unless @current_stream =~ /^room(\s|$)/ && @wm.room['room']

    case @current_stream
    when 'room', 'room title'
      raw = extract_component_content(@current_raw_line, @current_stream) if @current_raw_line
      @room_pending_title = strip_xml_tags(raw || text).strip
      @event_bus.emit(:room_title, text: @room_pending_title)
    when 'room desc', 'roomDesc'
      # Preserve raw XML for link processing in room window
      raw = extract_component_content(@current_raw_line, @current_stream) if @current_raw_line
      @room_pending_desc = (raw || text).strip
      @event_bus.emit(:room_desc, text: @room_pending_desc)
    when 'room objs'
      # Preserve raw XML — render_objects_section strips <pushBold/>, <a>, <d> etc.
      raw = extract_component_content(@current_raw_line, 'room objs') if @current_raw_line
      @room_pending_objects = (raw || text).strip
      @event_bus.emit(:room_objects, text: @room_pending_objects)
    when 'room players'
      # Preserve raw XML for link processing in room window (GS has <a> tags around names)
      raw = extract_component_content(@current_raw_line, 'room players') if @current_raw_line
      @room_pending_players = (raw || text).strip
      @event_bus.emit(:room_players, text: @room_pending_players)
      # Also update the indicator if present (fall through below)
    when 'room exits'
      # Preserve raw XML — render_exits_section strips <d>, <a>, <compass> etc.
      raw = extract_component_content(@current_raw_line, 'room exits') if @current_raw_line
      @room_pending_exits = (raw || text).strip
      @event_bus.emit(:room_exits, text: @room_pending_exits)
      # Clear pending data
      @room_pending_title = nil
      @room_pending_title_colors = nil
      @room_pending_desc = nil
      @room_pending_desc_colors = nil
      @room_pending_objects = nil
      @room_pending_objects_colors = nil
      @room_pending_players = nil
      @room_pending_exits = nil
    end

    # Defer room window render to the IO.select flush point to reduce
    # curses operation frequency (update_exits already renders internally)
    @need_room_render = true unless @current_stream == 'room exits'

    @need_update = true
    # Don't skip for room players - let the indicator handler also process it
    @current_stream == 'room players' ? :continue : :consumed
  end

  private

  # Extract the inner XML content of a named component/compDef element from
  # a raw server line using REXML.  Returns the inner markup as a string
  # (preserving child tags like <pushBold/>) or nil if the element isn't found.
  #
  # @param raw_line [String] the full raw server line (may contain multiple XML elements)
  # @param component_id [String] the id attribute to match (e.g., 'room objs')
  # @return [String, nil] inner XML of the matched element, or nil
  def extract_component_content(raw_line, component_id)
    doc = REXML::Document.new("<root>#{raw_line}</root>")
    element = doc.root.elements["component[@id='#{component_id}']"] ||
              doc.root.elements["compDef[@id='#{component_id}']"]
    return nil unless element

    element.children.map(&:to_s).join
  rescue REXML::ParseException
    nil
  end

  # Strip all XML tags from text, keeping only the text content.
  #
  # @param text [String] text potentially containing XML tags
  # @return [String] text with all XML tags removed
  def strip_xml_tags(text)
    text.gsub(%r{<[^>]+>}, '')
  end

  # Commit all pending room data to the RoomWindow and clear the staging area.
  #
  # Called when exits arrive (the last expected room component). Only commits
  # if there is actual pending data to avoid double-updates that would clear
  # previously committed data.
  #
  # @return [void]
  def commit_room_data_batch
    return unless @wm.room['room']

    # Only update if we have pending data (avoid double-updates clearing data)
    if @room_pending_title || @room_pending_desc || @room_pending_objects || @room_pending_players
      @event_bus.emit(:room_title, text: @room_pending_title || '')
      @event_bus.emit(:room_desc, text: @room_pending_desc || '')
      @event_bus.emit(:room_objects, text: @room_pending_objects || '')
      @event_bus.emit(:room_players, text: @room_pending_players || '')
      @event_bus.emit(:room_supplemental_clear)

      # Also update the room players indicator (fallback for games that don't use streams)
      update_room_players_indicator(@room_pending_players)

      # Clear pending data
      @room_pending_title = nil
      @room_pending_title_colors = nil
      @room_pending_desc = nil
      @room_pending_desc_colors = nil
      @room_pending_objects = nil
      @room_pending_objects_colors = nil
      @room_pending_players = nil
      @room_pending_number = nil
    end

    # Always update exits (even on subsequent exit lines)
    @event_bus.emit(:room_exits, text: @room_pending_exits || '')
    @room_pending_exits = nil
    @need_update = true
  end

  # Update the 'room players' indicator window with parsed player names.
  #
  # @param players_text [String, nil] raw "Also here:" text or nil
  # @return [void]
  def update_room_players_indicator(players_text)
    if players_text
      names = parse_player_names(players_text)
      if names.any?
        names_text = names.join(', ')
        label_colors = HighlightProcessor.apply_highlights(names_text, [])
        @event_bus.emit(:indicator_update, id: 'room players', label: names_text, label_colors: label_colors, value: true)
      else
        @event_bus.emit(:indicator_update, id: 'room players', label: ' ', label_colors: nil, value: false)
      end
    else
      # No players in room - clear the indicator
      @event_bus.emit(:indicator_update, id: 'room players', label: ' ', label_colors: nil, value: false)
    end
  end
end

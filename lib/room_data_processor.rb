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
# Expects the including class to provide:
# - @wm           [WindowManager]
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
  # @return [Boolean] true if this line was consumed as room data (caller
  #   should not route it to the main window)
  # @api private
  def process_room_data(text, line_colors)
    return false unless @wm.room['room'] && !text.empty?

    room_data_captured = false

    case @room_capture_mode
    when :title
      # Capture room title (RoomWindow will add brackets during render)
      # Format input: [Room Name] (Room ID) -> output: Room Name] (Room ID)
      # Remove leading [ and trailing ] before room ID
      @room_pending_title = text.sub(/^\[/, '').sub(/\]\s*\(/, ' (').strip
      @room_pending_title_colors = line_colors.dup
      @room_capture_mode = nil
      room_data_captured = true
    when :desc
      @room_pending_desc = text.strip
      @room_pending_desc_colors = line_colors.dup
      @room_capture_mode = nil
      room_data_captured = true
    end

    # Detect "You also see" for objects (may have leading whitespace)
    if text =~ /^\s*You also see\b/
      # Extract from raw line to preserve <pushBold/> tags for RoomWindow creature highlighting
      # Strip </component> tag which may be at end of raw line
      @room_pending_objects = if @current_raw_line && (match = @current_raw_line.match(/You also see\b.*/))
                                match[0].gsub(%r{</component>}, '').strip
                              else
                                text.strip
                              end
      @room_pending_objects_colors = line_colors.dup
      room_data_captured = true
    end

    # Detect "Also here:" for players
    if text =~ /^Also here:\s*(.+)$/
      @room_pending_players = text.strip
      room_data_captured = true
    end

    # Detect "Obvious paths:", "Obvious exits:", or "Room Exits:" for exits
    if text =~ /^(?:Obvious (?:paths|exits)|Room Exits):/
      # Strip <d> tags from exits
      @room_pending_exits = text.gsub(%r{</?d>}, '').strip
      room_data_captured = true
      # Trigger room render since exits are typically last
      commit_room_data_batch
    end

    # Detect "Room Number:" or "StringProcs:" lines (come after exits)
    if text =~ /^Room Number:\s*\d+/
      @wm.room['room'].update_room_number(text.strip)
      room_data_captured = true
      @need_update = true
    elsif text =~ /^StringProcs:/
      @wm.room['room'].update_stringprocs(text.strip)
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

    window = @wm.room['room']

    case @current_stream
    when 'room', 'room title'
      @room_pending_title = text.strip
    when 'room desc', 'roomDesc'
      @room_pending_desc = text.strip
    when 'room objs'
      # Store pending instead of updating directly to avoid duplicates
      # Use raw line to preserve <pushBold/> tags for creature highlighting
      # Strip </component> tag which may be at end of raw line
      @room_pending_objects = if @current_raw_line && !@current_raw_line.empty?
                                @current_raw_line.gsub(%r{</component>}, '').strip
                              else
                                text.strip
                              end
    when 'room players'
      @room_pending_players = text.strip
      # Also update the indicator if present (fall through below)
    when 'room exits'
      # Trigger batch update since exits are last
      @room_pending_exits = text.gsub(%r{</?d>}, '').strip
      window.update_title(@room_pending_title || '')
      window.update_desc(@room_pending_desc || '')
      window.update_objects(@room_pending_objects || '')
      window.update_players(@room_pending_players || '')
      window.update_exits(@room_pending_exits || '')
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

    @need_update = true
    # Don't skip for room players - let the indicator handler also process it
    @current_stream == 'room players' ? :continue : :consumed
  end

  private

  # Commit all pending room data to the RoomWindow and clear the staging area.
  #
  # Called when exits arrive (the last expected room component). Only commits
  # if there is actual pending data to avoid double-updates that would clear
  # previously committed data.
  #
  # @return [void]
  def commit_room_data_batch
    room_window = @wm.room['room']
    return unless room_window

    # Only update if we have pending data (avoid double-updates clearing data)
    if @room_pending_title || @room_pending_desc || @room_pending_objects || @room_pending_players
      room_window.update_title(@room_pending_title || '')
      room_window.update_desc(@room_pending_desc || '')
      room_window.update_objects(@room_pending_objects || '')
      room_window.update_players(@room_pending_players || '')
      room_window.clear_supplemental

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
    room_window.update_exits(@room_pending_exits || '')
    @room_pending_exits = nil
    @need_update = true
  end

  # Update the 'room players' indicator window with parsed player names.
  #
  # @param players_text [String, nil] raw "Also here:" text or nil
  # @return [void]
  def update_room_players_indicator(players_text)
    window = @wm.indicator['room players']
    return unless window

    if players_text
      names = parse_player_names(players_text)
      if names.any?
        names_text = names.join(', ')
        window.label_colors = HighlightProcessor.apply_highlights(names_text, [])
        window.label = names_text
        window.update(true)
      else
        window.label_colors = nil
        window.label = ' '
        window.update(false)
      end
    else
      # No players in room - clear the indicator
      window.label_colors = nil
      window.label = ' '
      window.update(false)
    end
  end
end

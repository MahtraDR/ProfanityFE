#!/usr/bin/env ruby
# frozen_string_literal: true
# encoding: US-ASCII

# vim: set sts=2 noet ts=2:
#
#   ProfanityFE v0.4
#   Copyright (C) 2013  Matthew Lowe
#
#   This program is free software; you can redistribute it and/or modify
#   it under the terms of the GNU General Public License as published by
#   the Free Software Foundation; either version 2 of the License, or
#   (at your option) any later version.
#
#   This program is distributed in the hope that it will be useful,
#   but WITHOUT ANY WARRANTY; without even the implied warranty of
#   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#   GNU General Public License for more details.
#
#   You should have received a copy of the GNU General Public License along
#   with this program; if not, write to the Free Software Foundation, Inc.,
#   51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
#
#   matt@lichproject.org
#

require 'socket'
require 'rexml/document'

# Load version and initialize curses
require_relative 'lib/version'
require_relative 'lib/curses_setup'

# Load global constants (HIGHLIGHT, PRESET, LAYOUT, etc.)
require_relative 'lib/constants'

# Centralized highlight processing (must be loaded before windows)
require_relative 'lib/highlight_processor'

# Window classes loaded from lib/windows/
require_relative 'lib/windows/base_window'
require_relative 'lib/windows/skill'
require_relative 'lib/windows/exp_window'
require_relative 'lib/windows/perc_window'
require_relative 'lib/windows/text_window'
require_relative 'lib/windows/tabbed_text_window'
require_relative 'lib/windows/progress_window'
require_relative 'lib/windows/countdown_window'
require_relative 'lib/windows/indicator_window'
require_relative 'lib/windows/sink_window'
require_relative 'lib/windows/room_window'
require_relative 'lib/key_codes'
require_relative 'lib/color_manager'
require_relative 'lib/selection_manager'
require_relative 'lib/gag_patterns'

# Extracted modules (SRP decomposition)
require_relative 'lib/shared_state'
require_relative 'lib/kill_ring'
require_relative 'lib/string_classification'
require_relative 'lib/profanity_log'
require_relative 'lib/command_buffer'
require_relative 'lib/window_manager'
require_relative 'lib/settings_loader'
require_relative 'lib/games/dragonrealms'
require_relative 'lib/games/gemstone'
require_relative 'lib/room_data_processor'
require_relative 'lib/familiar_notifier'
require_relative 'lib/game_text_processor'
require_relative 'lib/profanity_settings'
require_relative 'lib/autocomplete'
require_relative 'lib/mouse_scroll'

# Initialize gag patterns with defaults (can be extended via XML config)
GagPatterns.load_defaults

# Ensure terminal is restored on any exit path (graceful shutdown)
at_exit do
  Curses.close_screen
rescue StandardError
  nil
end

# Parse fg/bg color attributes from an XML layout element.
# Splits a comma-separated attribute value into an array, converting
# the string 'nil' to actual nil.
#
# @param element [REXML::Element] XML element containing the attribute
# @param attr_name [String] attribute name to parse (e.g. 'fg', 'bg')
# @return [Array<String, nil>, nil] parsed color values, or nil if attribute absent
def parse_color_attrs(element, attr_name)
  return unless element.attributes[attr_name]

  element.attributes[attr_name].split(',').collect do |val|
    val == 'nil' ? nil : val
  end
end

# Extract player names from "Also here: ..." room text.
# Strips status descriptions, titles, and grouping to return bare names.
#
# @param text [String] raw "Also here: ..." line from the game
# @return [Array<String>] list of player names
def parse_player_names(text)
  text.sub(/^Also here:\s*/, '')
      .sub(/ and (?<rest>.*)$/) { ", #{Regexp.last_match[:rest]}" }
      .split(', ')
      .map { |obj| obj.sub(/ (who|whose body)? ?(has|is|appears|glows) .+/, '').sub(/ \(.+\)/, '') }
      .map { |obj| obj.strip.scan(/\w+$/).first }
      .compact
end

# Display prompt in window, with optional command text.
# Uses polymorphic duplicate_prompt? and route_string to avoid type-checking.
def add_prompt(window, prompt_text, cmd = '')
  return if cmd.empty? && window.respond_to?(:duplicate_prompt?) && window.duplicate_prompt?(prompt_text)

  prompt_colors = [{ start: 0, end: (prompt_text.length + cmd.length), fg: '555555' }]
  window.route_string("#{prompt_text}#{cmd}", prompt_colors, MAIN_STREAM)
end

# Safe arithmetic expression evaluator for layout dimensions
# Only allows: integers, +, -, *, /, (), and whitespace
def safe_eval_arithmetic(expr)
  normalized = expr.gsub(/\s+/, '')
  unless normalized.match?(%r{\A[\d+\-*/()]+\z})
    warn "Invalid layout expression (unsafe characters): #{expr}"
    return 0
  end
  if normalized.include?('**')
    warn "Invalid layout expression (exponentiation not allowed): #{expr}"
    return 0
  end
  depth = 0
  normalized.each_char do |c|
    depth += 1 if c == '('
    depth -= 1 if c == ')'
    if depth < 0
      warn "Invalid layout expression (unbalanced parens): #{expr}"
      return 0
    end
  end
  if depth != 0
    warn "Invalid layout expression (unbalanced parens): #{expr}"
    return 0
  end
  eval(expr).to_i
rescue SyntaxError, ZeroDivisionError => e
  warn "Layout expression error: #{e.message} in '#{expr}'"
  0
end

# ========== CLI CONFIGURATION ==========

cli_port = 8000
cli_default_color_id = 7
cli_default_background_color_id = 0
cli_use_default_colors = false
cli_custom_colors = nil
cli_settings_file = nil
cli_log_dir = nil
cli_log_file = nil
cli_char = nil
cli_config = nil
cli_template = nil
cli_no_status = false
cli_links = false
cli_speech_ts = false
cli_remote_url = nil

ARGV.each do |arg|
  if arg =~ /^--help|^-h|^-\?/
    puts ''
    puts "Profanity FrontEnd v#{VERSION}"
    puts ''
    puts '   --char=<name>                       Character name (for log file & process title)'
    puts '   --config=<name>                     Config name to load (default: same as --char)'
    puts '   --template=<file>                   Template file name (from templates/)'
    puts '   --port=<port>                       Game server port (default: 8000)'
    puts '   --default-color-id=<id>             Default foreground color (default: 7)'
    puts '   --default-background-color-id=<id>  Default background color (default: 0)'
    puts '   --custom-colors=<on|off>            Force custom color mode'
    puts '   --use-default-colors                Use terminal default colors'
    puts '   --no-status                         Disable process title updates'
    puts '   --links                             Enable in-game link highlighting'
    puts '   --speech-ts                         Add timestamps to speech, familiar, and thought windows'
    puts '   --remote-url=<url>                  Remote game server URL'
    puts '   --log-file=<path>                   Log file path (default: profanity.log)'
    puts '   --log-dir=<dir>                     Log directory (default: current directory)'
    puts ''
    exit
  elsif (match = arg.match(/^--char=(?<name>.+)$/))
    cli_char = match[:name]
  elsif (match = arg.match(/^--config=(?<name>.+)$/))
    cli_config = match[:name]
  elsif (match = arg.match(/^--template=(?<file>.+)$/))
    cli_template = match[:file]
  elsif (match = arg.match(/^--port=(?<port>[0-9]+)$/))
    cli_port = match[:port].to_i
  elsif (match = arg.match(/^--default-color-id=(?<id>-?[0-9]+)$/))
    cli_default_color_id = match[:id].to_i
  elsif (match = arg.match(/^--default-background-color-id=(?<id>-?[0-9]+)$/))
    cli_default_background_color_id = match[:id].to_i
  elsif arg =~ /^--use-default-colors$/
    cli_use_default_colors = true
  elsif (match = arg.match(/^--custom-colors=(?<value>on|off|yes|no)$/))
    fix_setting = { 'on' => true, 'yes' => true, 'off' => false, 'no' => false }
    cli_custom_colors = fix_setting[match[:value]]
  elsif (match = arg.match(/^--settings-file=(?<file>.*?)$/))
    cli_settings_file = match[:file]
  elsif arg =~ /^--no-status$/
    cli_no_status = true
  elsif arg =~ /^--links$/
    cli_links = true
  elsif arg =~ /^--speech-ts$/
    cli_speech_ts = true
  elsif (match = arg.match(/^--remote-url=(?<url>.+)$/))
    cli_remote_url = match[:url]
  elsif (match = arg.match(/^--log-file=(?<file>.+)$/))
    cli_log_file = match[:file]
  elsif (match = arg.match(/^--log-dir=(?<dir>.+)$/))
    cli_log_dir = match[:dir]
  end
end

PORT = cli_port
CHAR_NAME = cli_char

# Resolve settings file via ProfanitySettings (EO-compatible search order)
# --config overrides which XML to load; defaults to --char if not specified
SETTINGS_FILENAME = ProfanitySettings.resolve_template(
  char: cli_config || cli_char,
  template: cli_template,
  settings_file: cli_settings_file,
  app_dir: File.dirname(__FILE__)
)

# Resolve log file path via ProfanitySettings
LOG_FILE = ProfanitySettings.resolve_log(
  char: cli_char,
  log_file: cli_log_file,
  log_dir: cli_log_dir
)

DEFAULT_COLOR_ID = cli_default_color_id
DEFAULT_BACKGROUND_COLOR_ID = cli_default_background_color_id
Curses.use_default_colors if cli_use_default_colors
CUSTOM_COLORS = cli_custom_colors.nil? ? Curses.can_change_color? : cli_custom_colors

# Update the terminal title and process name with character info.
# Shows "CharName [prompt:room]" in terminal tabs and process listings.
#
# @param char_name [String] the character name
# @param prompt_text [String] current game prompt text
# @param room_text [String] current room name (optional)
# @return [void]
def update_process_title(char_name, prompt_text, room_text = '')
  return if CHAR_NAME.nil? || NO_STATUS
  parts = [prompt_text, room_text].reject(&:empty?).join(':')
  title = parts.empty? ? char_name : "#{char_name} [#{parts}]"
  Process.setproctitle(title)
  # Terminal title (xterm/iTerm/etc.)
  $stdout.print "\033]0;#{title}\007"
  # Screen/tmux window name
  $stdout.print "\ek#{title}\e\\"
  $stdout.flush
rescue StandardError
  # ignore title update failures
end

NO_STATUS = cli_no_status
SPEECH_TS = cli_speech_ts

update_process_title(CHAR_NAME || 'ProfanityFE', '')

ColorManager.configure(
  default_color_id: DEFAULT_COLOR_ID,
  default_background_color_id: DEFAULT_BACKGROUND_COLOR_ID,
  custom_colors: CUSTOM_COLORS
)

# ========== INITIALIZE CORE OBJECTS ==========

# Declared here so closures (execute_command, etc.) can capture it.
# Assigned later after layout is loaded.
server = nil
blue_links = cli_links

xml_escape_list = {
  '&lt;'   => '<',
  '&gt;'   => '>',
  '&quot;' => '"',
  '&apos;' => "'",
  '&amp;'  => '&'
}

shared_state = SharedState.new
cmd_buffer = CommandBuffer.new
window_mgr = WindowManager.new

key_binding = {}
key_action = {}

# Mouse scroll wheel support
write_to_client = proc { |text|
  if (window = window_mgr.stream[MAIN_STREAM])
    window.add_string(text, [{ fg: Autocomplete::HIGHLIGHT_COLOR, start: 0, end: text.length }])
    cmd_buffer.refresh
    Curses.doupdate
  end
}
mouse_scroll = MouseScroll.new(key_action, write_to_client)

# ========== MACRO ENGINE ==========

# Interpret and execute a macro string, inserting characters into the
# command buffer while handling escape sequences: \\ (literal backslash),
# \x (clear buffer), \r (send command), \@ (literal @), \? (backfill
# cursor position). A bare @ marks the final cursor position.
do_macro = proc { |macro|
  backslash = false
  at_pos = nil
  backfill = nil
  macro.split('').each_with_index do |ch, i|
    if backslash
      if ch == '\\'
        cmd_buffer.put_ch('\\')
      elsif ch == 'x'
        cmd_buffer.text.clear
        # Reset position via clear_and_get then discard
        cmd_buffer.clear_and_get
      elsif ch == 'r'
        at_pos = nil
        key_action['send_command'].call
      elsif ch == '@'
        cmd_buffer.put_ch('@')
      elsif ch == '?'
        backfill = i - 3
      end
      backslash = false
    elsif ch == '\\'
      backslash = true
    elsif ch == '@'
      at_pos = cmd_buffer.pos
    else
      cmd_buffer.put_ch(ch)
    end
  end
  if at_pos
    cmd_buffer.cursor_left while at_pos < cmd_buffer.pos
    cmd_buffer.cursor_right while at_pos > cmd_buffer.pos
  end
  cmd_buffer.refresh
  if backfill
    cmd_buffer.window.setpos(0, backfill)
    # Direct position set for backfill (rare macro feature)
    backfill = nil
  end
  Curses.doupdate
}

# ========== COMMAND DISPATCH ==========
#
# Dot-commands are local Profanity commands (not sent to the game server).
# Any input starting with '.' that doesn't match a dot-command below is
# forwarded to the server with the leading '.' replaced by ';'.
#
# Available dot-commands:
#   .quit              Exit Profanity immediately.
#   .key               Display the raw keycode of the next key pressed.
#                      Useful for discovering keycodes to bind in settings XML.
#   .fixcolor          Reinitialize custom Curses colors from ColorManager.
#                      Use after terminal color corruption or theme changes.
#                      Only meaningful when CUSTOM_COLORS is enabled.
#   .resync            Reset server time offset, forcing recalculation on
#                      next prompt. Fixes drifted countdown/roundtime timers.
#   .reload            Hot-reload settings XML (~/.profanity.xml). Reloads
#                      key bindings, highlights, and gag patterns in place.
#   .layout <name>     Switch to a named window layout defined in settings XML.
#                      Reloads all windows and triggers a resize.
#   .resize            Manually recalculate all window positions and sizes for
#                      the current terminal dimensions. Use when automatic
#                      resize detection (KEY_RESIZE) doesn't fire.
#   .tab               List all tabs in tabbed windows (active tab marked *).
#   .tab <number>      Switch to tab by 1-based index.
#   .tab <name>        Switch to tab by name.
#   .help              Show this list of dot-commands.
#
# All dot-commands are case-insensitive.

DOT_COMMAND_HELP = [
  '.quit              Exit Profanity immediately',
  '.key               Show raw keycode of next key press',
  '.fixcolor          Reinitialize custom Curses colors',
  '.resync            Reset server time offset for timers',
  '.reload            Hot-reload settings XML file',
  '.layout <name>     Switch to a named window layout',
  '.resize            Recalculate window sizes for terminal',
  '.tab               List tabs (active marked with *)',
  '.tab <N|name>      Switch tab by number or name',
  '.links             Toggle in-game link highlighting',
  '.scrollcfg         Configure mouse scroll wheel',
  '.help              Show this help'
].freeze

# Dispatch a user command. Dot-commands (e.g. .quit, .key, .reload)
# are handled locally; everything else is forwarded to the game server.
execute_command = proc { |cmd|
  if cmd =~ /^\.quit/i
    exit
  elsif cmd =~ /^\.key/i
    # Display raw keycode of next key press (debugging aid for key bindings)
    if (window = window_mgr.stream[MAIN_STREAM])
      window.add_string('* ')
      window.add_string('* Waiting for key press...')
      cmd_buffer.refresh
      Curses.doupdate
      window.add_string("* Detected keycode: #{cmd_buffer.window.getch}")
      window.add_string('* ')
      Curses.doupdate
    end
  elsif cmd =~ /^\.fixcolor/i
    ColorManager.reinitialize_colors
  elsif cmd =~ /^\.resync/i
    shared_state.skip_server_time_offset = false
  elsif cmd =~ /^\.reload/i
    SettingsLoader.load(SETTINGS_FILENAME, key_binding, key_action, do_macro, reload: true)
  elsif (match = cmd.match(/^\.layout\s+(?<layout>.+)/))
    window_mgr.load_layout(match[:layout])
    cmd_buffer.window = window_mgr.command_window
    key_action['resize'].call
  elsif cmd =~ /^\.resize/i
    key_action['resize'].call
  elsif (match = cmd.match(/^\.tab(?:\s+(?<arg>.+))?/i))
    arg = match[:arg]&.strip
    if TabbedTextWindow.list.empty?
      window_mgr.stream[MAIN_STREAM]&.add_string('* No tabbed windows configured')
    elsif arg.nil? || arg.empty?
      # List all tabs with active marked by *
      TabbedTextWindow.list.each do |win|
        tabs_info = win.tabs.keys.each_with_index.map do |name, i|
          "#{i + 1}:#{name}#{name == win.active_tab ? '*' : ''}"
        end.join(' ')
        window_mgr.stream[MAIN_STREAM]&.add_string("* Tabs: #{tabs_info}")
      end
    elsif arg =~ /^\d+$/
      TabbedTextWindow.list.each { |w| w.switch_tab_by_index(arg.to_i) }
      Curses.doupdate
    else
      TabbedTextWindow.list.each { |w| w.switch_tab(arg) }
      Curses.doupdate
    end
  elsif cmd =~ /^\.links/i
    blue_links = !blue_links
    if (window = window_mgr.stream[MAIN_STREAM])
      window.add_string("* Links display: #{blue_links ? 'ON' : 'OFF'}")
      Curses.doupdate
    end
  elsif cmd =~ /^\.scrollcfg/i
    mouse_scroll.start_configuration
  elsif cmd =~ /^\.help/i
    if (window = window_mgr.stream[MAIN_STREAM])
      window.add_string('* ')
      DOT_COMMAND_HELP.each { |line| window.add_string("*   #{line}") }
      window.add_string('* ')
      Curses.doupdate
    end
  else
    # Not a dot-command — forward to game server with '.' replaced by ';'
    server.puts cmd.sub(/^\./, ';')
  end
}

# Re-execute a command from the history buffer at the given index.
# Echoes the command to the main window before dispatching it.
send_history_command = proc { |index|
  if (cmd = cmd_buffer.history[index])
    if (window = window_mgr.stream[MAIN_STREAM])
      add_prompt(window, shared_state.prompt_text, cmd)
      cmd_buffer.refresh
      Curses.doupdate
    end
    execute_command.call(cmd)
  end
}

# ========== KEY ACTIONS ==========

key_action['resize'] = proc {
  window_mgr.resize(cmd_buffer)
  Curses.doupdate
}

key_action['cursor_left'] = proc {
  cmd_buffer.cursor_left
  Curses.doupdate
}

key_action['cursor_right'] = proc {
  cmd_buffer.cursor_right
  Curses.doupdate
}

key_action['cursor_word_left'] = proc {
  cmd_buffer.cursor_word_left
  Curses.doupdate
}

key_action['cursor_word_right'] = proc {
  cmd_buffer.cursor_word_right
  Curses.doupdate
}

key_action['cursor_home'] = proc {
  cmd_buffer.cursor_home
  Curses.doupdate
}

key_action['cursor_end'] = proc {
  cmd_buffer.cursor_end
  Curses.doupdate
}

key_action['cursor_backspace'] = proc {
  cmd_buffer.backspace
  Curses.doupdate
}

key_action['cursor_delete'] = proc {
  cmd_buffer.delete_char
  Curses.doupdate
}

key_action['cursor_backspace_word'] = proc {
  cmd_buffer.backspace_word
}

key_action['cursor_delete_word'] = proc {
  cmd_buffer.delete_word
}

key_action['cursor_kill_forward'] = proc {
  cmd_buffer.kill_forward
  Curses.doupdate
}

key_action['cursor_kill_line'] = proc {
  cmd_buffer.kill_line
  Curses.doupdate
}

key_action['cursor_yank'] = proc {
  cmd_buffer.yank
}

key_action['switch_current_window'] = proc {
  if (current_scroll_window = SCROLL_WINDOW[0])
    current_scroll_window.set_active(false)
  end
  SCROLL_WINDOW.push(SCROLL_WINDOW.shift)
  if (current_scroll_window = SCROLL_WINDOW[0])
    current_scroll_window.set_active(true)
  end
  cmd_buffer.refresh
  Curses.doupdate
}

key_action['next_tab'] = proc {
  TabbedTextWindow.list.each(&:next_tab)
  cmd_buffer.refresh
  Curses.doupdate
}

key_action['prev_tab'] = proc {
  TabbedTextWindow.list.each(&:prev_tab)
  cmd_buffer.refresh
  Curses.doupdate
}

(1..5).each do |n|
  key_action["switch_tab_#{n}"] = proc {
    TabbedTextWindow.list.each { |w| w.switch_tab_by_index(n) }
    cmd_buffer.refresh
    Curses.doupdate
  }
end

key_action['scroll_current_window_up_one'] = proc {
  SCROLL_WINDOW[0]&.scroll(-1)
  cmd_buffer.refresh
  Curses.doupdate
}

key_action['scroll_current_window_down_one'] = proc {
  SCROLL_WINDOW[0]&.scroll(1)
  cmd_buffer.refresh
  Curses.doupdate
}

key_action['scroll_current_window_up_page'] = proc {
  if (w = SCROLL_WINDOW[0])
    w.scroll(0 - w.maxy + 1)
  end
  cmd_buffer.refresh
  Curses.doupdate
}

key_action['scroll_current_window_down_page'] = proc {
  if (w = SCROLL_WINDOW[0])
    w.scroll(w.maxy - 1)
  end
  cmd_buffer.refresh
  Curses.doupdate
}

key_action['scroll_current_window_bottom'] = proc {
  SCROLL_WINDOW[0]&.scroll(SCROLL_WINDOW[0]&.max_buffer_size)
  cmd_buffer.refresh
  Curses.doupdate
}

key_action['previous_command'] = proc {
  cmd_buffer.previous_command
  Curses.doupdate
}

key_action['next_command'] = proc {
  cmd_buffer.next_command
  Curses.doupdate
}

key_action['send_command'] = proc {
  cmd = cmd_buffer.clear_and_get
  shared_state.need_prompt = false
  if (window = window_mgr.stream[MAIN_STREAM])
    add_prompt(window, shared_state.prompt_text, cmd)
  end
  cmd_buffer.refresh
  Curses.doupdate
  cmd_buffer.add_to_history(cmd)
  execute_command.call(cmd)
}

key_action['send_last_command'] = proc { send_history_command.call(1) }

key_action['send_second_last_command'] = proc { send_history_command.call(2) }

key_action['autocomplete'] = proc {
  Autocomplete.complete(cmd_buffer, window_mgr.stream[MAIN_STREAM])
}

# ========== LOAD SETTINGS AND LAYOUT ==========

SettingsLoader.load(SETTINGS_FILENAME, key_binding, key_action, do_macro)
window_mgr.load_layout('default')
cmd_buffer.window = window_mgr.command_window

TextWindow.list.each { |w| w.maxy.times { w.add_string "\n".dup } }

# ========== CONNECT AND RUN ==========

begin
  server = TCPSocket.open('127.0.0.1', PORT)
rescue Errno::ECONNREFUSED, Errno::ECONNRESET, SocketError => e
  warn "Failed to connect to game server on port #{PORT}: #{e.message}"
  warn 'Is the game server running?'
  exit 1
end

server.puts "SET_FRONTEND_PID #{Process.pid}"
server.flush

$server_time_offset = 0.0

# Time sync thread
Thread.new do
  sleep TIME_SYNC_DELAY
  shared_state.skip_server_time_offset = false
end

# Server read thread
processor = GameTextProcessor.new(
  window_mgr: window_mgr,
  shared_state: shared_state,
  cmd_buffer: cmd_buffer,
  xml_escapes: xml_escape_list
)
Thread.new { processor.run(server) }

# ========== INPUT LOOP ==========

begin
  key_combo = nil
  loop do
    ch = cmd_buffer.window.getch

    # Handle mouse events first
    if ch == Curses::KEY_MOUSE
      if mouse_scroll.configuring?
        mouse_scroll.process(ch)
        next
      end
      mouse_scroll.process(ch)

      mouse = Curses.getmouse
      if mouse
        screen_y = mouse.y
        screen_x = mouse.x
        bstate = mouse.bstate

        ProfanityLog.write('Mouse', "bstate=#{bstate} at (#{screen_y},#{screen_x})")

        if (bstate & Curses::BUTTON1_PRESSED) != 0
          window = BaseWindow.find_window_at(screen_y, screen_x)
          if window
            rel_y = screen_y - window.begy
            rel_x = screen_x - window.begx
            SelectionManager.start_selection(window, rel_y, rel_x)
          end
        elsif (bstate & Curses::BUTTON1_RELEASED) != 0
          if SelectionManager.selecting
            window = SelectionManager.active_window
            if window
              rel_y = screen_y - window.begy
              rel_x = screen_x - window.begx
              SelectionManager.update_selection(rel_y, rel_x)
            end
            SelectionManager.end_selection
          end
        elsif defined?(Curses::BUTTON1_CLICKED) && (bstate & Curses::BUTTON1_CLICKED) != 0
          window = BaseWindow.find_window_at(screen_y, screen_x)
          if window
            rel_y = screen_y - window.begy
            rel_x = screen_x - window.begx
            SelectionManager.start_selection(window, rel_y, rel_x)
            SelectionManager.end_selection
          end
        elsif (bstate & Curses::REPORT_MOUSE_POSITION) != 0
          if SelectionManager.selecting
            window = SelectionManager.active_window
            if window
              rel_y = screen_y - window.begy
              rel_x = screen_x - window.begx
              SelectionManager.update_selection(rel_y, rel_x)
              Curses.doupdate
            end
          end
        end
      end
      next
    end

    if key_combo
      if key_combo[ch].instance_of?(Proc)
        key_combo[ch].call
        key_combo = nil
      elsif key_combo[ch].instance_of?(Hash)
        key_combo = key_combo[ch]
      else
        key_combo = nil
      end
    elsif key_binding[ch].instance_of?(Proc)
      key_binding[ch].call
    elsif key_binding[ch].instance_of?(Hash)
      key_combo = key_binding[ch]
    elsif ch.instance_of?(String)
      cmd_buffer.put_ch(ch)
      cmd_buffer.refresh
      Curses.doupdate
    end
  end
rescue StandardError => e
  ProfanityLog.write('main', e.to_s, backtrace: e.backtrace)
ensure
  begin
    server.close
  rescue StandardError
    # ignore
  end
  Curses.close_screen
end

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

# Thread-safe curses rendering (must be loaded before any doupdate calls)
require_relative 'lib/curses_renderer'

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
cli_room_window_only = false
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
    puts '   --room-window-only                  Do not echo room data to the story window'
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
  elsif arg =~ /^--room-window-only$/
    cli_room_window_only = true
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

NO_STATUS = cli_no_status
SPEECH_TS = cli_speech_ts

ColorManager.configure(
  default_color_id: DEFAULT_COLOR_ID,
  default_background_color_id: DEFAULT_BACKGROUND_COLOR_ID,
  custom_colors: CUSTOM_COLORS
)

# ========== INITIALIZE CORE OBJECTS ==========

# Declared here so closures (execute_command, etc.) can capture it.
# Assigned later after layout is loaded.
server = nil

xml_escape_list = {
  '&lt;'   => '<',
  '&gt;'   => '>',
  '&quot;' => '"',
  '&apos;' => "'",
  '&amp;'  => '&'
}

shared_state = SharedState.new
shared_state.char_name = CHAR_NAME&.capitalize || 'ProfanityFE'
shared_state.no_status = NO_STATUS
shared_state.blue_links = cli_links
shared_state.room_window_only = cli_room_window_only
shared_state.update_terminal_title
cmd_buffer = CommandBuffer.new
window_mgr = WindowManager.new

key_binding = {}
key_action = {}

# Color helper for ProfanityFE feedback messages (dot-commands, status, etc.)
feedback_colors = ->(text) { [{ start: 0, end: text.length, fg: FEEDBACK_COLOR, bg: nil, ul: nil }] }

# Mouse scroll wheel support
write_to_client = proc { |text|
  if (window = window_mgr.stream[MAIN_STREAM])
    window.add_string(text, feedback_colors.call(text))
    cmd_buffer.refresh
    CursesRenderer.doupdate
  end
}
mouse_scroll = MouseScroll.new(key_action, write_to_client)
# Enable mouse click capture if --links was passed on startup
mouse_scroll.enable_click_events if cli_links

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
  CursesRenderer.doupdate
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
#   .arrow             Cycle up/down arrow keys through three modes:
#                      history (default) -> page scroll -> line scroll.
#   .links             Toggle in-game link highlighting (<a> tags). Controlled
#                      by the 'links' preset color in the template XML.
#   .scrollcfg         Open interactive mouse scroll wheel configuration.
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
  '.arrow             Cycle arrow keys: history/page/line',
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
      msg = '* Waiting for key press...'
      window.add_string('* ', feedback_colors.call('* '))
      window.add_string(msg, feedback_colors.call(msg))
      cmd_buffer.refresh
      CursesRenderer.doupdate
      msg = "* Detected keycode: #{cmd_buffer.window.getch}"
      window.add_string(msg, feedback_colors.call(msg))
      window.add_string('* ', feedback_colors.call('* '))
      CursesRenderer.doupdate
    end
  elsif cmd =~ /^\.fixcolor/i
    # Reinitialize custom Curses color pairs (fixes palette corruption)
    ColorManager.reinitialize_colors
  elsif cmd =~ /^\.resync/i
    # Reset server time offset so the next prompt recalculates roundtime sync
    shared_state.skip_server_time_offset = false
  elsif cmd =~ /^\.reload/i
    # Hot-reload settings XML: key bindings, highlights, gags, presets
    SettingsLoader.load(SETTINGS_FILENAME, key_binding, key_action, do_macro, reload: true)
  elsif (match = cmd.match(/^\.layout\s+(?<layout>.+)/))
    # Switch to a named layout defined in settings XML and trigger resize
    window_mgr.load_layout(match[:layout])
    cmd_buffer.window = window_mgr.command_window
    key_action['resize'].call
  elsif cmd =~ /^\.resize/i
    # Manually recalculate window positions for current terminal dimensions
    key_action['resize'].call
  elsif (match = cmd.match(/^\.tab(?:\s+(?<arg>.+))?/i))
    arg = match[:arg]&.strip
    if TabbedTextWindow.list.empty?
      msg = '* No tabbed windows configured'
      window_mgr.stream[MAIN_STREAM]&.add_string(msg, feedback_colors.call(msg))
    elsif arg.nil? || arg.empty?
      # List all tabs with active marked by *
      TabbedTextWindow.list.each do |win|
        tabs_info = win.tabs.keys.each_with_index.map do |name, i|
          "#{i + 1}:#{name}#{name == win.active_tab ? '*' : ''}"
        end.join(' ')
        msg = "* Tabs: #{tabs_info}"
        window_mgr.stream[MAIN_STREAM]&.add_string(msg, feedback_colors.call(msg))
      end
    elsif arg =~ /^\d+$/
      TabbedTextWindow.list.each { |w| w.switch_tab_by_index(arg.to_i) }
      CursesRenderer.doupdate
    else
      TabbedTextWindow.list.each { |w| w.switch_tab(arg) }
      CursesRenderer.doupdate
    end
  elsif cmd =~ /^\.arrow/i
    # Cycle arrow key mode: history -> page scroll -> line scroll
    key_action['switch_arrow_mode'].call
    if (window = window_mgr.stream[MAIN_STREAM])
      mode = if key_binding[Curses::KEY_UP] == key_action['previous_command']
               'history'
             elsif key_binding[Curses::KEY_UP] == key_action['scroll_current_window_up_page']
               'page scroll'
             else
               'line scroll'
             end
      msg = "* Arrow mode: #{mode}"
      window.add_string(msg, feedback_colors.call(msg))
      CursesRenderer.doupdate
    end
  elsif cmd =~ /^\.links/i
    # Toggle in-game link highlighting and clickable links
    shared_state.blue_links = !shared_state.blue_links
    # Enable/disable mouse click capture (off restores native terminal selection)
    if shared_state.blue_links
      mouse_scroll.enable_click_events
    else
      mouse_scroll.disable_click_events
    end
    # Update room window link state and re-render
    if (room_win = window_mgr.room['room'])
      room_win.links_enabled = shared_state.blue_links
      room_win.render
    end
    if (window = window_mgr.stream[MAIN_STREAM])
      msg = if shared_state.blue_links
              '* Links: ON (clickable links + drag-to-select)'
            else
              '* Links: OFF (native terminal selection)'
            end
      window.add_string(msg, feedback_colors.call(msg))
      CursesRenderer.doupdate
    end
  elsif cmd =~ /^\.scrollcfg/i
    # Open interactive mouse scroll wheel configuration dialog
    mouse_scroll.start_configuration
  elsif cmd =~ /^\.help/i
    if (window = window_mgr.stream[MAIN_STREAM])
      window.add_string('* ', feedback_colors.call('* '))
      DOT_COMMAND_HELP.each { |line| msg = "*   #{line}"; window.add_string(msg, feedback_colors.call(msg)) }
      window.add_string('* ', feedback_colors.call('* '))
      CursesRenderer.doupdate
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
      CursesRenderer.doupdate
    end
    execute_command.call(cmd)
  end
}

# ========== KEY ACTIONS ==========

key_action['resize'] = proc {
  window_mgr.resize(cmd_buffer)
  CursesRenderer.doupdate
}

key_action['cursor_left'] = proc {
  cmd_buffer.cursor_left
  CursesRenderer.doupdate
}

key_action['cursor_right'] = proc {
  cmd_buffer.cursor_right
  CursesRenderer.doupdate
}

key_action['cursor_word_left'] = proc {
  cmd_buffer.cursor_word_left
  CursesRenderer.doupdate
}

key_action['cursor_word_right'] = proc {
  cmd_buffer.cursor_word_right
  CursesRenderer.doupdate
}

key_action['cursor_home'] = proc {
  cmd_buffer.cursor_home
  CursesRenderer.doupdate
}

key_action['cursor_end'] = proc {
  cmd_buffer.cursor_end
  CursesRenderer.doupdate
}

key_action['cursor_backspace'] = proc {
  cmd_buffer.backspace
  CursesRenderer.doupdate
}

key_action['cursor_delete'] = proc {
  cmd_buffer.delete_char
  CursesRenderer.doupdate
}

key_action['cursor_backspace_word'] = proc {
  cmd_buffer.backspace_word
}

key_action['cursor_delete_word'] = proc {
  cmd_buffer.delete_word
}

key_action['cursor_kill_forward'] = proc {
  cmd_buffer.kill_forward
  CursesRenderer.doupdate
}

key_action['cursor_kill_line'] = proc {
  cmd_buffer.kill_line
  CursesRenderer.doupdate
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
  CursesRenderer.doupdate
}

key_action['next_tab'] = proc {
  TabbedTextWindow.list.each(&:next_tab)
  cmd_buffer.refresh
  CursesRenderer.doupdate
}
key_action['switch_tab'] = key_action['next_tab']

key_action['prev_tab'] = proc {
  TabbedTextWindow.list.each(&:prev_tab)
  cmd_buffer.refresh
  CursesRenderer.doupdate
}
key_action['switch_tab_reverse'] = key_action['prev_tab']

(1..5).each do |n|
  key_action["switch_tab_#{n}"] = proc {
    TabbedTextWindow.list.each { |w| w.switch_tab_by_index(n) }
    cmd_buffer.refresh
    CursesRenderer.doupdate
  }
end

key_action['scroll_current_window_up_one'] = proc {
  SCROLL_WINDOW[0]&.scroll(-1)
  cmd_buffer.refresh
  CursesRenderer.doupdate
}

key_action['scroll_current_window_down_one'] = proc {
  SCROLL_WINDOW[0]&.scroll(1)
  cmd_buffer.refresh
  CursesRenderer.doupdate
}

key_action['scroll_current_window_up_page'] = proc {
  if (w = SCROLL_WINDOW[0])
    w.scroll(0 - w.maxy + 1)
  end
  cmd_buffer.refresh
  CursesRenderer.doupdate
}

key_action['scroll_current_window_down_page'] = proc {
  if (w = SCROLL_WINDOW[0])
    w.scroll(w.maxy - 1)
  end
  cmd_buffer.refresh
  CursesRenderer.doupdate
}

key_action['scroll_current_window_bottom'] = proc {
  SCROLL_WINDOW[0]&.scroll(SCROLL_WINDOW[0]&.max_buffer_size)
  cmd_buffer.refresh
  CursesRenderer.doupdate
}

key_action['previous_command'] = proc {
  cmd_buffer.previous_command
  CursesRenderer.doupdate
}

key_action['next_command'] = proc {
  cmd_buffer.next_command
  CursesRenderer.doupdate
}

key_action['switch_arrow_mode'] = proc {
  if key_binding[Curses::KEY_UP] == key_action['previous_command']
    key_binding[Curses::KEY_UP] = key_action['scroll_current_window_up_page']
    key_binding[Curses::KEY_DOWN] = key_action['scroll_current_window_down_page']
  elsif key_binding[Curses::KEY_UP] == key_action['scroll_current_window_up_page']
    key_binding[Curses::KEY_UP] = key_action['scroll_current_window_up_one']
    key_binding[Curses::KEY_DOWN] = key_action['scroll_current_window_down_one']
  else
    key_binding[Curses::KEY_UP] = key_action['previous_command']
    key_binding[Curses::KEY_DOWN] = key_action['next_command']
  end
}

key_action['send_command'] = proc {
  cmd = cmd_buffer.clear_and_get
  shared_state.need_prompt = false
  if (window = window_mgr.stream[MAIN_STREAM])
    add_prompt(window, shared_state.prompt_text, cmd)
  end
  cmd_buffer.refresh
  CursesRenderer.doupdate
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

if LAYOUT.empty?
  $stderr.puts "ERROR: No layouts found in #{SETTINGS_FILENAME}."
  $stderr.puts "The XML file may be malformed. Check for unclosed tags or encoding errors."
  exit 1
end

window_mgr.load_layout('default')
cmd_buffer.window = window_mgr.command_window
window_mgr.room['room']&.links_enabled = cli_links

unless cmd_buffer.window
  $stderr.puts "ERROR: Layout has no command window. Add <window class='command'/> to your layout."
  exit 1
end

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
  cmd_buffer.window.nodelay = true # non-blocking getch — we manage waiting via IO.select
  loop do
    # IO.select is thread-safe and releases the GVL, so the server thread
    # runs freely while we wait for terminal input.
    IO.select([$stdin], nil, nil, 0.1)

    # All curses calls (getch + key processing) inside the monitor
    CursesRenderer.synchronize do
    ch = cmd_buffer.window.getch
    next if ch.nil? # no input (timeout or false positive)

    # Handle mouse events first
    if ch == Curses::KEY_MOUSE
      mouse = Curses.getmouse
      unless mouse
        next
      end

      if mouse_scroll.configuring?
        mouse_scroll.process(mouse)
        next
      end
      # Pass the same event to scroll handler (no double getmouse)
      mouse_scroll.process(mouse)

      screen_y = mouse.y
      screen_x = mouse.x
      bstate = mouse.bstate

      # Dispatch a link command if the click is on highlighted link text.
      # Echoes the command to the main window and sends it to the server.
      dispatch_link = proc { |window, rel_y, rel_x|
        if (link_cmd = window.link_cmd_at(rel_y, rel_x))
          if (main = window_mgr.stream[MAIN_STREAM])
            add_prompt(main, shared_state.prompt_text, link_cmd)
            CursesRenderer.doupdate
          end
          cmd_buffer.add_to_history(link_cmd)
          server.puts link_cmd
          true
        end
      }

      if (bstate & Curses::BUTTON1_PRESSED) != 0
        # Clear any previous highlight and begin tracking a new selection
        SelectionManager.clear_selection
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
            start_pos = SelectionManager.start_pos
            # Single click (no drag): check for link, skip selection
            if start_pos && start_pos[0] == rel_y && (start_pos[1] - rel_x).abs <= 3
              dispatch_link.call(window, rel_y, rel_x)
              SelectionManager.clear_selection
            else
              # Actual drag: finalize selection and copy to clipboard
              SelectionManager.update_selection(rel_y, rel_x)
              SelectionManager.end_selection
              CursesRenderer.doupdate
            end
          else
            SelectionManager.clear_selection
          end
        end
      elsif defined?(Curses::BUTTON1_CLICKED) && (bstate & Curses::BUTTON1_CLICKED) != 0
        # Single click: check for link only (no selection on click)
        SelectionManager.clear_selection
        window = BaseWindow.find_window_at(screen_y, screen_x)
        if window
          rel_y = screen_y - window.begy
          rel_x = screen_x - window.begx
          dispatch_link.call(window, rel_y, rel_x)
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
      CursesRenderer.doupdate
    end
    end # CursesRenderer.synchronize
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

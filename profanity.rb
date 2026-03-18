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
require_relative 'lib/application'

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

require 'optparse'

cli_options = {
  port: 8000,
  default_color_id: 7,
  default_background_color_id: 0,
  use_default_colors: false,
  custom_colors: nil,
  settings_file: nil,
  log_dir: nil,
  log_file: nil,
  char: nil,
  config: nil,
  template: nil,
  no_status: false,
  links: false,
  speech_ts: false,
  room_window_only: false,
  remote_url: nil,
}

OptionParser.new do |opts|
  opts.banner = "\nProfanity FrontEnd v#{VERSION}\n\n"

  opts.on('--char=NAME', 'Character name (for log file & process title)') { |v| cli_options[:char] = v }
  opts.on('--config=NAME', 'Config name to load (default: same as --char)') { |v| cli_options[:config] = v }
  opts.on('--template=FILE', 'Template file name (from templates/)') { |v| cli_options[:template] = v }
  opts.on('--port=PORT', Integer, 'Game server port (default: 8000)') { |v| cli_options[:port] = v }
  opts.on('--default-color-id=ID', Integer, 'Default foreground color (default: 7)') { |v| cli_options[:default_color_id] = v }
  opts.on('--default-background-color-id=ID', Integer, 'Default background color (default: 0)') { |v| cli_options[:default_background_color_id] = v }
  opts.on('--custom-colors=MODE', %w[on off yes no], 'Force custom color mode (on/off/yes/no)') do |v|
    cli_options[:custom_colors] = %w[on yes].include?(v)
  end
  opts.on('--use-default-colors', 'Use terminal default colors') { cli_options[:use_default_colors] = true }
  opts.on('--no-status', 'Disable process title updates') { cli_options[:no_status] = true }
  opts.on('--links', 'Enable in-game link highlighting') { cli_options[:links] = true }
  opts.on('--speech-ts', 'Add timestamps to speech, familiar, and thought windows') { cli_options[:speech_ts] = true }
  opts.on('--room-window-only', 'Do not echo room data to the story window') { cli_options[:room_window_only] = true }
  opts.on('--remote-url=URL', 'Remote game server URL') { |v| cli_options[:remote_url] = v }
  opts.on('--log-file=PATH', 'Log file path (default: profanity.log)') { |v| cli_options[:log_file] = v }
  opts.on('--log-dir=DIR', 'Log directory (default: current directory)') { |v| cli_options[:log_dir] = v }
  opts.on('--settings-file=FILE', 'Settings XML file path (overrides --char/--config lookup)') { |v| cli_options[:settings_file] = v }
end.parse!

# ========== GLOBAL CONSTANTS ==========

PORT = cli_options[:port]
CHAR_NAME = cli_options[:char]

SETTINGS_FILENAME = ProfanitySettings.resolve_template(
  char: cli_options[:config] || cli_options[:char],
  template: cli_options[:template],
  settings_file: cli_options[:settings_file],
  app_dir: File.dirname(__FILE__)
)

LOG_FILE = ProfanitySettings.resolve_log(
  char: cli_options[:char],
  log_file: cli_options[:log_file],
  log_dir: cli_options[:log_dir]
)

DEFAULT_COLOR_ID = cli_options[:default_color_id]
DEFAULT_BACKGROUND_COLOR_ID = cli_options[:default_background_color_id]
Curses.use_default_colors if cli_options[:use_default_colors]
CUSTOM_COLORS = cli_options[:custom_colors].nil? ? Curses.can_change_color? : cli_options[:custom_colors]

NO_STATUS = cli_options[:no_status]
SPEECH_TS = cli_options[:speech_ts]

ColorManager.configure(
  default_color_id: DEFAULT_COLOR_ID,
  default_background_color_id: DEFAULT_BACKGROUND_COLOR_ID,
  custom_colors: CUSTOM_COLORS
)

# ========== RUN ==========

Application.new(cli_options).run

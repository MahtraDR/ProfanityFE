# frozen_string_literal: true

=begin
constants.rb: Global mutable constants and synchronization primitives for ProfanityFE.
=end

# Global constants for ProfanityFE
#
# NOTE: These hashes/arrays are intentionally mutable - they are populated at runtime
# by load_settings_file and load_layout. Access should be synchronized via SETTINGS_LOCK
# when reading HIGHLIGHT to prevent race conditions with the settings reload thread.

# @return [String] default stream name for the primary game output window
MAIN_STREAM = 'main'

# @return [Integer] default maximum number of lines retained per text window buffer
DEFAULT_BUFFER_SIZE = 250

# @return [String] default log file name, used when no --log-file or --log-dir CLI arg is given.
#   The resolved path is stored in +LOG_FILE+ (defined in profanity.rb after CLI parsing).
DEFAULT_LOG_FILE = 'profanity.log'

# @return [Integer] number of backtrace frames written to the log on errors
BACKTRACE_LIMIT = 4

# @return [Integer] seconds to wait before allowing server time offset recalculation
TIME_SYNC_DELAY = 15

# @return [Float] seconds subtracted from countdown timers to compensate for network latency
COUNTDOWN_OFFSET = 0.2

# @return [Integer] fallback terminal width when no Curses window is attached
DEFAULT_TERMINAL_WIDTH = 80

SETTINGS_LOCK = Mutex.new

# Mutex for serializing Curses rendering calls across threads (timer threads, server thread, input thread).
# ncurses is not thread-safe — all noutrefresh/doupdate calls must be synchronized.
CURSES_MUTEX = Mutex.new

# Populated by load_settings_file from XML config - maps Regexp => [fg, bg, ul]
HIGHLIGHT = {}

# Populated by load_settings_file from XML config - maps preset_id => [fg, bg]
PRESET = {}

# Populated by load_settings_file from XML config - maps layout_id => REXML::Element
LAYOUT = {}

# Ordered list of scrollable windows for Ctrl+W cycling
SCROLL_WINDOW = []

# Current room creatures/objects for highlighting (populated by RoomWindow)
ROOM_OBJECTS = []

# Populated by load_settings_file from XML config - array of [Regexp, replacement_string]
# Used for percWindow text transformations (spell display abbreviations, etc.)
# Example XML: <perc-transform pattern=" (roisaen|roisan)" replace=""/>
PERC_TRANSFORMS = []

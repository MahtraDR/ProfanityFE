# frozen_string_literal: true

require 'monitor'

# Thread-safe rendering coordinator for curses screen updates.
#
# ncurses is not thread-safe — concurrent calls to +noutrefresh+ and
# +doupdate+ from different threads can corrupt internal data structures
# and cause visible flickering (especially on terminals with higher
# rendering latency such as MobaXterm or SSH sessions).
#
# This module serializes all screen-flush operations through a reentrant
# +Monitor+ so that timer threads, the server read thread, and the input
# loop never call +doupdate+ concurrently.  Using +Monitor+ (rather than
# +Mutex+) allows safe nesting when a synchronized block calls another
# method that also synchronizes.
#
# @example Flush the virtual screen to the terminal
#   CursesRenderer.doupdate
#
# @example Atomically update a window and flush
#   CursesRenderer.render do
#     window.update
#     cmd_buffer.window&.noutrefresh
#   end
#
# @example Serialize non-curses terminal output (e.g. OSC title sequences)
#   CursesRenderer.synchronize do
#     $stdout.print "\033]0;#{title}\007"
#     $stdout.flush
#   end
module CursesRenderer
  @monitor = Monitor.new

  module_function

  # Serialize a block of curses (or terminal I/O) operations.
  #
  # Use when performing multiple curses calls that must not be
  # interleaved with calls from other threads — for example, writing
  # escape sequences directly to +$stdout+.
  #
  # @yield block of operations to serialize
  # @return [Object] the block's return value
  def synchronize(&block)
    @monitor.synchronize(&block)
  end

  # Flush the virtual screen to the physical terminal, synchronized.
  #
  # Drop-in replacement for +Curses.doupdate+ that prevents concurrent
  # flushes from different threads.
  #
  # @return [void]
  def doupdate
    @monitor.synchronize { Curses.doupdate }
  end

  # Execute rendering operations and flush to screen atomically.
  #
  # Wraps the block and a +Curses.doupdate+ call in a single +Monitor+
  # acquisition so that no other thread can flush a partial update.
  #
  # @yield block that performs +noutrefresh+ calls on one or more windows
  # @return [void]
  def render
    @monitor.synchronize do
      yield
      Curses.doupdate
    end
  end
end

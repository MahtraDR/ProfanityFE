# frozen_string_literal: true

# kill_ring.rb: Readline-style kill ring (cut/paste buffer) for ProfanityFE.

# Readline-style kill ring for cut/paste operations.
#
# Successive calls to kill/delete-word operations accumulate text into
# the kill buffer as long as no other commands have changed the command
# buffer. Call {#before} to detect discontinuity, mutate {#buffer},
# then call {#after} to snapshot the current state for next time.
#
# @example
#   ring = KillRing.new
#   ring.before("hello world", 5)
#   ring.buffer += "hello world"[5..]  # kill forward
#   ring.after("hello", 5)
#   ring.buffer  # => " world"
class KillRing
  # @return [String] accumulated killed text for yanking
  attr_accessor :buffer

  def initialize
    @buffer = ''
    @original = ''
    @last_text = ''
    @last_pos = 0
  end

  # Call before a kill operation. Resets the buffer if the command text
  # or cursor position has changed since the last kill operation.
  #
  # @param current_text [String] current command buffer text
  # @param current_pos [Integer] current cursor position
  # @return [void]
  def before(current_text, current_pos)
    return unless @last_text != current_text || @last_pos != current_pos

    @buffer = ''
    @original = current_text
  end

  # Call after a kill operation. Snapshots the current state so the next
  # {#before} call can detect whether the buffer changed between kills.
  #
  # @param current_text [String] current command buffer text (after deletion)
  # @param current_pos [Integer] current cursor position (after deletion)
  # @return [void]
  def after(current_text, current_pos)
    @last_text = current_text.dup
    @last_pos = current_pos
  end

  # The full original text captured at the start of the current kill sequence.
  # Used by kill_line to restore the entire line on yank.
  #
  # @return [String] original text before any kills in this sequence
  attr_reader :original
end

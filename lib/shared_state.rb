# frozen_string_literal: true

# shared_state.rb: Thread-safe container for cross-thread state in ProfanityFE.

# Thread-safe container for state shared between the input thread,
# server read thread, and timer threads.
#
# Under MRI's GIL, single-variable assignment is atomic, but multi-step
# check-then-act patterns are not. This class serializes access to the
# cross-thread prompt/time-sync variables via a single mutex.
#
# @example
#   state = SharedState.new
#   state.prompt_text = 'H>'
#   state.need_prompt = true
#   state.consume_prompt!  # => true (was needed), now false
class SharedState
  # @return [String, nil] character name for terminal title (nil disables title updates)
  attr_accessor :char_name

  # @return [Boolean] whether terminal title updates are suppressed
  attr_accessor :no_status

  def initialize
    @mutex = Mutex.new
    @need_prompt = false
    @prompt_text = '>'
    @room_title = ''
    @skip_server_time_offset = false
    @blue_links = false
    @char_name = nil
    @no_status = false
    @last_title = nil
  end

  # @return [Boolean] whether a prompt display is pending
  def need_prompt
    @mutex.synchronize { @need_prompt }
  end

  # @param val [Boolean] whether a prompt display is pending
  # @return [void]
  def need_prompt=(val)
    @mutex.synchronize { @need_prompt = val }
  end

  # @return [String] current prompt string (e.g., "H>", ">")
  def prompt_text
    @mutex.synchronize { @prompt_text }
  end

  # @param val [String] new prompt string
  # @return [void]
  def prompt_text=(val)
    @mutex.synchronize { @prompt_text = val }
  end

  # @return [String] current room title (for terminal title display)
  def room_title
    @mutex.synchronize { @room_title }
  end

  # @param val [String] new room title
  # @return [void]
  def room_title=(val)
    @mutex.synchronize { @room_title = val }
  end

  # @return [Boolean] whether to skip the next server time offset calculation
  def skip_server_time_offset
    @mutex.synchronize { @skip_server_time_offset }
  end

  # @param val [Boolean] whether to skip time offset
  # @return [void]
  def skip_server_time_offset=(val)
    @mutex.synchronize { @skip_server_time_offset = val }
  end

  # @return [Boolean] whether in-game link highlighting is enabled
  def blue_links
    @mutex.synchronize { @blue_links }
  end

  # @param val [Boolean] enable or disable link highlighting
  # @return [void]
  def blue_links=(val)
    @mutex.synchronize { @blue_links = val }
  end

  # Atomically check whether the prompt text changed and update state.
  # If the text changed, sets need_prompt to false and updates prompt_text.
  # If unchanged, sets need_prompt to true (a new prompt of the same text arrived).
  #
  # @param new_prompt_text [String] the incoming prompt text to compare
  # @return [Boolean] true if prompt text changed, false if same
  def update_prompt(new_prompt_text)
    @mutex.synchronize do
      if @prompt_text != new_prompt_text
        @need_prompt = false
        @prompt_text = new_prompt_text
        true
      else
        @need_prompt = true
        false
      end
    end
  end

  # Atomically consume the need_prompt flag.
  # Returns the old value and sets need_prompt to false.
  #
  # @return [Boolean] whether a prompt was pending before this call
  def consume_prompt!
    @mutex.synchronize do
      was = @need_prompt
      @need_prompt = false
      was
    end
  end

  # Update the terminal title and process name from current prompt and room.
  #
  # Builds "CharName [prompt:room]" from {#prompt_text} and {#room_title},
  # stripping the trailing ">" from the prompt. No-op when the title hasn't
  # changed since the last call (dedup, matching EO behavior).
  #
  # Sets the terminal tab/window title via an OSC 0 escape sequence
  # written by a forked +printf+ subprocess (matching EO's approach).
  # This avoids interleaving with curses' stdout buffer.  The
  # screen/tmux +\\ek+ escape is only emitted when +$TERM+ indicates
  # a screen/tmux session.
  #
  # @return [void]
  def update_terminal_title
    return if @char_name.nil? || @no_status

    prompt = @mutex.synchronize { @prompt_text.to_s.delete('>').strip }
    room   = @mutex.synchronize { @room_title.to_s.strip }
    parts  = [prompt, room].reject(&:empty?).join(':')
    title  = parts.empty? ? @char_name : "#{@char_name} [#{parts}]"

    return if title == @last_title

    @last_title = title
    Process.setproctitle(title)
    # Set the terminal tab/window title via OSC 0 escape sequence.
    # Uses system() to fork a subprocess (matching EO's approach) so the
    # escape bytes are written independently from curses' stdout buffer —
    # no interleaving possible.  Array form of system() avoids shell
    # injection and bypasses the shell entirely.
    system('printf', '\033]0;%s\007', title)
    return unless ENV['TERM']&.match?(/^screen|^tmux/)

    system('printf', '\ek%s\e\\', title)
  rescue StandardError
    # ignore title update failures (e.g. no controlling terminal)
  end
end

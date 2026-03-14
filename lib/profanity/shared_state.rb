# frozen_string_literal: true

=begin
shared_state.rb: Thread-safe container for cross-thread state in ProfanityFE.
=end

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
  def initialize
    @mutex = Mutex.new
    @need_prompt = false
    @prompt_text = '>'
    @skip_server_time_offset = false
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

  # @return [Boolean] whether to skip the next server time offset calculation
  def skip_server_time_offset
    @mutex.synchronize { @skip_server_time_offset }
  end

  # @param val [Boolean] whether to skip time offset
  # @return [void]
  def skip_server_time_offset=(val)
    @mutex.synchronize { @skip_server_time_offset = val }
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
end

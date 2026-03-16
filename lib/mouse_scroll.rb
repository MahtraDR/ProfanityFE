# frozen_string_literal: true

require_relative 'profanity_settings'

=begin
Configurable mouse scroll wheel support.
Ported from elanthia-online/ProfanityFE.
=end

# Handles mouse scroll wheel events for window scrolling.
#
# Scroll wheel button masks vary by terminal emulator, so this class
# supports a calibration mode (`.scrollcfg`) that detects and saves
# the correct masks to +~/.profanity/settings.json+.
#
# @example
#   mouse = MouseScroll.new(key_action, display_callback)
#   mouse.process(ch)          # call from input loop on KEY_MOUSE
#   mouse.start_configuration  # call from .scrollcfg command
class MouseScroll
  MIN_EVENT_COUNT = 20

  # Bitmask for mouse click events (BUTTON1 press/release/click).
  # Always included in the mouse mask so clickable links work regardless
  # of whether scroll wheel calibration has been performed.
  CLICK_EVENTS = Curses::BUTTON1_PRESSED | Curses::BUTTON1_RELEASED |
                 (defined?(Curses::BUTTON1_CLICKED) ? Curses::BUTTON1_CLICKED : 0) |
                 Curses::REPORT_MOUSE_POSITION

  # @param key_action [Hash<String, Proc>] the key action registry
  # @param display_fn [Proc] callback to display messages: display_fn.call(text)
  def initialize(key_action, display_fn)
    @key_action = key_action
    @display_fn = display_fn
    @config_state = :idle
    @listener_enabled = false
    @button4_mask = nil
    @button5_mask = nil
    @bstate_counts = {}

    load_settings
    # Enable click events even without scroll calibration (for clickable links)
    enable_click_events
  end

  # Process a mouse event from the input loop.
  # Accepts either a key code (legacy) or a pre-fetched mouse event object.
  # When called with a mouse event, avoids double-consuming via Curses.getmouse.
  #
  # @param event [Integer, Curses::MouseEvent] KEY_MOUSE code or a mouse event object
  # @return [void]
  def process(event)
    if event.is_a?(Integer)
      return unless event == Curses::KEY_MOUSE

      m = Curses.getmouse
    else
      m = event
    end
    return unless m

    bstate = m.respond_to?(:bstate) ? m.bstate : nil
    return if bstate.nil?

    if configuring?
      configure(bstate)
    else
      handle_scroll(bstate)
    end
  rescue StandardError => e
    ProfanityLog.write('MouseScroll', e.message)
  end

  # Start scroll wheel calibration mode.
  #
  # @return [void]
  def start_configuration
    if configuring?
      reset_configuration
      @display_fn.call('[PROFANITY] Scroll configuration cancelled')
      return
    end

    @bstate_counts = {}
    @config_state = :up
    Curses.mousemask(Curses::ALL_MOUSE_EVENTS | Curses::REPORT_MOUSE_POSITION)
    @display_fn.call('[PROFANITY] Scroll up with your mouse wheel or trackpad')
  end

  # Whether calibration is in progress.
  #
  # @return [Boolean]
  def configuring?
    @config_state != :idle
  end

  private

  # Load saved scroll button masks from settings and enable the mouse listener.
  #
  # @return [void]
  def load_settings
    settings = ProfanitySettings.load_mouse_settings
    return unless settings

    @button4_mask = settings['BUTTON4_PRESSED_MASK']
    @button5_mask = settings['BUTTON5_PRESSED_MASK']

    return unless @button4_mask && @button5_mask

    @listener_enabled = true
    Curses.mousemask(@button4_mask | @button5_mask | CLICK_EVENTS)
  end

  # Enable mouse click events without scroll calibration.
  # Called at startup so clickable links work immediately.
  #
  # @return [void]
  def enable_click_events
    return if @listener_enabled # Already includes CLICK_EVENTS

    Curses.mousemask(CLICK_EVENTS)
  end

  # Cancel calibration and reset state to idle.
  #
  # @return [void]
  def reset_configuration
    @config_state = :idle
    @bstate_counts = {}
  end

  # Process a mouse event during calibration to detect scroll-up/down masks.
  #
  # @param bstate [Integer] the mouse button state bitmask
  # @return [void]
  def configure(bstate)
    case @config_state
    when :up
      @bstate_counts[bstate] = (@bstate_counts[bstate] || 0) + 1
      return unless @bstate_counts[bstate] >= MIN_EVENT_COUNT

      @button4_mask = bstate
      @config_state = :down
      @bstate_counts = {}
      @display_fn.call('[PROFANITY] Scroll down with your mouse wheel or trackpad')
    when :down
      return if bstate == @button4_mask

      @bstate_counts[bstate] = (@bstate_counts[bstate] || 0) + 1
      return unless @bstate_counts[bstate] >= MIN_EVENT_COUNT

      @button5_mask = bstate
      @config_state = :idle
      @bstate_counts = {}
      @listener_enabled = true
      Curses.mousemask(@button4_mask | @button5_mask | CLICK_EVENTS)
      ProfanitySettings.save_mouse_settings(@button4_mask, @button5_mask)
      @display_fn.call('[PROFANITY] Scroll wheel configuration complete!')
    end
  end

  # Dispatch a scroll-up or scroll-down action based on the button state.
  #
  # @param bstate [Integer] the mouse button state bitmask
  # @return [void]
  def handle_scroll(bstate)
    return unless @button4_mask && @button5_mask

    unless @listener_enabled
      Curses.mousemask(@button4_mask | @button5_mask | CLICK_EVENTS)
      @listener_enabled = true
    end

    if (bstate & @button4_mask).nonzero?
      @key_action['scroll_current_window_up_one']&.call
    elsif (bstate & @button5_mask).nonzero?
      @key_action['scroll_current_window_down_one']&.call
    end
  end
end

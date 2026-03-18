# frozen_string_literal: true

require_relative 'xml_tokenizer'
require_relative 'link_extractor'

# Tag dispatch and handler methods for game server XML processing.
#
# Replaces the 30+ elsif regex chain in GameTextProcessor#run with
# a hash-based dispatch table and focused handler methods. Each XML
# tag type has its own method, making the processing logic easier to
# understand, test, and modify independently.
#
# Expects the including class to provide:
# - @wm, @state, @cmd_buffer, @xml_escapes
# - @line_colors, @open_monsterbold, @open_preset, @open_style,
#   @open_color, @open_link
# - @current_stream, @combat_next_line, @need_update, @need_room_render
# - @room_capture_mode
# - handle_game_text, new_stun, fix_layout_number, parse_room_subtitle,
#   add_prompt
module TagHandlers
  # Dispatch table for opening and self-closing tags.
  TAG_DISPATCH = {
    'prompt'       => :handle_prompt_tag,
    'spell'        => :handle_spell_tag,
    'right'        => :handle_hand_tag,
    'left'         => :handle_hand_tag,
    'roundTime'    => :handle_roundtime_tag,
    'castTime'     => :handle_casttime_tag,
    'compass'      => :handle_compass_tag,
    'progressBar'  => :handle_progress_bar_tag,
    'arbProgress'  => :handle_arb_progress_tag,
    'pushBold'     => :handle_push_bold,
    'b'            => :handle_push_bold,
    'popBold'      => :handle_pop_bold,
    'preset'       => :handle_open_preset,
    'color'        => :handle_open_color,
    'style'        => :handle_style_tag,
    'pushStream'   => :handle_stream_open,
    'component'    => :handle_stream_open,
    'compDef'      => :handle_stream_open,
    'popStream'    => :handle_stream_close,
    'clearStream'  => :handle_clear_stream,
    'indicator'    => :handle_indicator_tag,
    'image'        => :handle_image_tag,
    'LaunchURL'    => :handle_launch_url,
    'a'            => :handle_open_link,
    'd'            => :handle_open_link,
    'streamWindow' => :handle_stream_window,
    'dialogdata'   => :handle_ignored_tag,
    'label'        => :handle_ignored_tag,
    'skin'         => :handle_ignored_tag,
    'output'       => :handle_ignored_tag,
  }.freeze

  # Dispatch table for closing tags (</tagname>).
  CLOSING_TAG_DISPATCH = {
    'preset'    => :handle_close_preset,
    'color'     => :handle_close_color,
    'b'         => :handle_pop_bold,
    'a'         => :handle_close_link,
    'd'         => :handle_close_link,
    'component' => :handle_stream_close,
    'compDef'   => :handle_stream_close,
  }.freeze

  # Dispatch an XML tag to its handler method.
  #
  # @param xml [String] full XML tag string
  # @param text_buffer [String] mutable text accumulator (positions
  #   are tracked via text_buffer.length)
  # @return [void]
  def dispatch_tag(xml, text_buffer)
    # Combat tracking: reset flag on any <popStream id="combat"...> tag.
    # This runs for every tag, before dispatch (matching original behavior).
    @combat_next_line = false if xml.match?(%r{<popStream[^>]*id=["']combat["']})

    name = XmlTokenizer.tag_name(xml)
    closing = xml.start_with?('</')

    table = closing ? CLOSING_TAG_DISPATCH : TAG_DISPATCH
    handler = table[name]

    if handler
      send(handler, xml, text_buffer)
    elsif @combat_next_line
      # Unrecognized tag while combat-next-line is active:
      # flush accumulated text and switch to combat stream.
      flush_text_buffer(text_buffer)
      @current_stream = 'combat'
    end
  end

  private

  # Flush accumulated text through handle_game_text and clear the buffer.
  #
  # @param buf [String] mutable text buffer to flush and clear
  # @return [void]
  def flush_text_buffer(buf)
    handle_game_text(buf.dup) unless buf.empty?
    buf.clear
  end

  # Unescape XML entities in a text segment.
  #
  # @param text [String] text with XML entities (&lt;, &gt;, etc.)
  # @return [String] unescaped text
  def unescape_entities(text)
    result = text.dup
    @xml_escapes.each do |entity, replacement|
      result.gsub!(entity, replacement)
    end
    result
  end

  # ---- Tag handlers ----
  #
  # Each handler receives the full XML tag string and the mutable text
  # buffer. Color region positions use text_buffer.length, which is
  # always correct because the buffer only contains non-tag text.
  # Handlers that need to emit accumulated text before changing state
  # call flush_text_buffer.

  # Explicitly ignored game protocol tags (dialog data, labels, etc.).
  def handle_ignored_tag(_xml, _text_buffer); end

  # Handle <prompt time='...'>text&gt;</prompt> paired tag.
  # Syncs server time offset and updates the prompt display.
  def handle_prompt_tag(xml, _text_buffer)
    return unless (m = xml.match(%r{^<prompt time=(?<q>'|")(?<time>[0-9]+)\k<q>.*?>(?<text>.*?)&gt;</prompt>$}))

    unless @state.skip_server_time_offset
      $server_time_offset = Time.now.to_f - m[:time].to_f
      @state.skip_server_time_offset = true
    end

    new_prompt_text = "#{m[:text]}>"
    if @state.prompt_text != new_prompt_text
      @state.need_prompt = false
      @state.prompt_text = new_prompt_text
      add_prompt(@wm.stream[MAIN_STREAM], new_prompt_text)
      if (prompt_window = @wm.indicator['prompt'])
        init_prompt_height = fix_layout_number(prompt_window.layout[0])
        init_prompt_width = fix_layout_number(prompt_window.layout[1])
        new_prompt_width = new_prompt_text.length
        prompt_window.resize(init_prompt_height, new_prompt_width)
        prompt_width_diff = new_prompt_width - init_prompt_width
        @wm.command_window.resize(fix_layout_number(@wm.command_window_layout[0]),
                                  fix_layout_number(@wm.command_window_layout[1]) - prompt_width_diff)
        ctop = fix_layout_number(@wm.command_window_layout[2])
        cleft = fix_layout_number(@wm.command_window_layout[3]) + prompt_width_diff
        @wm.command_window.move(ctop, cleft)
        prompt_window.label = new_prompt_text
      end
    else
      @state.need_prompt = true
    end
  end

  # Handle <spell>name</spell> paired tag.
  def handle_spell_tag(xml, _text_buffer)
    return unless (m = xml.match(%r{^<spell(?:>|\s.*?>)(?<spell>.*?)</spell>$}))
    return unless (window = @wm.indicator['spell'])

    window.label = m[:spell]
    window.update(m[:spell] == 'None' ? 0 : 1)
    @need_update = true
  end

  # Handle <right>item</right> or <left>item</left> paired tag.
  def handle_hand_tag(xml, _text_buffer)
    return unless (m = xml.match(%r{^<(?<hand>right|left)(?:>|\s.*?>)(?<item>.*?\S*?)</\k<hand>>}))
    return unless (window = @wm.indicator[m[:hand]])

    window.label = m[:item]
    window.update(m[:item] == 'Empty' ? 0 : 1)
    @need_update = true
  end

  # Handle <roundTime value='N'/> tag. Starts a countdown timer thread.
  def handle_roundtime_tag(xml, _text_buffer)
    return unless (m = xml.match(/^<roundTime value=(?<q>'|")(?<value>[0-9]+)\k<q>/))
    return unless (window = @wm.countdown['roundtime'])

    temp_roundtime_end = m[:value].to_i
    window.end_time = temp_roundtime_end
    window.update
    @need_update = true
    Thread.new do
      sleep 0.15
      while (window.end_time == temp_roundtime_end) && (window.value > 0)
        sleep 0.15
        CursesRenderer.render do
          next unless window.update

          @cmd_buffer.window&.noutrefresh
        end
      end
    rescue StandardError => e
      ProfanityLog.write('roundtime thread', e.to_s, backtrace: e.backtrace)
    end
  end

  # Handle <castTime value='N'/> tag. Starts a secondary countdown timer thread.
  def handle_casttime_tag(xml, _text_buffer)
    return unless (m = xml.match(/^<castTime value=(?<q>'|")(?<value>[0-9]+)\k<q>/))
    return unless (window = @wm.countdown['roundtime'])

    temp_casttime_end = m[:value].to_i
    window.secondary_end_time = temp_casttime_end
    window.update
    @need_update = true
    Thread.new do
      while (window.secondary_end_time == temp_casttime_end) && (window.secondary_value > 0)
        sleep 0.15
        CursesRenderer.render do
          next unless window.update

          @cmd_buffer.window&.noutrefresh
        end
      end
    rescue StandardError => e
      ProfanityLog.write('casttime thread', e.to_s, backtrace: e.backtrace)
    end
  end

  # Handle <compass>...<dir value="n"/>...</compass> paired tag.
  def handle_compass_tag(xml, _text_buffer)
    current_dirs = xml.scan(/<dir value="(.*?)"/).flatten
    %w[up down out n ne e se s sw w nw].each do |dir|
      next unless (window = @wm.indicator["compass:#{dir}"])

      @need_update = true if window.update(current_dirs.include?(dir))
    end
  end

  # Handle <progressBar .../> tags for vitals, stance, encumbrance, mind.
  # Dispatches to game-specific sub-patterns based on id and text format.
  def handle_progress_bar_tag(xml, _text_buffer)
    if (m = xml.match(/^<progressBar id='encumlevel' value='(?<value>[0-9]+)' text='(?<text>.*?)'/))
      if (window = @wm.progress['encumbrance'])
        value = m[:text] == 'Overloaded' ? 110 : m[:value].to_i
        @need_update = true if window.update(value, 110)
      end
    elsif (m = xml.match(/^<progressBar id='pbarStance' value='(?<value>[0-9]+)'/))
      if (window = @wm.progress['stance']) && window.update(m[:value].to_i, 100)
        @need_update = true
      end
    elsif (m = xml.match(/^<progressBar id='mindState' value='(?<value>.*?)' text='(?<text>.*?)'/))
      if (window = @wm.progress['mind'])
        value = m[:text] == 'saturated' ? 110 : m[:value].to_i
        @need_update = true if window.update(value, 110)
      end
    elsif (m = xml.match(/^<progressBar id='(?<id>.*?)' value='[0-9]+' text='.*?\s+(?<cur>-?[0-9]+)\/(?<max>[0-9]+)'/))
      # GemStone vitals: text contains current/max (e.g., "health 456/456")
      if (window = @wm.progress[m[:id]]) && window.update(m[:cur].to_i, m[:max].to_i)
        @need_update = true
      end
    elsif (m = xml.match(/^<progressBar id='(?<id>health|mana|spirit|stamina|concentration)' value='(?<value>[0-9]+)' text='(?:health|mana|spirit|fatigue|concentration|inner fire) [0-9]+\%'/))
      # DragonRealms vitals: text contains percentage (e.g., "health 75%")
      if (window = @wm.progress[m[:id]]) && window.update(m[:value].to_i, 100)
        @need_update = true
      end
    end
  end

  # Handle <arbProgress id='...' max='...' current='...'/> user-defined progress bars.
  def handle_arb_progress_tag(xml, _text_buffer)
    return unless (m = xml.match(/^<arbProgress id='(?<id>[a-zA-Z0-9]+)' max='(?<max>\d+)' current='(?<cur>\d+)'(?:\s+label='(?<label>.+?)')?(?:\s+colors='(?<colors>\S+?)')?/))

    current = [m[:cur].to_i, m[:max].to_i].min
    return unless (window = @wm.progress[m[:id]])

    window.label = m[:label] if m[:label]
    if m[:colors]
      bg, fg = m[:colors].split(',')
      window.bg = [bg] if bg
      window.fg = [fg] if fg
    end
    @need_update = true if window.update(current, m[:max].to_i)
  end

  # Handle <pushBold/> or <b> tag. Opens a monster bold color region.
  def handle_push_bold(_xml, text_buffer)
    h = { start: text_buffer.length }
    if PRESET['monsterbold']
      h[:fg] = PRESET['monsterbold'][0]
      h[:bg] = PRESET['monsterbold'][1]
    end
    @open_monsterbold.push(h)
  end

  # Handle <popBold/> or </b> tag. Closes the most recent monster bold region.
  def handle_pop_bold(_xml, text_buffer)
    if (h = @open_monsterbold.pop)
      h[:end] = text_buffer.length
      @line_colors.push(h) if h[:fg] || h[:bg]
    end
  end

  # Handle <preset id='...'> opening tag.
  def handle_open_preset(xml, text_buffer)
    return unless (m = xml.match(/^<preset id=(?<q>'|")(?<id>.*?)\k<q>>$/))

    preset_id = m[:id]
    if preset_id == 'roomDesc' && @wm.room['room']
      flush_text_buffer(text_buffer)
      @room_capture_mode = :desc
    end
    h = { start: text_buffer.length }
    if PRESET[preset_id]
      h[:fg] = PRESET[preset_id][0]
      h[:bg] = PRESET[preset_id][1]
    end
    @open_preset.push(h)
  end

  # Handle </preset> closing tag.
  def handle_close_preset(_xml, text_buffer)
    if @room_capture_mode == :desc
      flush_text_buffer(text_buffer)
    end
    if (h = @open_preset.pop)
      h[:end] = text_buffer.length
      @line_colors.push(h) if h[:fg] || h[:bg]
    end
  end

  # Handle <color fg='...' bg='...' ul='...'> opening tag.
  def handle_open_color(xml, text_buffer)
    h = { start: text_buffer.length }
    if (fg_match = xml.match(/\sfg=(?<q>'|")(?<val>.*?)\k<q>[\s>]/))
      h[:fg] = fg_match[:val].downcase
    end
    if (bg_match = xml.match(/\sbg=(?<q>'|")(?<val>.*?)\k<q>[\s>]/))
      h[:bg] = bg_match[:val].downcase
    end
    if (ul_match = xml.match(/\sul=(?<q>'|")(?<val>.*?)\k<q>[\s>]/))
      h[:ul] = ul_match[:val].downcase
    end
    @open_color.push(h)
  end

  # Handle </color> closing tag.
  def handle_close_color(_xml, text_buffer)
    if (h = @open_color.pop)
      h[:end] = text_buffer.length
      @line_colors.push(h)
    end
  end

  # Handle <style id='...'> tag (both opening and "closing" via empty id).
  # The game protocol uses <style id=""> as a close marker rather than </style>.
  def handle_style_tag(xml, text_buffer)
    return unless (m = xml.match(/^<style id=(?<q>'|")(?<id>.*?)\k<q>/))

    style_id = m[:id]
    if style_id.empty?
      # Empty id = closing style
      if @room_capture_mode == :title || @room_capture_mode == :desc
        flush_text_buffer(text_buffer)
      end
      if @open_style
        @open_style[:end] = text_buffer.length
        if (@open_style[:start] < @open_style[:end]) && (@open_style[:fg] || @open_style[:bg])
          @line_colors.push(@open_style)
        end
        @open_style = nil
      end
    else
      # Non-empty id = opening style
      @open_style = { start: text_buffer.length }
      if PRESET[style_id]
        @open_style[:fg] = PRESET[style_id][0]
        @open_style[:bg] = PRESET[style_id][1]
      end
      @room_capture_mode = :title if style_id == 'roomName'
      @room_capture_mode = :desc if style_id == 'roomDesc' && @wm.room['room']
    end
  end

  # Handle <pushStream>, <component>, or <compDef> stream-opening tag.
  # Flushes accumulated text and switches the current stream.
  def handle_stream_open(xml, text_buffer)
    return unless (m = xml.match(%r{id=(?<q>"|')(?<id>.*?)\k<q>}))

    flush_text_buffer(text_buffer)
    new_stream = m[:id]
    if (exp_match = new_stream.match(/^exp (?<skill>\w+\s?\w+?)/))
      @current_stream = 'exp'
      @wm.stream['exp']&.set_current(exp_match[:skill])
    else
      @current_stream = new_stream
      if new_stream == 'room' && (sub_match = xml.match(/subtitle=(?<q>"|')(?<sub>.*?)\k<q>/))
        title = parse_room_subtitle(sub_match[:sub])
        unless title.empty?
          @state.room_title = title
          @wm.room['room']&.update_title(title)
        end
      end
    end

    @combat_next_line = true if @current_stream == 'combat'
  end

  # Handle <popStream.../>, </component>, or </compDef> stream-closing tag.
  # Flushes accumulated text and clears the current stream.
  def handle_stream_close(_xml, text_buffer)
    flush_text_buffer(text_buffer)
    @wm.stream['exp']&.delete_skill if @current_stream == 'exp'
    @current_stream = nil
  end

  # Handle <clearStream id="percWindow"/> tag.
  def handle_clear_stream(xml, _text_buffer)
    @wm.stream['percWindow']&.clear_spells if xml.match?(/id=["']percWindow["']/)
  end

  # Handle <a ...> or <d ...> link opening tag.
  def handle_open_link(xml, text_buffer)
    return unless @state.blue_links

    preset = PRESET['links'] || LinkExtractor::DEFAULT_LINK_COLOR
    link = { start: text_buffer.length, fg: preset[0], bg: preset[1], priority: 2 }
    link[:cmd] = LinkExtractor.extract_cmd(xml)
    @open_link.push(link)
  end

  # Handle </a> or </d> link closing tag.
  def handle_close_link(_xml, text_buffer)
    if (h = @open_link.pop)
      h[:end] = text_buffer.length
      # For tags without cmd/exist (e.g., exit directions),
      # use the link text itself as the command
      h[:cmd] ||= text_buffer[h[:start]...h[:end]] if h[:start] && h[:end] > h[:start]
      @line_colors.push(h) if h[:fg] || h[:bg]
    end
  end

  # Handle <indicator id='IconXXX' visible='y|n'/> tag.
  def handle_indicator_tag(xml, _text_buffer)
    return unless (m = xml.match(/^<indicator id=(?<q1>'|")Icon(?<icon>[A-Z]+)\k<q1> visible=(?<q2>'|")(?<vis>[yn])\k<q2>/))

    if (window = @wm.countdown[m[:icon].downcase])
      window.active = (m[:vis] == 'y')
      @need_update = true if window.update
    end
    if (window = @wm.indicator[m[:icon].downcase]) && window.update(m[:vis] == 'y')
      @need_update = true
    end
  end

  # Handle <image id='...' name='...'/> body part/injury tag.
  def handle_image_tag(xml, _text_buffer)
    return unless (m = xml.match(/^<image id=(?<q1>'|")(?<id>back|leftHand|rightHand|head|rightArm|abdomen|leftEye|leftArm|chest|rightLeg|neck|leftLeg|nsys|rightEye)\k<q1> name=(?<q2>'|")(?<name>.*?)\k<q2>/))

    if m[:id] == 'nsys'
      if (window = @wm.indicator['nsys'])
        if (rank = m[:name].slice(/[0-9]/))
          @need_update = true if window.update(rank.to_i)
        elsif window.update(0)
          @need_update = true
        end
      end
    else
      fix_value = { 'Injury1' => 1, 'Injury2' => 2, 'Injury3' => 3, 'Scar1' => 4, 'Scar2' => 5, 'Scar3' => 6 }
      if (window = @wm.indicator[m[:id]]) && window.update(fix_value[m[:name]] || 0)
        @need_update = true
      end
    end
  end

  # Handle <LaunchURL src="..."/> tag.
  def handle_launch_url(xml, _text_buffer)
    return unless (m = xml.match(/^<LaunchURL src="(?<src>[^"]+)"/))

    url = "https://www.play.net#{m[:src]}"
    @wm.stream[MAIN_STREAM]&.add_string(' *'.dup)
    @wm.stream[MAIN_STREAM]&.add_string(" * LaunchURL: #{url}")
    @wm.stream[MAIN_STREAM]&.add_string(' *'.dup)
  end

  # Handle <streamWindow id='room' subtitle='...'/> tag.
  def handle_stream_window(xml, _text_buffer)
    return unless (m = xml.match(/^<streamWindow id='room'.*?subtitle=(?<q>"|')(?<sub>.*?)\k<q>/))

    room = parse_room_subtitle(m[:sub])
    return if room.empty?

    @state.room_title = room
    if (window = @wm.indicator['room'])
      window.label = room
      window.update(1)
      @need_update = true
    end
    @wm.room['room']&.update_title(room)
  end
end

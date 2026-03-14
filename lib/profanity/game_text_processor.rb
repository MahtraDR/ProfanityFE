# frozen_string_literal: true

require_relative 'spell_abbreviations'

=begin
Processes game server output in a dedicated thread, handling XML tag parsing,
stream routing, room data assembly, spell abbreviation, and UI updates.
=end

# Processes all game text received from the server read thread.
#
# Handles the full pipeline from raw server output to rendered UI:
# XML tag parsing, stream routing (combat, death, logons, etc.),
# room data assembly (title, description, objects, players, exits),
# spell name abbreviation for percWindow, indicator/progress/countdown
# updates, stun detection, bold/color/preset tracking, highlight
# application, and movement suppression.
#
# Extracted from the main server read Thread.new block in profanity.rb
# (~1,165 lines). Converts thread-local variables to instance variables,
# the handle_game_text proc to a private method, and the while loop to
# the public #run method.
#
# @example
#   processor = GameTextProcessor.new(
#     window_mgr:  wm,
#     shared_state: state,
#     cmd_buffer:   cmd_buffer,
#     xml_escapes:  { '&gt;' => '>', '&lt;' => '<' }
#   )
#   processor.run(server)
class GameTextProcessor
  # DragonRealms spell abbreviation lookup.
  # @see DR_SPELL_ABBREVIATIONS
  DR_ALL_SPELLS = DR_SPELL_ABBREVIATIONS

  # Create a new processor wired to the given window manager and shared state.
  #
  # @param window_mgr [WindowManager] provides handler hashes for stream/indicator/progress/countdown/room windows
  # @param shared_state [OpenStruct] mutable state shared with the input thread (need_prompt, prompt_text, skip_server_time_offset)
  # @param cmd_buffer [CommandBuffer] the command-line input buffer (used for Curses refresh coordination)
  # @param xml_escapes [Hash<String, String>] XML entity to character mappings (e.g. +"&gt;"+ => +">"+)
  def initialize(window_mgr:, shared_state:, cmd_buffer:, xml_escapes:)
    @wm = window_mgr
    @state = shared_state
    @cmd_buffer = cmd_buffer
    @xml_escapes = xml_escapes

    # Line color/style tracking
    @line_colors = []
    @open_monsterbold = []
    @open_preset = []
    @open_style = nil
    @open_color = []

    # Stream and display state
    @current_stream = nil
    @bold_next_line = false
    @emptycount = 0
    @combat_next_line = nil
    @need_update = false

    # Track content sent to dedicated stream windows to prevent duplicates to main
    @last_stream_text = nil

    # Track movement messages to suppress prompts/empty lines after them
    @last_was_movement = false

    # Room data tracking for RoomWindow
    @room_capture_mode = nil  # :title, :desc, or nil
    @room_pending_title = nil
    @room_pending_title_colors = nil
    @room_pending_desc = nil
    @room_pending_desc_colors = nil
    @room_pending_objects = nil
    @room_pending_objects_colors = nil
    @room_pending_players = nil
    @room_pending_exits = nil
    @room_pending_number = nil
    @current_raw_line = nil  # Raw line with XML tags preserved for room object extraction
  end

  # Main processing loop. Blocks on +server.gets+ reading lines from the
  # game server socket and processes each through XML tag extraction,
  # stream routing, bold/color tracking, room data assembly, and window
  # updates. Exits (calls +exit+) when the connection is closed or an
  # unrecoverable error occurs.
  #
  # @param server [IO] TCP socket (or socket-like) connected to the game server
  # @return [void] never returns normally; calls +exit+ on disconnect or error
  def run(server)
    line = nil

    while (line = server.gets)

      # File.write("combatlog.txt", line.inspect + "\n", mode: "a")

      if line =~ /^<popBold\/>/
        @bold_next_line = false
      elsif @bold_next_line == true
        line = "<pushBold/>#{line.chomp}<popBold/>\n"
      elsif line =~ /<pushBold\/>\r\n$/
        @bold_next_line = true
      end

      line.chomp!

      if line.match(GagPatterns.general_regexp)
        # p line.inspect
        # File.write("gaglog.txt", line.inspect + "\n", mode: "a")
        # line = nil
        next
      # elsif line.match(/\w+ offers you .* almanac .* ACCEPT to accept the offer or DECLINE to decline it\./)
        # Saelia offers you an encyclopedic almanac carefully bound with a shadowleaf cover.  Enter ACCEPT to accept the offer or DECLINE to decline it.  The offer will expire in 30 seconds.
        # server.puts("accept\nawake\n")
      elsif line.empty?
        @emptycount += 1
        if @emptycount > 1
          line = nil
          next
        end
      else
        @emptycount = 0
      end

      # if line.match(/The moth/)
      #   File.write("mothlog.txt", line.inspect + "\n", mode: "a")
      # end

      if line.empty?
        if @current_stream.nil?
          # Check if last line in ANY tab was movement (backup check)
          main_window = @wm.stream[MAIN_STREAM]
          last_line_was_movement = false
          movement_pattern = /^You (?:run|walk|go|swim|climb|crawl|drag|stride|sneak|stalk)\b/

          if main_window.is_a?(TabbedTextWindow)
            # Check all tabs for recent movement (movement could be in main, combat, etc.)
            main_window.tabs.each_value do |tab_buffer|
              last_entry = tab_buffer.find { |entry| entry[0] && !entry[0].strip.empty? }
              if last_entry && last_entry[0] =~ movement_pattern
                last_line_was_movement = true
                break
              end
            end
          elsif main_window.respond_to?(:buffer) && !main_window.buffer.empty?
            last_entry = main_window.buffer.find { |entry| entry[0] && !entry[0].strip.empty? }
            last_line_was_movement = last_entry && last_entry[0] =~ movement_pattern
          end

          # Skip prompt and empty line after movement (use flag OR buffer check)
          if @last_was_movement || last_line_was_movement
            @state.need_prompt = false
            @last_was_movement = false
            # Skip the empty line entirely
          else
            if @state.need_prompt
              @state.need_prompt = false
              add_prompt(main_window, @state.prompt_text)
            end
            main_window.route_string(String.new, [], MAIN_STREAM)
            @need_update = true
          end
        end
      else
        # Save raw line with XML tags for room object extraction (RoomWindow needs tags)
        @current_raw_line = line.dup
        while (xml_match = line.match(/(?<xml><(?<tag>prompt|spell|right|left|inv|compass).*?\k<tag>>|<.*?>)/))
          start_pos = xml_match.begin(0)
          xml = xml_match[:xml]
          line.slice!(start_pos, xml.length)

          if xml =~ %r{<popStream id="combat" />}
          # File.write("poplog.txt", line.inspect + "\n", mode: "a")
            @combat_next_line = false
          end

          if (prompt_match = xml.match(%r{^<prompt time=(?<q>'|")(?<time>[0-9]+)\k<q>.*?>(?<text>.*?)&gt;</prompt>$}))
            unless @state.skip_server_time_offset
              $server_time_offset = Time.now.to_f - prompt_match[:time].to_f
              @state.skip_server_time_offset = true
            end
            new_prompt_text = "#{prompt_match[:text]}>"
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
          elsif (spell_match = xml.match(%r{^<spell(?:>|\s.*?>)(?<spell>.*?)</spell>$}))
            if (window = @wm.indicator['spell'])
              window.clear
              window.label = spell_match[:spell]
              window.update(spell_match[:spell] == 'None' ? 0 : 1)
              @need_update = true
            end
          elsif (hand_match = xml.match(%r{^<(?<hand>right|left)(?:>|\s.*?>)(?<item>.*?\S*?)</\k<hand>>}))
            if (window = @wm.indicator[hand_match[:hand]])
              window.clear
              window.label = hand_match[:item]
              window.update(hand_match[:item] == 'Empty' ? 0 : 1)
              @need_update = true
            end
          elsif (rt_match = xml.match(/^<roundTime value=(?<q>'|")(?<value>[0-9]+)\k<q>/))
            if (window = @wm.countdown['roundtime'])
              temp_roundtime_end = rt_match[:value].to_i
              window.end_time = temp_roundtime_end
              window.update
              @need_update = true
              Thread.new do
                begin
                  sleep 0.15
                  while (@wm.countdown['roundtime'].end_time == temp_roundtime_end) and (@wm.countdown['roundtime'].value > 0)
                    sleep 0.15
                    if @wm.countdown['roundtime'].update
                      CURSES_MUTEX.synchronize do
                        @cmd_buffer.window&.noutrefresh
                        Curses.doupdate
                      end
                    end
                  end
                rescue StandardError => e
                  begin
                    File.open(LOG_FILE, 'a') { |f| f.puts "[roundtime thread] #{e}"; f.puts e.backtrace[0...BACKTRACE_LIMIT] }
                  rescue StandardError
                    $stderr.puts "[roundtime thread] #{e}"
                  end
                end
              end
            end
          elsif (cast_match = xml.match(/^<castTime value=(?<q>'|")(?<value>[0-9]+)\k<q>/))
            if (window = @wm.countdown['roundtime'])
              temp_casttime_end = cast_match[:value].to_i
              window.secondary_end_time = temp_casttime_end
              window.update
              @need_update = true
              Thread.new do
                begin
                  while (@wm.countdown['roundtime'].secondary_end_time == temp_casttime_end) and (@wm.countdown['roundtime'].secondary_value > 0)
                    sleep 0.15
                    if @wm.countdown['roundtime'].update
                      CURSES_MUTEX.synchronize do
                        @cmd_buffer.window&.noutrefresh
                        Curses.doupdate
                      end
                    end
                  end
                rescue StandardError => e
                  begin
                    File.open(LOG_FILE, 'a') { |f| f.puts "[casttime thread] #{e}"; f.puts e.backtrace[0...BACKTRACE_LIMIT] }
                  rescue StandardError
                    $stderr.puts "[casttime thread] #{e}"
                  end
                end
              end
            end
          elsif xml =~ /^<compass/
            current_dirs = xml.scan(/<dir value="(.*?)"/).flatten
            %w[up down out n ne e se s sw w nw].each do |dir|
              next unless (window = @wm.indicator["compass:#{dir}"])

              @need_update = true if window.update(current_dirs.include?(dir))
            end
          elsif (pbar_match = xml.match(/^<progressBar id='(?<id>.*?)' value='[0-9]+' text='.* (?<pct>[0-9]+)%/))
            if (window = @wm.progress[pbar_match[:id]]) && window.update(pbar_match[:pct].to_i, 100)
              @need_update = true
            end
          elsif (stance_match = xml.match(/^<progressBar id='pbarStance' value='(?<value>[0-9]+)'/))
            if (window = @wm.progress['stance']) && window.update(stance_match[:value].to_i, 100)
              @need_update = true
            end
          elsif (mind_match = xml.match(/^<progressBar id='mindState' value='(?<value>.*?)' text='(?<text>.*?)'/))
            if (window = @wm.progress['mind'])
              value = if mind_match[:text] == 'saturated'
                        110
                      else
                        mind_match[:value].to_i
                      end
              @need_update = true if window.update(value, 110)
            end

          elsif ['<pushBold/>', '<b>'].include?(xml)
            h = { start: start_pos }
            if PRESET['monsterbold']
              h[:fg] = PRESET['monsterbold'][0]
              h[:bg] = PRESET['monsterbold'][1]
            end
            @open_monsterbold.push(h)
          elsif ['<popBold/>', '</b>'].include?(xml)
            if (h = @open_monsterbold.pop)
              h[:end] = start_pos
              @line_colors.push(h) if h[:fg] or h[:bg]
            end
          elsif (preset_match = xml.match(/^<preset id=(?<q>'|")(?<id>.*?)\k<q>>$/))
            preset_id = preset_match[:id]
            # Only extract text for roomDesc preset
            if preset_id == 'roomDesc' && @wm.room['room']
              game_text = line.slice!(0, start_pos)
              handle_game_text(game_text)
              @room_capture_mode = :desc
            end
            h = { start: start_pos }
            if PRESET[preset_id]
              h[:fg] = PRESET[preset_id][0]
              h[:bg] = PRESET[preset_id][1]
            end
            @open_preset.push(h)
          elsif xml == '</preset>'
            # Only extract text if we're in room description capture mode
            if @room_capture_mode == :desc
              game_text = line.slice!(0, start_pos)
              handle_game_text(game_text)
            end
            if (h = @open_preset.pop)
              h[:end] = start_pos
              @line_colors.push(h) if h[:fg] or h[:bg]
            end
          elsif xml =~ /^<color/
            h = { start: start_pos }
            h[:fg] = fg_match[:val].downcase if (fg_match = xml.match(/\sfg=(?<q>'|")(?<val>.*?)\k<q>[\s>]/))
            h[:bg] = bg_match[:val].downcase if (bg_match = xml.match(/\sbg=(?<q>'|")(?<val>.*?)\k<q>[\s>]/))
            h[:ul] = ul_match[:val].downcase if (ul_match = xml.match(/\sul=(?<q>'|")(?<val>.*?)\k<q>[\s>]/))
            @open_color.push(h)
          elsif xml == '</color>'
            if (h = @open_color.pop)
              h[:end] = start_pos
              @line_colors.push(h)
            end
          elsif (style_match = xml.match(/^<style id=(?<q>'|")(?<id>.*?)\k<q>/))
            style_id = style_match[:id]
            # Only extract text for room-related styles
            if style_id.empty? && @room_capture_mode == :title
              # Closing style tag while in title mode - extract the title
              game_text = line.slice!(0, start_pos)
              handle_game_text(game_text)
            end
            if style_id.empty?
              if @open_style
                @open_style[:end] = start_pos
                if (@open_style[:start] < @open_style[:end]) and (@open_style[:fg] or @open_style[:bg])
                  @line_colors.push(@open_style)
                end
                @open_style = nil
              end
            else
              @open_style = { start: start_pos }
              if PRESET[style_id]
                @open_style[:fg] = PRESET[style_id][0]
                @open_style[:bg] = PRESET[style_id][1]
              end
              # Set room capture mode for roomName style
              @room_capture_mode = :title if style_id == 'roomName' && @wm.room['room']
            end
          elsif @combat_next_line && !line.empty?
            # line = "<pushStream id=\"combat\" />#{line.chomp}"
            @current_stream = "combat"
            # File.write("combatnextlog.txt", line.inspect + "\n", mode: "a")
            game_text = line.slice!(0, start_pos)
            handle_game_text(game_text)
          elsif line =~ %r{^<pushStream id="combat" />}
            # File.write("pushlog.txt", line.inspect + "\n", mode: "a")
            @current_stream = "combat"
            game_text = line.slice!(0, start_pos)
            handle_game_text(game_text)
            @combat_next_line = true
          elsif (stream_match = xml.match(%r{<(?:pushStream|component) id=(?<q>"|')(?<id>.*?)\k<q>[^>]*/?>}))
            new_stream = stream_match[:id]
            if (exp_match = new_stream.match(/^exp (?<skill>\w+\s?\w+?)/))
              @current_stream = 'exp'
              @wm.stream['exp'].set_current(exp_match[:skill]) if @wm.stream['exp']
            # elsif new_stream =~ /^moonWindow/
            # 	@current_stream = 'moonWindow'
            # 	@wm.stream['moonWindow'].clear_spells if @wm.stream['moonWindow']
            else
              @current_stream = new_stream
              # Extract room title from subtitle attribute (e.g., <component id="room" subtitle=" - Room Name">)
              if new_stream == 'room' && @wm.room['room'] && (sub_match = xml.match(/subtitle=(?<q>"|')(?<sub>.*?)\k<q>/))
                subtitle = sub_match[:sub]
                # Strip leading " - " if present
                title = subtitle.sub(/^\s*-\s*/, '').sub(/^\[/, '').sub(/\]$/, '')
                @wm.room['room'].update_title(title) unless title.empty?
              end
            end
            game_text = line.slice!(0, start_pos)
            handle_game_text(game_text)
          elsif xml =~ %r{^<popStream(?!/><pushStream)} or xml == '</component>'
            game_text = line.slice!(0, start_pos)
            handle_game_text(game_text)
            @wm.stream['exp'].delete_skill if @current_stream == 'exp' and @wm.stream['exp']
            @current_stream = nil
          elsif xml =~ %r{^<clearStream id="percWindow"/>$}
            @wm.stream['percWindow'].clear_spells if @wm.stream['percWindow']
          elsif xml =~ /^<progressBar/
            nil
          elsif xml =~ %r{<d cmd='get}
            # contents = xml.scan(/'([^']*)'/)[0]
            contents = xml[/'([^']*)'/,1]
            # File.open('profanitya.log', 'a') do |f|
            #   f.puts("TestXML: #{contents}")
            # end
            @wm.stream[MAIN_STREAM].add_string "TestXML: #{contents}"
          elsif xml =~ %r{^<(?:dialogdata|a|/a|d|/d|/?component|label|skin|output)}
            nil
          elsif (ind_match = xml.match(/^<indicator id=(?<q1>'|")Icon(?<icon>[A-Z]+)\k<q1> visible=(?<q2>'|")(?<vis>[yn])\k<q2>/))
            if (window = @wm.countdown[ind_match[:icon].downcase])
              window.active = (ind_match[:vis] == 'y')
              @need_update = true if window.update
            end
            if (window = @wm.indicator[ind_match[:icon].downcase]) && window.update(ind_match[:vis] == 'y')
              @need_update = true
            end
          elsif (img_match = xml.match(/^<image id=(?<q1>'|")(?<id>back|leftHand|rightHand|head|rightArm|abdomen|leftEye|leftArm|chest|rightLeg|neck|leftLeg|nsys|rightEye)\k<q1> name=(?<q2>'|")(?<name>.*?)\k<q2>/))
            if img_match[:id] == 'nsys'
              if (window = @wm.indicator['nsys'])
                if (rank = img_match[:name].slice(/[0-9]/))
                  @need_update = true if window.update(rank.to_i)
                elsif window.update(0)
                  @need_update = true
                end
              end
            else
              fix_value = { 'Injury1' => 1, 'Injury2' => 2, 'Injury3' => 3, 'Scar1' => 4, 'Scar2' => 5, 'Scar3' => 6 }
              if (window = @wm.indicator[img_match[:id]]) && window.update(fix_value[img_match[:name]] || 0)
                @need_update = true
              end
            end
          elsif (url_match = xml.match(/^<LaunchURL src="(?<src>[^"]+)"/))
            url = "https://www.play.net#{url_match[:src]}"
            # assume linux if not mac
            # TODO somehow determine whether we are running in a gui environment?
            # for now, just print it instead of trying to open it
            # cmd = RUBY_PLATFORM =~ /darwin/ ? "open" : "firefox"
            # system("#{cmd} #{url}")
            @wm.stream[MAIN_STREAM].add_string ' *'.dup
            @wm.stream[MAIN_STREAM].add_string " * LaunchURL: #{url}"
            @wm.stream[MAIN_STREAM].add_string ' *'.dup
          end
        end
        handle_game_text(line)
      end
      #
      # delay screen update if there are more game lines waiting
      #
      next unless @need_update and !IO.select([server], nil, nil, 0.001)

      @need_update = false
      CURSES_MUTEX.synchronize do
        @cmd_buffer.window&.noutrefresh
        Curses.doupdate
      end
    end
    # After loop exits (connection closed):
    @wm.stream[MAIN_STREAM].add_string ' *'.dup
    @wm.stream[MAIN_STREAM].add_string ' * Connection closed'.dup
    @wm.stream[MAIN_STREAM].add_string ' * Press any key to exit...'.dup
    @wm.stream[MAIN_STREAM].add_string ' *'.dup
    CURSES_MUTEX.synchronize do
      @cmd_buffer.window&.noutrefresh
      Curses.doupdate
    end
    @cmd_buffer.window&.getch
    exit
  rescue StandardError => e
    begin
      File.open(LOG_FILE, 'a') do |f|
        f.puts e
        f.puts e.backtrace[0...BACKTRACE_LIMIT]
      end
    rescue StandardError
      $stderr.puts e
      $stderr.puts e.backtrace[0...BACKTRACE_LIMIT]
    end
    exit
  end

  private

  # Evaluate a layout dimension string to an integer, substituting
  # Curses terminal dimensions for the tokens "lines" and "cols".
  #
  # @param str [String] dimension expression (e.g. "lines-2", "cols/3")
  # @return [Integer] computed dimension value
  # @api private
  def fix_layout_number(str)
    str = str.gsub('lines', Curses.lines.to_s).gsub('cols', Curses.cols.to_s)
    safe_eval_arithmetic(str)
  end

  # Start a countdown timer for the stun indicator window.
  # Spawns a background thread that ticks the countdown display
  # every 150ms until it reaches zero.
  #
  # @param seconds [Integer, Float] duration of the stun in seconds
  # @return [void]
  # @api private
  def new_stun(seconds)
    if (window = @wm.countdown['stunned'])
      temp_stun_end = Time.now.to_f - $server_time_offset.to_f + seconds.to_f
      window.end_time = temp_stun_end
      window.update
      Thread.new do
        begin
          while (window.end_time == temp_stun_end) && (window.value > 0)
            sleep 0.15
            if window.update
              CURSES_MUTEX.synchronize do
                @cmd_buffer.window&.noutrefresh
                Curses.doupdate
              end
            end
          end
        rescue StandardError => e
          begin
            File.open(LOG_FILE, 'a') { |f| f.puts "[stun thread] #{e}"; f.puts e.backtrace[0...BACKTRACE_LIMIT] }
          rescue StandardError
            $stderr.puts "[stun thread] #{e}"
          end
        end
      end
    end
  end

  # Process a chunk of game text after XML tags have been stripped.
  #
  # Applies XML entity unescaping, captures room data (title, description,
  # objects, players, exits) for RoomWindow, matches notification patterns
  # for the familiar stream, detects stun/movement/health text, applies
  # color presets and highlight patterns, and routes the final text to
  # the appropriate window (stream, main, or dedicated handler).
  #
  # @param text [String] game text with XML tags already removed
  # @return [void]
  # @api private
  def handle_game_text(text)
    text = text.dup if text.frozen?
    @xml_escapes.each_key do |escapable|
      replacement = @xml_escapes[escapable]
      search_pos = 0
      while (pos = text.index(escapable, search_pos))
        text = text.sub(escapable, replacement)
        @line_colors.each do |h|
          h[:start] -= (escapable.length - 1) if h[:start] > pos
          h[:end] -= (escapable.length - 1) if h[:end] > pos
        end
        @open_style[:start] -= (escapable.length - 1) if @open_style and (@open_style[:start] > pos)
        search_pos = pos + replacement.length
      end
    end

    # Room data capture for RoomWindow - skip routing to main window if captured
    room_data_captured = false
    if @wm.room['room'] && !text.empty?
      case @room_capture_mode
      when :title
        # Capture room title (RoomWindow will add brackets during render)
        # Format input: [Room Name] (Room ID) -> output: Room Name] (Room ID)
        # Remove leading [ and trailing ] before room ID
        @room_pending_title = text.sub(/^\[/, '').sub(/\]\s*\(/, ' (').strip
        @room_pending_title_colors = @line_colors.dup
        @room_capture_mode = nil
        room_data_captured = true
      when :desc
        @room_pending_desc = text.strip
        @room_pending_desc_colors = @line_colors.dup
        @room_capture_mode = nil
        room_data_captured = true
      end

      # Detect "You also see" for objects (may have leading whitespace)
      if text =~ /^\s*You also see\b/
        # Extract from raw line to preserve <pushBold/> tags for RoomWindow creature highlighting
        # Strip </component> tag which may be at end of raw line
        if @current_raw_line && (match = @current_raw_line.match(/You also see\b.*/))
          @room_pending_objects = match[0].gsub(%r{</component>}, '').strip
        else
          @room_pending_objects = text.strip
        end
        @room_pending_objects_colors = @line_colors.dup
        room_data_captured = true
      end

      # Detect "Also here:" for players
      if text =~ /^Also here:\s*(.+)$/
        @room_pending_players = text.strip
        room_data_captured = true
      end

      # Detect "Obvious paths:", "Obvious exits:", or "Room Exits:" for exits
      if text =~ /^(?:Obvious (?:paths|exits)|Room Exits):/
        # Strip <d> tags from exits
        @room_pending_exits = text.gsub(/<\/?d>/, '').strip
        room_data_captured = true
        # Trigger room render since exits are typically last
        # Only update if we have pending data (avoid double-updates clearing data)
        if (@room_pending_title || @room_pending_desc || @room_pending_objects || @room_pending_players) &&
           (room_window = @wm.room['room'])
          room_window.update_title(@room_pending_title || '')
          room_window.update_desc(@room_pending_desc || '')
          room_window.update_objects(@room_pending_objects || '')
          room_window.update_players(@room_pending_players || '')
          room_window.clear_supplemental

          # Also update the room players indicator (fallback for games that don't use streams)
          if (window = @wm.indicator['room players'])
            if @room_pending_players
              names = parse_player_names(@room_pending_players)
              if names.any?
                names_text = names.join(', ')
                window.label_colors = HighlightProcessor.apply_highlights(names_text, [])
                window.label = names_text
                window.update(true)
              else
                window.label_colors = nil
                window.label = ' '
                window.update(false)
              end
            else
              # No players in room - clear the indicator
              window.label_colors = nil
              window.label = ' '
              window.update(false)
            end
          end

          # Clear pending data
          @room_pending_title = nil
          @room_pending_title_colors = nil
          @room_pending_desc = nil
          @room_pending_desc_colors = nil
          @room_pending_objects = nil
          @room_pending_objects_colors = nil
          @room_pending_players = nil
          @room_pending_number = nil
        end

        # Always update exits (even on subsequent exit lines)
        @wm.room['room'].update_exits(@room_pending_exits || '')
        @room_pending_exits = nil
        @need_update = true
      end

      # Detect "Room Number:" or "StringProcs:" lines (come after exits)
      if text =~ /^Room Number:\s*\d+/
        @wm.room['room'].update_room_number(text.strip)
        room_data_captured = true
        @need_update = true
      elsif text =~ /^StringProcs:/
        @wm.room['room'].update_stringprocs(text.strip)
        room_data_captured = true
        @need_update = true
      end

      # Skip routing room data to main window - don't duplicate
      return if room_data_captured
    end

    # if text =~ /<b>/
    #   text.gsub!("<b>", "<pushBold/>")
    # end
    # if text =~ /<\/b>/
    #   text.gsub!("</b>", "<popBold/>")
    # end
    # [custom/t2: ***STATUS*** EXECUTE fill-pouch]
    if text =~ /^\[(?:custom\/)?\w+: \*\*\*STATUS\*\*\*\s(?!\d+).*/
      note = text.gsub(/(\[|\]|\*\*\*STATUS\*\*\* |EXECUTE |custom\/)/, '')
    # elsif text =~ /<[^>]+>/
    #   text = ""
    elsif text =~ /Auctioneer Endlar bangs his gavel and yells, "Bidding is now open/
      note = text
    elsif text =~ /\w+ just opened the waiting list\./
      note = text
    elsif (match = text.match(/You sense nothing wrong with (?<name>\w+)/))
      note = "#{match[:name]} is all healthy."
    elsif text =~ /reaches over and holds|just tried to take your hand, but you politely pulled away|\w+ is next on .* list/
      note = text
    elsif (match = text.match(/You believe you've learned something significant about (?<topic>\w+\s?\w*)!$/))
      note = "Almanac: #{match[:topic]}"
    elsif (match = text.match(%r{Tarantula successfully sacrificed (?<count>\d+)/34 of (?<name>\w+\s?\w*) at}))
      note = "Tarantula: #{match[:name]} #{match[:count]}/34"
    elsif (match = text.match(/contains a complete description of the (?<spell>.*) spell/))
      note = "Scroll spell: #{match[:spell]}"
    elsif text =~ /^You raise the bead up, and a black glow surrounds it/
      note = "Focus effect started."
    elsif text =~ /^The glow slowly fades away from around you/
      note = "Focus effect ended."
    elsif (match = text.match(/(?<info>Spent .* looting \d+ boxes.)/))
      note = match[:info]
    elsif (match = text.match(/(?<info>\w+\s?\w*:\s+\d+\s\d+\.\d+%\s\w+\s?\w*\s+\(\d+\/34\))/))
      note = match[:info]
    elsif text =~ /(?:Character|Longitem)\s+accepting from is/
      note = text
    end

    if note
      @line_colors = []
      if PRESET['monsterbold']
        @line_colors = [{
          start: 0,
          end: note.length,
          fg: PRESET['monsterbold'][0],
          bg: PRESET['monsterbold'][1]
        }]
      end
      @wm.stream['familiar'].add_string(note, @line_colors)
      @need_update = true
    end

    if text =~ /^\[.*?\]>/
      @state.need_prompt = false
    elsif (match = text.match(/^\s*You are stunned for (?<rounds>[0-9]+) rounds?/))
      new_stun(match[:rounds].to_i * 5)
    # elsif text =~ /^Deep and resonating, you feel the chant ...
    #   # raise dead stun
    #   new_stun(30.6)
    elsif text =~ /^Just as you think the falling will never end, you crash through an ethereal barrier which bursts into a dazzling kaleidoscope of color!  Your sensation of falling turns to dizziness and you feel unusually heavy for a moment\.  Everything seems to stop for a prolonged second and then WHUMP!!!/
      # Shadow Valley exit stun
      new_stun(16.2)
    # elsif text =~ /^You have.*?(?:case of uncontrollable convulsions|case of sporadic convulsions|strange case of muscle twitching)/
    #   # nsys wound will be correctly set by xml, dont set the scar using health verb output
    #   skip_nsys = true
    elsif text =~ /^You glance down at your empty hands\./
      if (window = @wm.indicator['right'])
        window.clear
        window.label = 'Empty'
        @need_update = true
      end
      if (window = @wm.indicator['left'])
        window.clear
        window.label = 'Empty'
        @need_update = true
      end
    # elsif skip_nsys
    #   skip_nsys = false
    elsif (window = @wm.indicator['nsys'])
      if text =~ /^You have.*? very difficult time with muscle control/
        @need_update = true if window.update(3)
      elsif text =~ /^You have.*? constant muscle spasms/
        @need_update = true if window.update(2)
      elsif text =~ /^You have.*? developed slurred speech/
        @need_update = true if window.update(1)
      end
    end

    if @open_style
      h = @open_style.dup
      h[:end] = text.length
      @line_colors.push(h)
      @open_style[:start] = 0
    end
    @open_color.each do |oc|
      ocd = oc.dup
      ocd[:end] = text.length
      @line_colors.push(ocd)
      oc[:start] = 0
    end

    # Apply highlight patterns to all routable streams
    if @current_stream.nil? or @wm.stream[@current_stream] or (@current_stream =~ /^(?:death|logons|thoughts|voln|familiar|assess|ooc|shopWindow|combat|moonWindow|atmospherics)$/)
      HighlightProcessor.apply_highlights(text, @line_colors)
    end

    unless text.empty?
      if @current_stream

        # if text.match(/This is a test/)
        #   server.puts("echo tested\necho bar\n")
        # elsif text.match(/\w+ offers you .* almanac .* ACCEPT to accept the offer or DECLINE to decline it\./)
        #   # Saelia offers you an encyclopedic almanac carefully bound with a shadowleaf cover.  Enter ACCEPT to accept the offer or DECLINE to decline it.  The offer will expire in 30 seconds.

        #   server.puts("accept\nawake\n")
        # end

        if @current_stream == 'combat' && text.match(GagPatterns.combat_regexp)
          # File.write("combatgaglog.txt", line.inspect + "\n", mode: "a")
          return
        end

        if @current_stream == 'thoughts' && (text =~ /^\[.+?\]-[A-z]+:[A-Z][a-z]+: "|^\[server\]: /)
          @current_stream = 'lnet'
        end

        # Handle room components for dedicated RoomWindow
        if @current_stream =~ /^room(\s|$)/ && @wm.room['room']
          window = @wm.room['room']

          case @current_stream
          when 'room', 'room title'
            @room_pending_title = text.strip
          when 'room desc', 'roomDesc'
            @room_pending_desc = text.strip
          when 'room objs'
            # Store pending instead of updating directly to avoid duplicates
            # Use raw line to preserve <pushBold/> tags for creature highlighting
            # Strip </component> tag which may be at end of raw line
            if @current_raw_line && !@current_raw_line.empty?
              @room_pending_objects = @current_raw_line.gsub(%r{</component>}, '').strip
            else
              @room_pending_objects = text.strip
            end
          when 'room players'
            @room_pending_players = text.strip
            # Also update the indicator if present (fall through below)
          when 'room exits'
            # Trigger batch update since exits are last
            @room_pending_exits = text.gsub(/<\/?d>/, '').strip
            window.update_title(@room_pending_title || '')
            window.update_desc(@room_pending_desc || '')
            window.update_objects(@room_pending_objects || '')
            window.update_players(@room_pending_players || '')
            window.update_exits(@room_pending_exits || '')
            # Clear pending data
            @room_pending_title = nil
            @room_pending_title_colors = nil
            @room_pending_desc = nil
            @room_pending_desc_colors = nil
            @room_pending_objects = nil
            @room_pending_objects_colors = nil
            @room_pending_players = nil
            @room_pending_exits = nil
          end

          @need_update = true
          # Don't skip for room players - let the indicator handler also process it
          return unless @current_stream == 'room players'
        end

        # Handle room players indicator - extract player names only
        if @current_stream == 'room players'
          if (window = @wm.indicator['room players'])
            # Parse player names from "Also here: Title Name who is..., Title Name2 who is..."
            names = parse_player_names(text)
            if names.any?
              names_text = names.join(', ')
              # Apply highlight patterns to player names
              window.label_colors = HighlightProcessor.apply_highlights(names_text, [])
              window.label = names_text
              window.update(true)
            else
              window.label_colors = nil
              window.label = ' '
              window.update(false)
            end
            @need_update = true
          end
          return # Don't route to stream_handler
        end

        if (window = @wm.stream[@current_stream])
          if @current_stream == 'death'
            # FIXME: has been vaporized!
            # fixme: ~ off to a rough start
            if (death_match = text.match(/^\s\*\s(?:A fiery phoenix soars into the heavens as\s)?(?<name>[A-Z][a-z]+)(?: was just struck down.*| just disintegrated!| was lost to the Plane of Exile!|'s spirit arises from the ashes of death.| was smote by \w+!)/))
              name = death_match[:name]
              timestamp = Time.now.strftime('%H:%M')
              if text.match?(/A fiery phoenix soars into the heavens as/)
                text = "#{timestamp} #{name} MF"
              else
                text = "#{timestamp} #{name}"
              end
              # Apply highlights to reformatted text, then add timestamp color
              # Timestamp color (smaller range) takes priority over highlights
              @line_colors = HighlightProcessor.apply_highlights(text, [])
              @line_colors.push({
                start: 0,
                end: 5,
                fg: 'ff0000'
              })
            end
          elsif @current_stream == 'logons'
            foo = { 'joins the adventure with little fanfare.' => '007700',
                    'just sauntered into the adventure with an annoying tune on his lips.' => '007700', 'just wandered into another adventure.' => '007700', 'just limped in for another adventure.' => '007700', 'snuck out of the shadow he was hiding in.' => '007700', 'joins the adventure with a gleam in her eye.' => '007700', 'joins the adventure with a gleam in his eye.' => '007700', 'comes out from within the shadows with renewed vigor.' => '007700', 'just crawled into the adventure.' => '007700', 'has woken up in search of new ale!' => '007700', 'just popped into existance.' => '007700', 'has joined the adventure after escaping another.' => '007700', 'joins the adventure.' => '007700', 'returns home from a hard day of adventuring.' => '777700', 'has left to contemplate the life of a warrior.' => '777700', 'just sauntered off-duty to get some rest.' => '777700', 'departs from the adventure with little fanfare.' => '777700', 'limped away from the adventure for now.' => '777700', 'thankfully just returned home to work on a new tune.' => '777700', 'fades swiftly into the shadows.' => '777700', 'retires from the adventure for now.' => '777700', 'just found a shadow to hide out in.' => '777700', 'quietly departs the adventure.' => '777700', 'has disconnected.' => 'aa7733' }
            if (logon_match = text.match(/^\s\*\s(?<name>[A-Z][a-z]+) (?<type>#{foo.keys.join('|')})/))
              name = logon_match[:name]
              logon_type = logon_match[:type]
              timestamp = Time.now.strftime('%H:%M')
              text = "#{timestamp} #{name}"
              # Apply highlights to reformatted text, then add timestamp color
              # Timestamp color (smaller range) takes priority over highlights
              @line_colors = HighlightProcessor.apply_highlights(text, [])
              @line_colors.push({
                start: 0,
                end: 5,
                fg: foo[logon_type]
              })
            end
          elsif @current_stream == 'exp'
            window = @wm.stream['exp']
          elsif @current_stream == 'percWindow'
            window = @wm.stream['percWindow']

            # Apply configurable text transformations from XML
            # Example: <perc-transform pattern=" (roisaen|roisan)" replace=""/>
            PERC_TRANSFORMS.each do |pattern, replacement|
              text.sub!(pattern, replacement)
            end

            if text.index('(')
              spell_name = text[0..text.index('(') - 2]
              # Shorten spell names
              text.sub!(/^#{spell_name}/, DR_ALL_SPELLS[spell_name.strip]) if DR_ALL_SPELLS.include?(spell_name.strip)
            end

            text.gsub!(/  /,' ')
            text.strip!

            # Apply highlight patterns to percWindow text
            HighlightProcessor.apply_highlights(text, @line_colors)

            if PRESET[@current_stream]
              @line_colors.push(start: 0, fg: PRESET[@current_stream][0], bg: PRESET[@current_stream][1],
                               end: text.length)
            end
            # window.add_string(text, @line_colors)
            # @need_update = true
          end
          unless text =~ /^\[server\]: "(?:kill|connect)/
            window.route_string(text, @line_colors, @current_stream)
            @need_update = true
            # Track content sent to stream windows to prevent duplicate to main
            @last_stream_text = text.strip
          end
        elsif @current_stream =~ /^(?:death|logons|thoughts|voln|familiar|assess|ooc|shopWindow|combat|moonWindow|atmospherics)$/
          if (window = @wm.stream[MAIN_STREAM])
            if PRESET[@current_stream]
              @line_colors.push(start: 0, fg: PRESET[@current_stream][0], bg: PRESET[@current_stream][1],
                               end: text.length)
            end
            unless text.empty?
              # Detect movement in stream content too
              @last_was_movement = true if text =~ /^You (?:run|walk|go|swim|climb|crawl|drag|stride|sneak|stalk)\b/

              if @state.need_prompt && !@last_was_movement
                @state.need_prompt = false
                add_prompt(window, @state.prompt_text)
              elsif @state.need_prompt
                @state.need_prompt = false  # Consume but don't display after movement
              end
              window.route_string(text, @line_colors, @current_stream)
              @need_update = true
            end
          end
        end
      elsif (window = @wm.stream[MAIN_STREAM])
        # Skip duplicate content that was already sent to a stream window
        if @last_stream_text && text.strip == @last_stream_text
          @last_stream_text = nil
        else
          # Detect movement messages to suppress following prompts/empty lines
          is_movement = text =~ /^You (?:run|walk|go|swim|climb|crawl|drag|stride|sneak|stalk)\b/

          # Skip prompt after movement
          if @state.need_prompt && !@last_was_movement
            @state.need_prompt = false
            add_prompt(window, @state.prompt_text)
          elsif @state.need_prompt
            @state.need_prompt = false  # Consume but don't display
          end

          window.route_string(text, @line_colors, MAIN_STREAM)
          @need_update = true
          @last_was_movement = true if is_movement
        end
      end
    end
    @line_colors = []
    @open_monsterbold.clear
    @open_preset.clear
    @open_color.clear
  end
end

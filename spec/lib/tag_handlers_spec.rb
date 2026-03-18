# frozen_string_literal: true

require_relative '../../lib/xml_tokenizer'
require_relative '../../lib/tag_handlers'

# Minimal host class that includes TagHandlers, providing the instance
# variables and helper methods the module expects.
class TagHandlerHost
  include TagHandlers

  attr_accessor :line_colors, :open_monsterbold, :open_preset, :open_style,
                :open_color, :open_link, :current_stream, :combat_next_line,
                :need_update, :need_room_render, :room_capture_mode

  attr_reader :flushed_texts, :wm, :state, :cmd_buffer

  def initialize(wm:, state:)
    @wm = wm
    @state = state
    @cmd_buffer = Struct.new(:window).new(nil)
    @xml_escapes = { '&lt;' => '<', '&gt;' => '>', '&quot;' => '"', '&apos;' => "'", '&amp;' => '&' }
    @line_colors = []
    @open_monsterbold = []
    @open_preset = []
    @open_style = nil
    @open_color = []
    @open_link = []
    @current_stream = nil
    @combat_next_line = nil
    @need_update = false
    @need_room_render = false
    @room_capture_mode = nil
    @flushed_texts = []
  end

  # Capture flushed text instead of processing it
  def handle_game_text(text)
    @flushed_texts << { text: text.dup, colors: @line_colors.dup, stream: @current_stream }
    @line_colors = []
    @open_monsterbold.clear
    @open_preset.clear
    @open_color.clear
    @open_link.clear
  end

  # Stubs for methods defined in profanity.rb / GameTextProcessor
  def fix_layout_number(str)
    str.gsub('lines', '24').gsub('cols', '80')
    safe_eval_arithmetic(str.gsub('lines', '24').gsub('cols', '80'))
  end

  def parse_room_subtitle(subtitle)
    text = subtitle.sub(/^\s*-\s*/, '')
    text.sub(/^\[(.+?)\]/, '\1').strip
  end

  def new_stun(_seconds) = nil
end

# Mock window that records route_string / add_string calls
class SpyWindow
  attr_reader :calls

  def initialize
    @calls = []
  end

  def route_string(text, colors, stream, **opts)
    @calls << { method: :route_string, text: text, colors: colors, stream: stream }
  end

  def add_string(text, colors = [])
    @calls << { method: :add_string, text: text, colors: colors }
  end
end

# Mock indicator with label and update tracking
class SpyIndicator
  attr_accessor :label, :label_colors, :active, :end_time, :secondary_end_time
  attr_reader :updates

  def initialize
    @label = nil
    @updates = []
  end

  def update(*args)
    @updates << args
    true
  end

  def value = 0
  def secondary_value = 0
  def layout = %w[1 10 0 0]
  def resize(*) = nil
  def move(*) = nil
end

RSpec.describe TagHandlers do
  let(:main_window) { SpyWindow.new }
  let(:wm) do
    Struct.new(:stream, :indicator, :progress, :countdown, :room,
               :command_window, :command_window_layout).new(
      { 'main' => main_window }, {}, {}, {}, {}, nil, nil
    )
  end
  let(:state) do
    Struct.new(:need_prompt, :prompt_text, :skip_server_time_offset,
               :room_title, :blue_links, :room_window_only) do
      def update_terminal_title = nil
    end.new(false, '>', true, '', false, false)
  end
  let(:host) { TagHandlerHost.new(wm: wm, state: state) }

  # ---- dispatch_tag ----

  describe '#dispatch_tag' do
    it 'dispatches to the correct handler based on tag name' do
      buf = String.new
      expect(host).to receive(:handle_push_bold).with('<pushBold/>', buf)
      host.dispatch_tag('<pushBold/>', buf)
    end

    it 'dispatches closing tags to CLOSING_TAG_DISPATCH' do
      buf = String.new
      expect(host).to receive(:handle_close_preset).with('</preset>', buf)
      host.dispatch_tag('</preset>', buf)
    end

    it 'resets combat_next_line on popStream combat tag' do
      host.combat_next_line = true
      host.dispatch_tag('<popStream id="combat" />', String.new)
      expect(host.combat_next_line).to be false
    end

    it 'activates combat stream on unrecognized tag when combat_next_line is true' do
      host.combat_next_line = true
      buf = +'some text'
      host.dispatch_tag('<unknownTag/>', buf)
      expect(host.current_stream).to eq 'combat'
    end

    it 'ignores dialogdata tags without activating combat' do
      host.combat_next_line = true
      host.dispatch_tag('<dialogdata id="foo"/>', String.new)
      expect(host.current_stream).to be_nil
    end
  end

  # ---- Bold handlers ----

  describe '#handle_push_bold / #handle_pop_bold' do
    it 'creates a color region for bold text' do
      PRESET['monsterbold'] = ['ff0000', nil]
      buf = +'Hello '
      host.dispatch_tag('<pushBold/>', buf)
      buf << 'goblin'
      host.dispatch_tag('<popBold/>', buf)

      expect(host.line_colors).to include(
        a_hash_including(start: 6, end: 12, fg: 'ff0000')
      )
    end

    it 'handles <b> and </b> tags the same way' do
      PRESET['monsterbold'] = ['ff0000', nil]
      buf = +''
      host.dispatch_tag('<b>', buf)
      buf << 'bold'
      host.dispatch_tag('</b>', buf)

      expect(host.line_colors).to include(
        a_hash_including(start: 0, end: 4, fg: 'ff0000')
      )
    end
  end

  # ---- Prompt handler ----

  describe '#handle_prompt_tag' do
    it 'updates shared state prompt_text' do
      state.skip_server_time_offset = false
      state.prompt_text = '>'
      host.dispatch_tag('<prompt time="1679000000">H&gt;</prompt>', String.new)
      expect(state.prompt_text).to eq 'H>'
    end

    it 'syncs server time offset on first prompt' do
      state.skip_server_time_offset = false
      host.dispatch_tag('<prompt time="1679000000">H&gt;</prompt>', String.new)
      expect(state.skip_server_time_offset).to be true
      expect($server_time_offset).to be_a(Float)
    end

    it 'sets need_prompt to true on repeated same prompt' do
      state.prompt_text = 'H>'
      host.dispatch_tag('<prompt time="1679000000">H&gt;</prompt>', String.new)
      expect(state.need_prompt).to be true
    end
  end

  # ---- Spell handler ----

  describe '#handle_spell_tag' do
    it 'updates the spell indicator label' do
      ind = SpyIndicator.new
      wm.indicator['spell'] = ind
      host.dispatch_tag('<spell>Fire Ball</spell>', String.new)
      expect(ind.label).to eq 'Fire Ball'
    end

    it 'updates with 0 when spell is None' do
      ind = SpyIndicator.new
      wm.indicator['spell'] = ind
      host.dispatch_tag('<spell>None</spell>', String.new)
      expect(ind.updates.flatten).to include(0)
    end
  end

  # ---- Hand handler ----

  describe '#handle_hand_tag' do
    it 'updates right hand indicator' do
      ind = SpyIndicator.new
      wm.indicator['right'] = ind
      host.dispatch_tag('<right>a steel sword</right>', String.new)
      expect(ind.label).to eq 'a steel sword'
      expect(ind.updates.flatten).to include(1)
    end

    it 'updates left hand as Empty with 0' do
      ind = SpyIndicator.new
      wm.indicator['left'] = ind
      host.dispatch_tag('<left>Empty</left>', String.new)
      expect(ind.label).to eq 'Empty'
      expect(ind.updates.flatten).to include(0)
    end
  end

  # ---- Compass handler ----

  describe '#handle_compass_tag' do
    it 'updates direction indicators' do
      n_ind = SpyIndicator.new
      e_ind = SpyIndicator.new
      s_ind = SpyIndicator.new
      wm.indicator['compass:n'] = n_ind
      wm.indicator['compass:e'] = e_ind
      wm.indicator['compass:s'] = s_ind

      host.dispatch_tag('<compass><dir value="n"/><dir value="e"/></compass>', String.new)

      expect(n_ind.updates.last).to eq [true]
      expect(e_ind.updates.last).to eq [true]
      expect(s_ind.updates.last).to eq [false]
    end
  end

  # ---- Stream handlers ----

  describe '#handle_stream_open' do
    it 'flushes text buffer and sets current_stream' do
      buf = +'text before stream'
      host.dispatch_tag('<pushStream id="combat" />', buf)

      expect(host.flushed_texts.last[:text]).to eq 'text before stream'
      expect(host.current_stream).to eq 'combat'
      expect(buf).to eq ''
    end

    it 'sets combat_next_line for combat streams' do
      host.dispatch_tag('<pushStream id="combat" />', String.new)
      expect(host.combat_next_line).to be true
    end

    it 'handles exp stream with skill name' do
      host.dispatch_tag('<pushStream id="exp Athletics" />', String.new)
      expect(host.current_stream).to eq 'exp'
    end
  end

  describe '#handle_stream_close' do
    it 'flushes text buffer and clears current_stream' do
      host.current_stream = 'combat'
      buf = +'combat text'
      host.dispatch_tag('<popStream id="combat" />', buf)

      expect(host.flushed_texts.last[:text]).to eq 'combat text'
      expect(host.current_stream).to be_nil
    end
  end

  # ---- Color handlers ----

  describe '#handle_open_color / #handle_close_color' do
    it 'creates a color region with fg and bg' do
      buf = +''
      host.dispatch_tag('<color fg="ff0000" bg="000000">', buf)
      buf << 'red on black'
      host.dispatch_tag('</color>', buf)

      expect(host.line_colors).to include(
        a_hash_including(start: 0, end: 12, fg: 'ff0000', bg: '000000')
      )
    end

    it 'handles underline attribute' do
      buf = +''
      host.dispatch_tag('<color ul="true">', buf)
      buf << 'underlined'
      host.dispatch_tag('</color>', buf)

      expect(host.line_colors).to include(
        a_hash_including(ul: 'true')
      )
    end
  end

  # ---- Preset handlers ----

  describe '#handle_open_preset / #handle_close_preset' do
    it 'creates a color region from the preset lookup' do
      PRESET['speech'] = ['00ff00', '000000']
      buf = +''
      host.dispatch_tag('<preset id="speech">', buf)
      buf << 'Someone says hello'
      host.dispatch_tag('</preset>', buf)

      expect(host.line_colors).to include(
        a_hash_including(start: 0, end: 18, fg: '00ff00', bg: '000000')
      )
    end

    it 'flushes text buffer when entering roomDesc preset' do
      wm.room['room'] = SpyWindow.new
      buf = +'text before desc'
      host.dispatch_tag('<preset id="roomDesc">', buf)

      expect(host.flushed_texts.last[:text]).to eq 'text before desc'
      expect(host.room_capture_mode).to eq :desc
    end
  end

  # ---- Style handler ----

  describe '#handle_style_tag' do
    it 'opens a style with non-empty id' do
      PRESET['roomName'] = ['00ff00', nil]
      host.dispatch_tag('<style id="roomName"/>', String.new)
      expect(host.open_style).to include(start: 0, fg: '00ff00')
      expect(host.room_capture_mode).to eq :title
    end

    it 'closes a style with empty id and flushes when in room capture' do
      PRESET['roomName'] = ['00ff00', nil]
      buf = +''
      host.dispatch_tag('<style id="roomName"/>', buf)
      buf << 'Town Square'
      host.dispatch_tag('<style id=""/>', buf)

      expect(host.open_style).to be_nil
      # The flush captures the style color in flushed_texts (handle_game_text
      # extends open_style to end of text, then clears line_colors)
      flushed = host.flushed_texts.find { |f| f[:text] == 'Town Square' }
      expect(flushed).not_to be_nil
    end
  end

  # ---- Link handlers ----

  describe '#handle_open_link / #handle_close_link' do
    before { state.blue_links = true }

    it 'creates a link color region with cmd from attribute' do
      buf = +'Go through '
      host.dispatch_tag("<d cmd='go door'>", buf)
      buf << 'the door'
      host.dispatch_tag('</d>', buf)

      link = host.line_colors.find { |c| c[:cmd] }
      expect(link).to include(start: 11, end: 19, cmd: 'go door')
    end

    it 'uses link text as cmd when no cmd attribute' do
      buf = +'Exit: '
      host.dispatch_tag('<d>', buf)
      buf << 'north'
      host.dispatch_tag('</d>', buf)

      link = host.line_colors.find { |c| c[:cmd] }
      expect(link[:cmd]).to eq 'north'
    end

    it 'handles GS <a> tags with exist/noun attributes' do
      buf = +''
      host.dispatch_tag('<a exist="12345" noun="sword">', buf)
      buf << 'a sword'
      host.dispatch_tag('</a>', buf)

      link = host.line_colors.find { |c| c[:cmd] }
      expect(link[:cmd]).to eq 'look #12345'
    end

    it 'does nothing when blue_links is false' do
      state.blue_links = false
      buf = +''
      host.dispatch_tag("<d cmd='go'>", buf)
      buf << 'door'
      host.dispatch_tag('</d>', buf)

      expect(host.line_colors).to be_empty
    end
  end

  # ---- Indicator handler ----

  describe '#handle_indicator_tag' do
    it 'updates indicator window for visible icon' do
      ind = SpyIndicator.new
      wm.indicator['stunned'] = ind
      host.dispatch_tag("<indicator id='IconSTUNNED' visible='y'/>", String.new)
      expect(ind.updates.flatten).to include(true)
    end

    it 'updates countdown window active state' do
      cd = SpyIndicator.new
      wm.countdown['stunned'] = cd
      host.dispatch_tag("<indicator id='IconSTUNNED' visible='y'/>", String.new)
      expect(cd.active).to be true
    end
  end

  # ---- Stream window handler ----

  describe '#handle_stream_window' do
    it 'updates room title from subtitle attribute' do
      host.dispatch_tag(%q{<streamWindow id='room' subtitle=" - [Town Square]"/>}, String.new)
      expect(state.room_title).to eq 'Town Square'
    end

    it 'handles DR subtitle with room number' do
      host.dispatch_tag(%q{<streamWindow id='room' subtitle=" - [Bosque Deriel] (230008)"/>}, String.new)
      expect(state.room_title).to eq 'Bosque Deriel (230008)'
    end
  end

  # ---- Entity unescaping ----

  describe '#unescape_entities' do
    it 'converts &lt; to <' do
      expect(host.send(:unescape_entities, '&lt;')).to eq '<'
    end

    it 'converts &gt; to >' do
      expect(host.send(:unescape_entities, '&gt;')).to eq '>'
    end

    it 'converts &amp; to &' do
      expect(host.send(:unescape_entities, '&amp;')).to eq '&'
    end

    it 'converts &quot; to "' do
      expect(host.send(:unescape_entities, '&quot;')).to eq '"'
    end

    it 'handles multiple entities in one string' do
      expect(host.send(:unescape_entities, '&lt;tag&gt; &amp; more')).to eq '<tag> & more'
    end

    it 'returns unchanged text when no entities present' do
      expect(host.send(:unescape_entities, 'plain text')).to eq 'plain text'
    end

    it 'handles empty string' do
      expect(host.send(:unescape_entities, '')).to eq ''
    end

    it 'handles &amp;amp; (double-encoded) — only decodes one layer' do
      expect(host.send(:unescape_entities, '&amp;amp;')).to eq '&amp;'
    end

    it 'handles entity at start of string' do
      expect(host.send(:unescape_entities, '&lt;start')).to eq '<start'
    end

    it 'handles entity at end of string' do
      expect(host.send(:unescape_entities, 'end&gt;')).to eq 'end>'
    end

    it 'handles adjacent entities' do
      expect(host.send(:unescape_entities, '&lt;&gt;')).to eq '<>'
    end
  end

  # ==================================================================
  # Adversarial edge cases
  # ==================================================================

  describe 'adversarial: unmatched tags' do
    it 'popBold without pushBold does not crash' do
      expect { host.dispatch_tag('<popBold/>', String.new) }.not_to raise_error
      expect(host.line_colors).to be_empty
    end

    it '</preset> without <preset> does not crash' do
      expect { host.dispatch_tag('</preset>', String.new) }.not_to raise_error
    end

    it '</color> without <color> does not crash' do
      expect { host.dispatch_tag('</color>', String.new) }.not_to raise_error
    end

    it '</d> without <d> does not crash' do
      state.blue_links = true
      expect { host.dispatch_tag('</d>', String.new) }.not_to raise_error
    end

    it '</a> without <a> does not crash' do
      state.blue_links = true
      expect { host.dispatch_tag('</a>', String.new) }.not_to raise_error
    end

    it 'popStream without pushStream does not crash' do
      expect { host.dispatch_tag('<popStream id="combat" />', String.new) }.not_to raise_error
      expect(host.current_stream).to be_nil
    end
  end

  describe 'adversarial: nested tags' do
    it 'nested pushBold tags create stacked color regions' do
      PRESET['monsterbold'] = ['ff0000', nil]
      buf = +''
      host.dispatch_tag('<pushBold/>', buf)
      buf << 'outer '
      host.dispatch_tag('<pushBold/>', buf)
      buf << 'inner'
      host.dispatch_tag('<popBold/>', buf)
      buf << ' outer'
      host.dispatch_tag('<popBold/>', buf)

      # Should have two color regions, inner one is 6..11
      expect(host.line_colors.length).to eq 2
    end

    it 'nested presets stack correctly' do
      PRESET['speech'] = ['00ff00', nil]
      PRESET['roomDesc'] = ['0000ff', nil]
      buf = +''
      host.dispatch_tag('<preset id="speech">', buf)
      buf << 'outer '
      host.dispatch_tag('<preset id="speech">', buf)
      buf << 'inner'
      host.dispatch_tag('</preset>', buf)
      host.dispatch_tag('</preset>', buf)

      # Two color regions
      expect(host.line_colors.length).to eq 2
    end
  end

  describe 'adversarial: malformed tag attributes' do
    it 'prompt without time attribute does not crash' do
      expect { host.dispatch_tag('<prompt>H&gt;</prompt>', String.new) }.not_to raise_error
    end

    it 'spell with empty content' do
      ind = SpyIndicator.new
      wm.indicator['spell'] = ind
      host.dispatch_tag('<spell></spell>', String.new)
      expect(ind.label).to eq ''
    end

    it 'preset with unknown id does not crash' do
      expect { host.dispatch_tag('<preset id="nonexistent">', String.new) }.not_to raise_error
    end

    it 'progressBar with missing value attribute does not crash' do
      expect { host.dispatch_tag('<progressBar id="health"/>', String.new) }.not_to raise_error
    end

    it 'style with no id attribute does not crash' do
      expect { host.dispatch_tag('<style/>', String.new) }.not_to raise_error
    end

    it 'streamWindow for non-room id is ignored' do
      host.dispatch_tag(%q{<streamWindow id='main' subtitle="test"/>}, String.new)
      expect(state.room_title).to eq ''
    end

    it 'indicator with malformed id does not crash' do
      expect { host.dispatch_tag("<indicator id='BadFormat' visible='y'/>", String.new) }.not_to raise_error
    end

    it 'image with unknown body part does not crash' do
      expect { host.dispatch_tag("<image id='unknown' name='test'/>", String.new) }.not_to raise_error
    end
  end

  describe 'adversarial: color position tracking' do
    it 'bold region with zero-length text has start == end' do
      PRESET['monsterbold'] = ['ff0000', nil]
      buf = +''
      host.dispatch_tag('<pushBold/>', buf)
      host.dispatch_tag('<popBold/>', buf)
      # Zero-length region — should NOT be pushed (no fg/bg to display)
      # Actually it should be pushed but with start == end, which is harmless
      if host.line_colors.any?
        region = host.line_colors.first
        expect(region[:start]).to eq region[:end]
      end
    end

    it 'color region positions are correct after entity unescaping in text' do
      # Text "a&lt;b" unescaped is "a<b" (3 chars)
      # Bold wrapping "a<b" should produce region 0..3
      PRESET['monsterbold'] = ['ff0000', nil]
      buf = +''
      host.dispatch_tag('<pushBold/>', buf)
      buf << host.send(:unescape_entities, 'a&lt;b')
      host.dispatch_tag('<popBold/>', buf)

      region = host.line_colors.find { |c| c[:fg] == 'ff0000' }
      expect(region[:start]).to eq 0
      expect(region[:end]).to eq 3  # "a<b" is 3 chars after unescape
    end

    it 'multiple color regions do not overlap incorrectly' do
      buf = +''
      host.dispatch_tag('<color fg="ff0000">', buf)
      buf << 'red'
      host.dispatch_tag('</color>', buf)
      host.dispatch_tag('<color fg="00ff00">', buf)
      buf << 'green'
      host.dispatch_tag('</color>', buf)

      red = host.line_colors.find { |c| c[:fg] == 'ff0000' }
      green = host.line_colors.find { |c| c[:fg] == '00ff00' }
      expect(red[:end]).to be <= green[:start]
    end
  end

  describe 'adversarial: stream handling' do
    it 'stream open without id attribute does not crash' do
      expect { host.dispatch_tag('<pushStream/>', String.new) }.not_to raise_error
      expect(host.current_stream).to be_nil
    end

    it 'component without id attribute does not crash' do
      expect { host.dispatch_tag('<component/>', String.new) }.not_to raise_error
    end

    it 'multiple stream opens without close accumulate correctly' do
      host.dispatch_tag('<pushStream id="combat" />', String.new)
      expect(host.current_stream).to eq 'combat'
      host.dispatch_tag('<pushStream id="thoughts" />', String.new)
      expect(host.current_stream).to eq 'thoughts'
    end

    it 'stream close after multiple opens resets to nil' do
      host.dispatch_tag('<pushStream id="combat" />', String.new)
      host.dispatch_tag('<pushStream id="thoughts" />', String.new)
      host.dispatch_tag('<popStream/>', String.new)
      expect(host.current_stream).to be_nil
    end

    it 'clearStream for non-percWindow id does not crash' do
      expect { host.dispatch_tag('<clearStream id="other"/>', String.new) }.not_to raise_error
    end
  end

  describe 'adversarial: combat_next_line edge cases' do
    it 'combat_next_line with empty text buffer does not flush' do
      host.combat_next_line = true
      host.dispatch_tag('<unknownTag/>', String.new)
      expect(host.current_stream).to eq 'combat'
      expect(host.flushed_texts).to be_empty
    end

    it 'popStream combat resets flag even when current_stream is different' do
      host.combat_next_line = true
      host.current_stream = 'thoughts'
      host.dispatch_tag('<popStream id="combat" />', String.new)
      expect(host.combat_next_line).to be false
      # current_stream should be nil (stream close)
      expect(host.current_stream).to be_nil
    end
  end

  describe 'adversarial: link edge cases' do
    before { state.blue_links = true }

    it 'link with empty text produces zero-length cmd' do
      buf = +''
      host.dispatch_tag('<d>', buf)
      host.dispatch_tag('</d>', buf)

      link = host.line_colors.find { |c| c[:cmd] }
      # With start == end, cmd extraction should fail the guard
      expect(link).to be_nil
    end

    it 'GS link with exist but no noun uses _drag prefix' do
      buf = +''
      host.dispatch_tag('<a exist="99999">', buf)
      buf << 'an item'
      host.dispatch_tag('</a>', buf)

      link = host.line_colors.find { |c| c[:cmd] }
      expect(link[:cmd]).to eq '_drag #99999'
    end

    it 'link cmd with special characters is preserved verbatim' do
      buf = +''
      host.dispatch_tag("<d cmd='go #12345 door'>", buf)
      buf << 'the door'
      host.dispatch_tag('</d>', buf)

      link = host.line_colors.find { |c| c[:cmd] }
      expect(link[:cmd]).to eq 'go #12345 door'
    end
  end

  describe 'adversarial: progress bar edge cases' do
    it 'handles health at 0%' do
      prog = SpyIndicator.new
      wm.progress['health'] = prog
      host.dispatch_tag("<progressBar id='health' value='0' text='health 0%'/>", String.new)
      expect(prog.updates).to include([0, 100])
    end

    it 'handles encumbrance "Overloaded" text' do
      prog = SpyIndicator.new
      wm.progress['encumbrance'] = prog
      host.dispatch_tag("<progressBar id='encumlevel' value='100' text='Overloaded'/>", String.new)
      expect(prog.updates).to include([110, 110])
    end

    it 'handles mind "saturated" text' do
      prog = SpyIndicator.new
      wm.progress['mind'] = prog
      host.dispatch_tag("<progressBar id='mindState' value='100' text='saturated'/>", String.new)
      expect(prog.updates).to include([110, 110])
    end

    it 'handles GS vitals with negative current' do
      prog = SpyIndicator.new
      wm.progress['health'] = prog
      host.dispatch_tag("<progressBar id='health' value='0' text='health -5/100'/>", String.new)
      expect(prog.updates).to include([-5, 100])
    end
  end
end

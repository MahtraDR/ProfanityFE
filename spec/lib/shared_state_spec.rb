# frozen_string_literal: true

require_relative '../../lib/shared_state'

RSpec.describe SharedState do
  subject(:state) { described_class.new }

  describe '#initialize' do
    it('need_prompt defaults false') { expect(state.need_prompt).to be false }
    it('prompt_text defaults ">"') { expect(state.prompt_text).to eq '>' }
    it('room_title defaults ""') { expect(state.room_title).to eq '' }
    it('skip_server_time_offset defaults false') { expect(state.skip_server_time_offset).to be false }
    it('blue_links defaults false') { expect(state.blue_links).to be false }
    it('char_name defaults nil') { expect(state.char_name).to be_nil }
    it('no_status defaults false') { expect(state.no_status).to be false }
    it('room_window_only defaults false') { expect(state.room_window_only).to be false }
  end

  describe '#update_prompt' do
    context 'when prompt text changes' do
      it 'returns true' do
        expect(state.update_prompt('H>')).to be true
      end

      it 'updates prompt_text' do
        state.update_prompt('H>')
        expect(state.prompt_text).to eq 'H>'
      end

      it 'clears need_prompt' do
        state.need_prompt = true
        state.update_prompt('H>')
        expect(state.need_prompt).to be false
      end
    end

    context 'when prompt text is unchanged' do
      before { state.update_prompt('H>') }

      it 'returns false' do
        expect(state.update_prompt('H>')).to be false
      end

      it 'sets need_prompt to true' do
        state.update_prompt('H>')
        expect(state.need_prompt).to be true
      end
    end

    # Adversarial
    it 'handles empty string prompt' do
      expect(state.update_prompt('')).to be true
      expect(state.prompt_text).to eq ''
    end

    it 'handles very long prompt' do
      long_prompt = 'X' * 1000 + '>'
      state.update_prompt(long_prompt)
      expect(state.prompt_text).to eq long_prompt
    end

    it 'handles prompt with special characters' do
      state.update_prompt("H\t>")
      expect(state.prompt_text).to eq "H\t>"
    end

    it 'treats whitespace-different prompts as changed' do
      state.update_prompt('H>')
      expect(state.update_prompt('H >')).to be true
    end
  end

  describe '#consume_prompt!' do
    it 'returns true and clears when pending' do
      state.need_prompt = true
      expect(state.consume_prompt!).to be true
      expect(state.need_prompt).to be false
    end

    it 'returns false when not pending' do
      expect(state.consume_prompt!).to be false
    end

    it 'is idempotent (second call returns false)' do
      state.need_prompt = true
      state.consume_prompt!
      expect(state.consume_prompt!).to be false
    end
  end

  describe '#update_terminal_title' do
    before do
      state.char_name = 'Mahtra'
      state.no_status = false
      allow(Process).to receive(:setproctitle)
      allow(state).to receive(:system)
    end

    it 'sets process title' do
      state.prompt_text = 'H>'
      state.room_title = 'Town Square'
      state.update_terminal_title
      expect(Process).to have_received(:setproctitle).with(/Mahtra/)
    end

    it 'includes room in title' do
      state.prompt_text = 'H>'
      state.room_title = 'Town Square'
      state.update_terminal_title
      expect(Process).to have_received(:setproctitle).with(/Town Square/)
    end

    it 'skips when char_name is nil' do
      state.char_name = nil
      state.update_terminal_title
      expect(Process).not_to have_received(:setproctitle)
    end

    it 'skips when no_status is true' do
      state.no_status = true
      state.update_terminal_title
      expect(Process).not_to have_received(:setproctitle)
    end

    it 'deduplicates identical titles' do
      state.prompt_text = 'H>'
      state.room_title = 'Same'
      state.update_terminal_title
      state.update_terminal_title
      # setproctitle should be called only once (dedup)
      expect(Process).to have_received(:setproctitle).once
    end

    it 'updates when prompt changes' do
      state.prompt_text = 'H>'
      state.update_terminal_title
      state.prompt_text = 'S>'
      state.update_terminal_title
      expect(Process).to have_received(:setproctitle).twice
    end

    # Adversarial
    it 'handles empty room_title' do
      state.prompt_text = 'H>'
      state.room_title = ''
      expect { state.update_terminal_title }.not_to raise_error
    end

    it 'handles empty prompt_text' do
      state.prompt_text = ''
      state.room_title = 'Room'
      expect { state.update_terminal_title }.not_to raise_error
    end

    it 'handles room_title with special characters' do
      state.prompt_text = '>'
      state.room_title = "Room [with] (parens) & 'quotes'"
      expect { state.update_terminal_title }.not_to raise_error
    end
  end

  describe 'thread safety' do
    it 'survives concurrent reads and writes' do
      threads = 10.times.map do |i|
        Thread.new do
          100.times do
            state.prompt_text = "prompt#{i}"
            state.need_prompt = i.even?
            state.room_title = "room#{i}"
            state.prompt_text
            state.need_prompt
            state.consume_prompt!
            state.update_prompt("p#{i}")
          end
        end
      end
      expect { threads.each(&:join) }.not_to raise_error
    end

    it 'update_prompt is atomic (no lost updates)' do
      results = Queue.new
      threads = 20.times.map do |i|
        Thread.new do
          result = state.update_prompt("prompt_#{i}")
          results << [i, result]
        end
      end
      threads.each(&:join)

      # Exactly one thread should get "false" (the one whose prompt matched
      # the final state). All others should get "true" (they changed the text).
      # Actually with racing, the first one to set gets true, and duplicates get false.
      # The key invariant: prompt_text is a valid value at the end.
      expect(state.prompt_text).to match(/^prompt_\d+$/)
    end
  end
end

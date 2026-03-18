# frozen_string_literal: true

# Load the REAL GagPatterns module (replaces the spec_helper stub)
original_verbose = $VERBOSE
$VERBOSE = nil
require_relative '../../lib/gag_patterns'
$VERBOSE = original_verbose

RSpec.describe GagPatterns do
  before(:each) { described_class.load_defaults }

  describe '.load_defaults' do
    it 'creates regexps that match nothing' do
      expect('anything').not_to match(described_class.combat_regexp)
      expect('anything').not_to match(described_class.general_regexp)
    end

    it 'clears patterns added before load_defaults' do
      described_class.add_general_pattern('test')
      described_class.load_defaults
      expect('test').not_to match(described_class.general_regexp)
    end
  end

  describe '.add_combat_pattern' do
    it 'pattern matches against combat text' do
      described_class.add_combat_pattern('swings a sword')
      expect('A goblin swings a sword at you').to match(described_class.combat_regexp)
    end

    it 'does not bleed into general patterns' do
      described_class.add_combat_pattern('swings')
      expect('swings').not_to match(described_class.general_regexp)
    end

    it 'accepts Regexp objects' do
      described_class.add_combat_pattern(/miss(es)?/i)
      expect('The goblin MISSES').to match(described_class.combat_regexp)
    end

    # String patterns are intentionally treated as regex — the module doc
    # example uses 'You also see .* moth' and XML <gag> elements contain
    # regex patterns, not literal strings. This means metacharacters like
    # () are active. Users who want literal parens must escape them.
    it 'treats string patterns as regex (metacharacters are active)' do
      described_class.add_combat_pattern('attack (melee|ranged)')
      expect('attack melee').to match(described_class.combat_regexp)
      expect('attack ranged').to match(described_class.combat_regexp)
      expect('attack magic').not_to match(described_class.combat_regexp)
    end

    it 'users can escape metacharacters for literal matching' do
      described_class.add_combat_pattern('attack \\(melee\\)')
      expect('attack (melee)').to match(described_class.combat_regexp)
      expect('attack melee').not_to match(described_class.combat_regexp)
    end

    it 'warns on invalid regex and does not add it' do
      expect {
        described_class.add_combat_pattern('[unclosed')
      }.to output(/Invalid combat gag pattern/).to_stderr
      expect('[unclosed').not_to match(described_class.combat_regexp)
    end

    it 'accumulates multiple patterns' do
      described_class.add_combat_pattern('sword')
      described_class.add_combat_pattern('axe')
      expect('sword').to match(described_class.combat_regexp)
      expect('axe').to match(described_class.combat_regexp)
      expect('bow').not_to match(described_class.combat_regexp)
    end

    # Adversarial
    it 'handles pattern that matches empty string' do
      described_class.add_combat_pattern('.*')
      expect('').to match(described_class.combat_regexp)
    end

    it 'handles pattern with anchors' do
      described_class.add_combat_pattern('^start')
      expect('start of line').to match(described_class.combat_regexp)
      expect('not start').not_to match(described_class.combat_regexp)
    end
  end

  describe '.add_general_pattern' do
    it 'matches general text' do
      described_class.add_general_pattern('You also see .* moth')
      expect('You also see a large moth').to match(described_class.general_regexp)
    end

    it 'does not bleed into combat patterns' do
      described_class.add_general_pattern('moth')
      expect('moth').not_to match(described_class.combat_regexp)
    end

    # Adversarial
    it 'handles unicode in patterns' do
      described_class.add_general_pattern('café')
      expect('a café appears').to match(described_class.general_regexp)
    end
  end

  describe '.clear_custom' do
    it 'removes all custom patterns from both sets' do
      described_class.add_combat_pattern('sword')
      described_class.add_general_pattern('moth')
      described_class.clear_custom
      expect('sword').not_to match(described_class.combat_regexp)
      expect('moth').not_to match(described_class.general_regexp)
    end

    it 'is idempotent' do
      described_class.clear_custom
      described_class.clear_custom
      expect('test').not_to match(described_class.general_regexp)
    end

    it 'allows re-adding patterns after clear' do
      described_class.add_general_pattern('old')
      described_class.clear_custom
      described_class.add_general_pattern('new')
      expect('old').not_to match(described_class.general_regexp)
      expect('new').to match(described_class.general_regexp)
    end
  end

  describe 'Regexp.union behavior edge cases' do
    it 'empty union matches nothing (not everything)' do
      described_class.load_defaults
      expect('').not_to match(described_class.general_regexp)
      expect('anything').not_to match(described_class.general_regexp)
    end

    it 'union with one pattern behaves like that pattern' do
      described_class.add_general_pattern('exact')
      expect('exact').to match(described_class.general_regexp)
      expect('inexact').to match(described_class.general_regexp) # substring match
      expect('other').not_to match(described_class.general_regexp)
    end
  end
end

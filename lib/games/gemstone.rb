# frozen_string_literal: true

=begin
GemStone IV-specific game text processing.
Placeholder for future GS support — death area codes, GS logon patterns,
GS spell abbreviations, etc.
=end

# GemStone IV-specific text processing rules (stub).
#
# Future: will contain GS death message formatting (area codes like ZUL, REIM),
# GS logon patterns ("joins the adventure.", "returns home", "has disconnected"),
# GS Raise Dead stun detection, and GS spell abbreviations.
module Games
  module GemStone
    # GS logon/logoff patterns (subset — GS has fewer variants than DR).
    LOGON_PATTERNS = {
      'joins the adventure.' => '007700',
      'returns home from a hard day of adventuring.' => '777700',
      'has disconnected.' => 'aa7733'
    }.freeze

    # Abbreviate a GS spell name (stub — returns original name).
    #
    # @param spell_name [String] full spell name
    # @return [String] the original name (no GS abbreviation table yet)
    def abbreviate_spell(spell_name)
      spell_name
    end
  end
end

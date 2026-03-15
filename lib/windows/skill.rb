# frozen_string_literal: true

# Skill data object for experience tracking in the {ExpWindow}.

# Value object representing a single skill's training state.
#
# Stores the skill name, rank count, rank percentage, and current
# mindstate. Provides a fixed-width {#to_s} suitable for columnar
# display in {ExpWindow}.
class Skill
  # Create a new Skill snapshot.
  #
  # @param name [String] skill name (e.g. "Evasion")
  # @param ranks [Integer, String] total ranks earned
  # @param percent [Integer, String] percentage toward next rank
  # @param mindstate [Integer, String] current mindstate (0-34)
  def initialize(name, ranks, percent, mindstate)
    @name = name
    @ranks = ranks
    @percent = percent
    @mindstate = mindstate
  end

  # Format the skill as a fixed-width columnar string.
  #
  # @return [String] e.g. "  Evasion:  123 45% [12/34]"
  def to_s
    format('%8s:%5d %2s%% [%2s/34]', @name, @ranks, @percent, @mindstate)
  end
end

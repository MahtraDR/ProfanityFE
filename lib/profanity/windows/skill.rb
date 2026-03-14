# frozen_string_literal: true

# Skill data class for experience tracking

class Skill
  def initialize(name, ranks, percent, mindstate)
    @name = name
    @ranks = ranks
    @percent = percent
    @mindstate = mindstate
  end

  def to_s
    format('%8s:%5d %2s%% [%2s/34]', @name, @ranks, @percent, @mindstate)
  end
end

# frozen_string_literal: true

=begin
gag_patterns.rb: Gag pattern management for filtering unwanted text from display.
Patterns loaded from XML config via <gag> and <combat_gag> elements.
=end

# Manages gag patterns that filter unwanted text from the display.
# Patterns can be loaded from the XML config file or added programmatically.
# Maintains two separate pattern sets: general (all streams) and combat.
#
# @example
#   GagPatterns.load_defaults
#   GagPatterns.add_general_pattern('You also see .* moth')
#   GagPatterns.general_regexp  # => /(?-mix:You also see .* moth)/
module GagPatterns
  @combat_patterns = []
  @general_patterns = []
  @combat_regexp = nil
  @general_regexp = nil

  class << self
    # @return [Regexp] combined regexp matching any combat gag pattern
    attr_reader :combat_regexp

    # @return [Regexp] combined regexp matching any general gag pattern
    attr_reader :general_regexp

    # Initialize with default patterns (empty). Call at startup.
    #
    # @return [void]
    def load_defaults
      @combat_patterns = default_combat_patterns.dup
      @general_patterns = default_general_patterns.dup
      rebuild_regexps
    end

    # Add a combat stream gag pattern.
    #
    # @param pattern [String, Regexp] pattern to match against combat text
    # @return [void]
    # @raise [RegexpError] logged as warning if pattern string is invalid
    def add_combat_pattern(pattern)
      regexp = pattern.is_a?(Regexp) ? pattern : Regexp.new(pattern)
      @combat_patterns << regexp
      rebuild_regexps
    rescue RegexpError => e
      warn "Invalid combat gag pattern: #{pattern} - #{e.message}"
    end

    # Add a general gag pattern (applies to all streams).
    #
    # @param pattern [String, Regexp] pattern to match against incoming text
    # @return [void]
    # @raise [RegexpError] logged as warning if pattern string is invalid
    def add_general_pattern(pattern)
      regexp = pattern.is_a?(Regexp) ? pattern : Regexp.new(pattern)
      @general_patterns << regexp
      rebuild_regexps
    rescue RegexpError => e
      warn "Invalid gag pattern: #{pattern} - #{e.message}"
    end

    # Reset to default patterns, discarding any custom patterns.
    # Called during settings reload to re-apply patterns from XML.
    #
    # @return [void]
    def clear_custom
      @combat_patterns = default_combat_patterns.dup
      @general_patterns = default_general_patterns.dup
      rebuild_regexps
    end

    private

    # Rebuild the union regexps from the current pattern arrays.
    #
    # @return [void]
    # @api private
    def rebuild_regexps
      @combat_regexp = Regexp.union(@combat_patterns)
      @general_regexp = Regexp.union(@general_patterns)
    end

    # @return [Array<Regexp>] default combat gag patterns (empty)
    # @api private
    def default_combat_patterns
      []
    end

    # @return [Array<Regexp>] default general gag patterns (empty)
    # @api private
    def default_general_patterns
      []
    end
  end
end

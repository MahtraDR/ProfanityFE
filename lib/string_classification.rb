# frozen_string_literal: true

=begin
String classification refinement for character-type checking.
Used by CommandBuffer for word-boundary detection in readline-style editing.
=end

# Adds character classification methods to String via refinement.
#
# @example
#   using StringClassification
#   "abc".alnum?  #=> true
#   "123".digits? #=> true
#   "!@#".punct?  #=> true
module StringClassification
  refine String do
    # @return [Boolean] true if all characters are alphanumeric
    def alnum?
      !!match(/^[[:alnum:]]+$/)
    end

    # @return [Boolean] true if all characters are digits
    def digits?
      !!match(/^[[:digit:]]+$/)
    end

    # @return [Boolean] true if all characters are punctuation
    def punct?
      !!match(/^[[:punct:]]+$/)
    end

    # @return [Boolean] true if all characters are whitespace
    def space?
      !!match(/^[[:space:]]+$/)
    end
  end
end

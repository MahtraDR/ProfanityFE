# frozen_string_literal: true

=begin
Shared logging utility for ProfanityFE.
Provides a single method to append log messages to the log file,
with graceful fallback to $stderr if the file is not writable.
=end

# Centralized logging for ProfanityFE.
#
# Replaces the duplicated File.open/rescue pattern found throughout
# the codebase with a single utility method.
#
# @example
#   ProfanityLog.write('autocomplete', 'no suggestions found')
module ProfanityLog
  # Write a message to the log file, falling back to $stderr on failure.
  #
  # @param context [String] source identifier (e.g., 'autocomplete', 'mouse')
  # @param message [String] the log message
  # @param backtrace [Array<String>, nil] optional backtrace lines to append
  # @return [void]
  def self.write(context, message, backtrace: nil)
    File.open(LOG_FILE, 'a') do |f|
      f.puts "[#{context}] #{message}"
      backtrace&.first(BACKTRACE_LIMIT)&.each { |line| f.puts line }
    end
  rescue StandardError
    $stderr.puts "[#{context}] #{message}"
  end
end

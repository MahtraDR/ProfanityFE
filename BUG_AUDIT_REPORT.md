# Mahtra-ProfanityFE Bug Audit Report

Date: 2026-03-15
Auditors: 4 parallel agents + expert Ruby verification

4 agents produced ~100 raw findings. After deduplication, expert Ruby
verification (including running code to test edge cases), and GIL analysis,
the findings reduce to 4 real bugs + 3 nice-to-have improvements.

---

## REAL BUGS (confirmed with Ruby verification)

### BUG-1: Undefined variables in color tag parsing [CRASH]
- **File**: lib/game_text_processor.rb:322-325
- **Impact**: NameError crash when game sends `<color fg='...' bg='...'>` XML tags
- **Root cause**: `xml.match()` return value is never captured:
  ```ruby
  # BROKEN: fg_match is never defined
  h[:fg] = fg_match[:val].downcase if xml.match(/\sfg=(?<q>'|")(?<val>.*?)\k<q>[\s>]/)
  ```
- **Fix**: Capture each match result:
  ```ruby
  if (fg_match = xml.match(/\sfg=(?<q>'|")(?<val>.*?)\k<q>[\s>]/))
    h[:fg] = fg_match[:val].downcase
  end
  ```
  Same for bg_match and ul_match.
- **Verified**: YES — `fg_match` is never assigned. Ruby raises NameError.

### BUG-2: Bad XML config cascades to crash at startup [CRASH on bad config]
- **File**: profanity.rb:656-658
- **Impact**: Malformed user XML → SettingsLoader catches exception → LAYOUT stays
  empty → `load_layout('default')` warns and returns → `cmd_buffer.window` stays nil
  → `cmd_buffer.window.getch` at line 697 raises NoMethodError
- **Fix**: Add startup validation after settings load:
  ```ruby
  SettingsLoader.load(SETTINGS_FILENAME, key_binding, key_action, do_macro)
  if LAYOUT.empty?
    $stderr.puts "ERROR: No layouts found in #{SETTINGS_FILENAME}."
    $stderr.puts "Check for malformed XML (unclosed tags, encoding errors)."
    exit 1
  end
  window_mgr.load_layout('default')
  cmd_buffer.window = window_mgr.command_window
  unless cmd_buffer.window
    $stderr.puts "ERROR: Layout has no command window. Add <window class='command'/> to your layout."
    exit 1
  end
  ```
- **Verified**: YES — confirmed the cascade: bad XML → empty LAYOUT → nil window → crash.

### BUG-3: Nonexistent key action references silently ignored [SILENT FAILURE]
- **File**: lib/settings_loader.rb:137
- **Impact**: If user XML has `<key id="F1" action="halp"/>` (typo), no binding is
  created and no warning is shown. User has no idea why the key doesn't work.
- **Root cause**: `key_action['halp']` returns nil, the `&&` short-circuits, the
  `elsif` falls through silently.
- **Fix**: Add a warning when action lookup fails:
  ```ruby
  elsif xml.attributes['action']
    action = key_action[xml.attributes['action']]
    if action
      current_binding[final_key] = action
    else
      ProfanityLog.write('settings', "Unknown action '#{xml.attributes['action']}' for key '#{xml.attributes['id']}'")
    end
  ```
- **Verified**: YES — `key_action[bad_name]` returns nil, `&&` fails silently.

### BUG-4: Spell name extraction with Regexp.escape missing [POTENTIAL CRASH]
- **File**: lib/game_text_processor.rb:683
- **Impact**: If a spell name contains regex metacharacters (e.g., `Fire (+3)`),
  `Regexp.new("^Fire (+3)")` raises RegexpError.
- **Root cause**: `text.sub!(/^#{spell_name}/, ...)` interpolates raw spell name
  into a regex without escaping.
- **Fix**:
  ```ruby
  text.sub!(/^#{Regexp.escape(spell_name)}/, abbreviate_spell(spell_name))
  ```
- **Verified**: YES — DR spell names don't currently contain metacharacters, but
  this is a correctness issue that would crash on edge-case data.

---

## NICE-TO-HAVE IMPROVEMENTS (not bugs, but cleaner code)

### IMP-1: Timer threads could capture window reference locally
- **File**: lib/game_text_processor.rb:225-239, 246-259
- **Current**: Roundtime/casttime threads re-lookup `@wm.countdown['roundtime']`
  on every iteration. If layout reloads, the lookup returns nil → NoMethodError
  → caught by `rescue StandardError` → thread exits cleanly with a log entry.
- **Impact**: Spurious log entries after `.layout` command. Not a crash.
- **Improvement**: Capture window reference once (like the stun thread already does):
  ```ruby
  Thread.new do
    rt_window = @wm.countdown['roundtime']
    next unless rt_window
    while rt_window.end_time == temp_roundtime_end && rt_window.value > 0
      ...
    end
  ```
  Eliminates spurious log entries. Follows existing stun thread pattern.

### IMP-2: SCROLL_WINDOW rotation could be synchronized
- **File**: profanity.rb:560
- **Current**: `SCROLL_WINDOW.push(SCROLL_WINDOW.shift)` without mutex. Under MRI
  Ruby's GIL, array operations are effectively atomic. Server thread uses safe
  navigation (`SCROLL_WINDOW[0]&.scroll`), so nil between shift/push is handled.
- **Impact**: No crash in MRI Ruby. Would be a bug in JRuby/TruffleRuby.
- **Improvement**: Wrap in CURSES_MUTEX for correctness and future-proofing.

### IMP-3: CountdownWindow secondary slice could use max()
- **File**: lib/windows/countdown_window.rb:76
- **Current**: `str[left.length, (@secondary_value - @value)]` — when secondary < value,
  the negative length produces nil, `.to_s` gives `""`, and `unless .empty?` skips it.
- **Impact**: No visible bug — the empty string is correctly skipped. But the intent
  is unclear and relies on Ruby's nil.to_s behavior.
- **Improvement**: `[(@secondary_value - @value), 0].max` makes the intent explicit.

---

## FALSE POSITIVES (removed from original report)

| Original Bug | Why it's NOT a bug |
|---|---|
| SinkWindow cleanup leak | SinkWindow is a plain Ruby object (no Curses resources). GC collects when @stream hash is replaced. No leak. |
| ColorManager pair exhaustion | `@color_pair_history` is a circular buffer (shift front, push back). Can never become empty. |
| CountdownWindow "nil" rendering | `nil.to_s` returns `""` (empty string), not literal "nil". The `unless .empty?` guard correctly skips it. |
| HIGHLIGHT hash race during .reload | Both `apply_highlights` and `SettingsLoader.load` hold `SETTINGS_LOCK`. No race possible. |
| Window handler hash access without mutex | MRI GIL makes reference reads atomic. `rescue StandardError` in `run()` catches any closed-window errors. |
| HighlightProcessor regex exception | Exception propagates out of `synchronize` (lock released), caught by `rescue StandardError` in `run()`. Not a crash. |
| Timer thread stale refs | `NoMethodError` on nil window is caught by `rescue StandardError`. Thread exits cleanly. Not a crash (just a log entry). |
| parse_player_names global method | Top-level methods become private methods of `Object`. `GameTextProcessor` inherits `Object`, so it has access. Standard Ruby. |
| Terminal not restored on crash | `at_exit` fires on `exit` from any thread in Ruby (verified). Only `SIGKILL` bypasses it. |
| Duplicate stream names | Hash last-writer-wins is intentional behavior. Can't route one stream to two windows. |
| Tab bar overflow | Curses `addstr` truncates at window boundary. No crash, just cosmetic truncation. |
| Regexp.union([]) | Returns `/(?!)/` (matches nothing). Does NOT crash. Verified in Ruby. |
| add_to_history empty history | `nil.nil?` returns true, short-circuits `||` before `.empty?`. No crash. |

---

## Summary

| Category | Count |
|----------|-------|
| Real bugs (fix) | 4 |
| Nice-to-have improvements | 3 |
| False positives eliminated | 13 |
| **Total from original 100+ raw findings** | **7 actionable** |

The codebase is in solid shape. The 4 real bugs are:
1. One confirmed crash (color tag parsing — BUG-1)
2. One config-triggered crash (bad XML cascade — BUG-2)
3. One silent failure (action typo — BUG-3)
4. One latent regex safety issue (spell name escaping — BUG-4)

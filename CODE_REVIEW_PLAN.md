# Mahtra-ProfanityFE Code Review Plan

Date: 2026-03-15
Reviewer: Claude Opus 4.6

This plan tracks all findings from the comprehensive code review covering
DRY, YARD, SOLID, XML documentation, CLI validation, and USER_GUIDE accuracy.

---

## Phase 1: Documentation Bugs (Must Fix)

These are factual errors or missing documentation that will confuse users.

### 1.1 Add --speech-ts to USER_GUIDE.md CLI flags table
- **File**: USER_GUIDE.md, section 1 "Getting Started / Command-Line Flags"
- **Issue**: `--speech-ts` was added to code and --help output but never added to the guide
- **Fix**: Add row to CLI flags table:
  `--speech-ts` — Add timestamps to speech, familiar, and thought windows
- **Status**: [x] DONE

### 1.2 Fix --remote-url parameter format in USER_GUIDE.md
- **File**: USER_GUIDE.md, section 1 CLI flags table
- **Issue**: Guide shows `--remote-url` without parameter; code requires `--remote-url=<url>`
- **Fix**: Update table entry to show `--remote-url=<url>` format
- **Status**: [x] DONE

### 1.3 Remove nonexistent streams from USER_GUIDE.md
- **File**: USER_GUIDE.md, section 11 "Stream Routing"
- **Issue**: Lists "talk" and "whispers" as valid stream names, but these are not implemented
  in game_text_processor.rb. Only these streams exist: combat, exp, percWindow, moonWindow,
  death, logons, thoughts, lnet, voln, familiar, assess, ooc, shopWindow, room, atmospherics
- **Fix**: Remove "talk" and "whispers" from the stream list; verify all implemented streams
  are listed
- **Status**: [x] DONE

### 1.4 Add .help to dot-commands documentation
- **File**: USER_GUIDE.md, section 7 "Dot-Commands"
- **Issue**: `.help` is implemented (profanity.rb line 439, shows DOT_COMMAND_HELP array)
  but has no dedicated subsection like all other dot-commands
- **Fix**: Add `.help` subsection explaining it lists all available dot-commands
- **Status**: [x] DONE

### 1.5 Add roomDesc to preset IDs table
- **File**: USER_GUIDE.md, section 8 "Presets"
- **Issue**: `roomDesc` preset is used in game_text_processor.rb (line 310-311) and
  referenced in section 3.6, but not listed in the preset IDs reference table
- **Fix**: Add `roomDesc` to the preset table with description
- **Status**: [x] DONE

---

## Phase 2: DRY Fixes (Should Fix)

Duplicated code that creates maintenance burden.

### 2.1 Extract shared logging utility
- **Severity**: HIGH
- **Issue**: The same logging pattern appears 7+ times across the codebase:
  ```ruby
  begin
    File.open(LOG_FILE, 'a') { |f| f.puts "[context] message" }
  rescue StandardError
    $stderr.puts "[context] message"
  end
  ```
- **Files affected**:
  - lib/autocomplete.rb (line 77)
  - lib/command_buffer.rb (lines 228-235)
  - lib/game_text_processor.rb (multiple locations)
  - lib/mouse_scroll.rb (lines 57-59)
  - lib/selection_manager.rb (lines 45, 69, 71)
  - lib/windows/perc_window.rb (lines 67-70)
- **Fix**: Create `lib/logger.rb` with a `ProfanityLog.write(context, message)` method;
  replace all 7+ occurrences
- **Status**: [ ] TODO

### 2.2 Extract StringClassification to shared file
- **Severity**: HIGH
- **Issue**: `StringClassification` refinement module (alnum?, digits?, punct?, space?)
  is defined in lib/command_buffer.rb lines 10-28 with a comment admitting it's
  "Duplicated from profanity.rb so this file is self-contained"
- **Fix**: Extract to `lib/string_classification.rb`; require from both locations
- **Status**: [ ] TODO

### 2.3 Extract shared color rendering helper
- **Severity**: MEDIUM
- **Issue**: Similar `attron(Curses.color_pair(...))` rendering blocks appear in
  countdown_window.rb, progress_window.rb, and indicator_window.rb
- **Fix**: Add a `render_colored_segment` helper to BaseWindow or a mixin
- **Status**: [ ] TODO

### 2.4 Extract color region hash builder
- **Severity**: MEDIUM
- **Issue**: The `{start:, end:, fg:, bg:, ul:}` hash structure is built repeatedly
  in room_window.rb, text_window.rb, and game_text_processor.rb
- **Fix**: Consider a small `ColorRegion` struct or factory method
- **Status**: [ ] TODO

---

## Phase 3: YARD Documentation (Should Fix)

Methods missing @param/@return documentation.

### 3.1 Document all window #initialize methods
- **Severity**: MEDIUM
- **Issue**: Nearly all window classes (10+) have undocumented #initialize methods
- **Files**:
  - lib/windows/base_window.rb
  - lib/windows/text_window.rb
  - lib/windows/tabbed_text_window.rb
  - lib/windows/indicator_window.rb
  - lib/windows/progress_window.rb
  - lib/windows/countdown_window.rb
  - lib/windows/room_window.rb
  - lib/windows/exp_window.rb
  - lib/windows/perc_window.rb
  - lib/windows/sink_window.rb
- **Fix**: Add @param tags to each #initialize
- **Status**: [ ] TODO

### 3.2 Document SelectionManager module
- **Severity**: MEDIUM
- **Issue**: All 5 public methods completely lack YARD documentation:
  start_selection, update_selection, end_selection, clear_selection, copy_to_clipboard
- **File**: lib/selection_manager.rb
- **Fix**: Add @param/@return to all 5 methods
- **Status**: [ ] TODO

### 3.3 Document SinkWindow class
- **Severity**: MEDIUM
- **Issue**: All 8 methods lack YARD documentation (intentional null-object pattern
  but should still document the "why")
- **File**: lib/windows/sink_window.rb
- **Fix**: Add YARD docs explaining each is a deliberate no-op and why
- **Status**: [ ] TODO

### 3.4 Document GameTextProcessor private methods
- **Severity**: MEDIUM
- **Issue**: ~20+ private helper methods lack YARD docs. Public #initialize and #run
  are documented but the private extraction methods are not
- **File**: lib/game_text_processor.rb
- **Fix**: Add @param/@return to all private methods (handle_game_text, new_stun,
  add_prompt, process_room_data, etc.)
- **Status**: [ ] TODO

### 3.5 Document MouseScroll private methods
- **Severity**: LOW
- **Issue**: 4 private methods lack YARD docs: load_settings, reset_configuration,
  configure, handle_scroll
- **File**: lib/mouse_scroll.rb
- **Fix**: Add @param/@return tags
- **Status**: [ ] TODO

### 3.6 Document KillRing#initialize
- **Severity**: LOW
- **Issue**: Missing @param documentation on constructor
- **File**: lib/kill_ring.rb
- **Fix**: Add YARD docs
- **Status**: [ ] TODO

### 3.7 Document Skill class
- **Severity**: LOW
- **Issue**: No file-level docs; #initialize and #to_s lack YARD
- **File**: lib/windows/skill.rb
- **Fix**: Add file-level and method-level docs
- **Status**: [ ] TODO

### 3.8 Document profanity.rb helper functions
- **Severity**: LOW
- **Issue**: parse_color_attrs and parse_player_names lack YARD docs;
  procs (do_macro, execute_command, send_history_command) have no formal docs
- **File**: profanity.rb
- **Fix**: Add @param/@return to the two helper functions; add # comments
  above procs explaining purpose
- **Status**: [ ] TODO

### 3.9 Document WindowManager#initialize
- **Severity**: LOW
- **Issue**: Constructor lacks YARD docs
- **File**: lib/window_manager.rb
- **Fix**: Add YARD docs
- **Status**: [ ] TODO

---

## Phase 4: XML Template Improvements (Nice to Have)

The 3 GS templates are GOOD but not at the EXCELLENT level of mahtra/default.

### 4.1 Fix placeholder macro in original.xml
- **File**: templates/original.xml, line 86
- **Issue**: `<key id='f' macro='something'/>` — "something" is a meaningless placeholder
- **Fix**: Either replace with a real GS macro or add a comment explaining it's a placeholder
  for customization
- **Status**: [ ] TODO

### 4.2 Add comments to undocumented highlights in tysong.xml
- **File**: templates/tysong.xml, lines 195+
- **Issue**: Several highlight patterns lack inline comments explaining what they match
- **Fix**: Add brief comments to each undocumented pattern
- **Status**: [ ] TODO

### 4.3 Consolidate redundant header in eleazzar.xml
- **File**: templates/eleazzar.xml
- **Issue**: Two separate header comment blocks (one structured, one informal) at top of file
  create redundancy
- **Fix**: Merge into a single comprehensive header
- **Status**: [ ] TODO

---

## Phase 5: SOLID Architecture (Consider / Long-term)

These are architectural improvements. They improve testability and extensibility
but are higher-risk refactors. Track here for future planning.

### 5.1 Break apart GameTextProcessor (SRP)
- **Severity**: HIGH (but high effort)
- **Issue**: ~1200 line class handling 8 distinct concerns
- **Suggested decomposition**:
  - Core pipeline (XML tag extraction, line iteration)
  - Stream router (route text to correct window by stream name)
  - Room data assembler (title, desc, objects, players, exits)
  - Effect processor (indicator/progress/countdown updates, stun detection)
  - Game-specific module (DR death/logon formatting, spell abbreviations)
- **Status**: [ ] FUTURE

### 5.2 Extract window factory from WindowManager.load_layout (OCP)
- **Severity**: HIGH (but high effort)
- **Issue**: 169-line method with 10-branch case statement. Adding a new window type
  requires modifying WindowManager directly
- **Fix**: Each window class registers itself with a class method and
  WindowManager dispatches via a registry lookup instead of case/when
- **Status**: [ ] FUTURE

### 5.3 Create game-specific modules (DIP + OCP)
- **Severity**: MEDIUM
- **Issue**: DR-specific code (spell abbreviations, death message formatting, logon
  patterns, Raise Dead stun detection) is hardcoded in GameTextProcessor
- **Fix**: Extract to lib/games/dragonrealms.rb and lib/games/gemstone.rb;
  select via --game flag or auto-detection from server XML
- **Note**: lib/games/ directory already created during restructure
- **Status**: [ ] FUTURE

### 5.4 Address SinkWindow Liskov violation
- **Severity**: MEDIUM (but low impact)
- **Issue**: SinkWindow overrides all BaseWindow methods as no-ops, violating LSP.
  It doesn't need to inherit from BaseWindow at all
- **Fix**: Make SinkWindow a standalone class (or duck-type) that responds to the
  same interface without inheriting Curses::Window
- **Status**: [ ] FUTURE

### 5.5 Split BaseWindow interface (ISP)
- **Severity**: MEDIUM (but low impact)
- **Issue**: BaseWindow provides scrollbar, selection, and routing APIs that
  IndicatorWindow, ProgressWindow, CountdownWindow, and SinkWindow don't need
- **Fix**: Extract Scrollable, Selectable, Routable mixins
- **Status**: [ ] FUTURE

### 5.6 Inject ColorManager dependency (DIP)
- **Severity**: LOW
- **Issue**: ColorManager is a global module with mutable state; difficult to test
- **Fix**: Use dependency injection or a ColorManager instance
- **Status**: [ ] FUTURE

---

## Phase 6: Code Quality (Minor)

### 6.1 Thread safety: ColorManager initialization
- **Severity**: MEDIUM
- **Issue**: color_manager.rb uses `sleep 0.01` as workaround for ncurses race
  condition; @color_id_lookup initialization not synchronized
- **Status**: [ ] FUTURE

### 6.2 Inconsistent error handling patterns
- **Severity**: MEDIUM
- **Issue**: Different files handle errors differently:
  - autocomplete.rb: catches StandardError, logs to file
  - settings_loader.rb: catches StandardError, prints to $stdout
  - profanity_settings.rb: catches JSON::ParserError, returns nil silently
- **Fix**: Will be partially addressed by Phase 2.1 (shared logger)
- **Status**: [ ] FUTURE

### 6.3 Magic numbers in window defaults
- **Severity**: LOW
- **Issue**: Hardcoded color values like `[nil, 'ff0000', '0000ff']` in
  countdown_window.rb and `%w[0000aa 000055]` in progress_window.rb
- **Fix**: Extract to named constants
- **Status**: [ ] FUTURE

---

## Summary

| Phase | Items | Severity | Effort |
|-------|-------|----------|--------|
| 1. Documentation Bugs | 5 | Must fix | Low |
| 2. DRY Fixes | 4 | Should fix | Medium |
| 3. YARD Documentation | 9 | Should fix | Medium |
| 4. XML Templates | 3 | Nice to have | Low |
| 5. SOLID Architecture | 6 | Future | High |
| 6. Code Quality | 3 | Future | Medium |
| **Total** | **30** | | |

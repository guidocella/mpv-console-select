local input = require 'mp.input'
local matches = {}
local selected_match = 1
local first_match_to_print = 1
local global_margins
local fzy = {}

local options = {
    scale = 1,
    font = "",
    font_size = 16,
    border_size = 1,
    case_sensitive = true,
    history_dedup = true,
    font_hw_ratio = 'auto',
}
require 'mp.options'.read_options(options, 'console')

mp.observe_property('user-data/osc/margins', 'native', function(_, val)
    global_margins = val or { t = 0, b = 0 }
end)

local function calculate_max_log_lines()
    local screeny = mp.get_property_native('osd-height') / mp.get_property_native('display-hidpi-scale', 1) / options.scale

    -- Terminal output.
    if screeny == 0 then
        -- Subtract 4 lines for the input line, the status line and the (n hidden items) lines.
        return mp.get_property_native('term-size/h', 29) - 4
    end

    local screeny_factor = 1 - global_margins.t - global_margins.b

    -- Subtract 3.5 lines for the input line and the (n hidden items) lines.
    return math.floor(screeny * screeny_factor / options.font_size - 3.5)
end

local function update_log()
    local log = {}
    local max_log_lines = calculate_max_log_lines()

    if selected_match < first_match_to_print then
        first_match_to_print = selected_match
    elseif selected_match > first_match_to_print + max_log_lines - 1 then
        first_match_to_print = selected_match - max_log_lines + 1
    end

    if first_match_to_print > 1 then
        log[1] = {
            text = '↑ (' .. (first_match_to_print - 1) .. ' hidden items)',
            style = '{\\1c&Hcccccc&}',
            terminal_style = '\027[38;5;8m',
        }
    end

    local last_match_to_print  = math.min(first_match_to_print + max_log_lines - 1, #matches)

    for i = first_match_to_print, last_match_to_print do
        if i == selected_match then
            log[#log+1] = {
                text = matches[i].text,
                style = '{\\1c&H2fbdfa&\\b1}',
                terminal_style = '\027[7m',
            }
        else
            log[#log+1] = matches[i].text
        end
    end

    if last_match_to_print < #matches then
        log[#log+1] = {
            text = '↓ (' .. (#matches - last_match_to_print) .. ' hidden items)',
            style = '{\\1c&Hcccccc&}',
            terminal_style = '\027[38;5;8m',
        }
    end

    input.set_log(log)
end

local function down()
    selected_match = selected_match < #matches and selected_match + 1 or 1
    update_log()
end

local function up()
    selected_match = selected_match > 1 and selected_match - 1 or #matches
    update_log()
end

local function page_down()
    selected_match = math.min(selected_match + calculate_max_log_lines() - 1, #matches)
    update_log()
end

local function page_up()
    selected_match = math.max(selected_match - calculate_max_log_lines() + 1, 1)
    update_log()
end

local keybindings = {
    ['DOWN'] = down,
    ['Ctrl+j'] = down,
    ['Ctrl+n'] = down,
    ['UP'] = up,
    ['Ctrl+k'] = up,
    ['Ctrl+p'] = up,
    ['PGDWN'] = page_down,
    ['Ctrl+f'] = page_down,
    ['PGUP'] = page_up,
    ['Ctrl+b'] = page_up,
}

local function opened()
    mp.observe_property('osd-dimensions', nil, update_log)

    -- Without add_timeout console.lua's keybindings can take precedence
    -- over these, even though these are always defined later ¯\(ツ)/¯.
    mp.add_timeout(0.01, function ()
        for key, fn in pairs(keybindings) do
            mp.add_forced_key_binding(key, mp.get_script_name() .. '_' .. key, fn, { repeatable = true })
        end
    end)
end

local function closed()
    for key, _ in pairs(keybindings) do
        mp.remove_key_binding(mp.get_script_name() .. '_' .. key)
    end

    mp.unobserve_property(update_log)

    matches = {}
    selected_match = 1
    first_match_to_print = 1
end

local function fuzzy_find(needle, haystacks)
    if type(haystacks[1]) == 'table' then
        local tmp = {}
        for i, value in ipairs(haystacks) do
            tmp[i] = value.text
        end
        haystacks = tmp
    end

    local result = fzy.filter(needle, haystacks)
    table.sort(result, function (i, j)
        return i[3] > j[3]
    end)
    for i, value in ipairs(result) do
        result[i] = value[1]
    end
    return result
end

local function remove_selected_from_playlist(playlist)
    mp.commandv('playlist-remove', matches[selected_match].pos - 1)

    table.remove(playlist, matches[selected_match].pos)
    table.remove(matches, selected_match)

    for i = selected_match, #matches do
        matches[i].pos = matches[i].pos - 1
    end

    if selected_match > #matches and selected_match > 1 then
        selected_match = selected_match - 1
    end

    local first_hidden = #matches - calculate_max_log_lines()
    if first_hidden > 0 and first_match_to_print > first_hidden then
        first_match_to_print = first_match_to_print - 1
    end

    update_log()
end

-- mp.add_key_binding('g-p', ...) doesn't work if p is bound in input.conf.
mp.add_forced_key_binding('g-p', 'select-playlist', function ()
    local playlist = {}

    input.get({
        prompt = 'Select a playlist entry:',
        opened = function ()
            for i, entry in ipairs(mp.get_property_native('playlist')) do
                local _, filename = require 'mp.utils'.split_path(entry.filename)
                playlist[i] = filename
                matches[i] = { text = filename, pos = i }

                if entry.playing then
                    selected_match = i
                end
            end

            opened()

            mp.add_forced_key_binding(
                'Ctrl+D',
                mp.get_script_name() .. '_' .. 'Ctrl+D',
                function ()
                    remove_selected_from_playlist(playlist)
                end,
                { repeatable = true }
            )
        end,
        edited = function (text)
            matches = {}
            selected_match = 1

            for _, match in ipairs(fuzzy_find(text, playlist)) do
                matches[#matches+1] = { text = playlist[match], pos = match }
            end

            update_log()
        end,
        submit = function ()
            if #matches > 0 then
                mp.commandv('playlist-play-index', matches[selected_match].pos - 1)
            end
            input.terminate()
        end,
        closed = function ()
            closed()
            mp.remove_key_binding(mp.get_script_name() .. '_' .. 'Ctrl+D')
        end,
    })
end)

mp.add_forced_key_binding('g-t', 'select-track', function ()
    local tracks = mp.get_property_native('track-list')

    input.get({
        prompt = 'Select a track:',
        opened = function ()
            for i, track in ipairs(tracks) do
                track.text = track.type:sub(1, 1):upper() .. track.type:sub(2) .. ': ' ..
                    (track.selected and '➜' or ' ') ..
                    (track.title and ' ' .. track.title or '') ..
                    ' (' .. (
                        (track.lang and track.lang .. ' ' or '') ..
                        (track.codec and track.codec .. ' ' or '') ..
                        (track['demux-w'] and track['demux-w'] .. 'x' .. track['demux-h'] .. ' ' or '') ..
                        (track['demux-fps'] and not track.image and string.format('%.3f', track['demux-fps']) .. 'FPS ' or '') ..
                        (track['demux-channel-count'] and track['demux-channel-count'] .. 'ch ' or '') ..
                        (track['demux-samplerate'] and track['demux-samplerate'] / 1000 .. 'kHz ' or '') ..
                        (track.external and 'external ' or '')
                    ):sub(1, -2) .. ')'

                matches[i] = {
                    text = track.text,
                    type = track.type,
                    id = track.id,
                    selected = track.selected,
                }
            end

            opened()
        end,
        edited = function (text)
            matches = {}
            selected_match = 1

            for _, match in ipairs(fuzzy_find(text, tracks)) do
                local track = tracks[match]

                matches[#matches+1] = {
                    text = track.text,
                    type = track.type,
                    id = track.id,
                    selected = track.selected,
                }
            end

            update_log()
        end,
        submit = function ()
            if #matches > 0 then
                local track = matches[selected_match]
                mp.set_property(track.type, track.selected and 'no' or track.id)
            end
            input.terminate()
        end,
        closed = closed,
    })
end)

mp.add_forced_key_binding('g-j', 'select-secondary-sub', function ()
    local subs = {}

    input.get({
        prompt = 'Select a secondary subtitle:',
        opened = function ()
            local secondary_sid = mp.get_property_native('secondary-sid')

            for _, track in ipairs(mp.get_property_native('track-list')) do
                if track.type == 'sub' then
                    track.text = (track.selected and '➜' or ' ') ..
                        (track.title and ' ' .. track.title or '') ..
                        ' (' .. (
                            (track.lang and track.lang .. ' ' or '') ..
                            (track.codec and track.codec .. ' ' or '') ..
                            (track.external and 'external ' or '')
                        ):sub(1, -2) .. ')'

                    subs[#subs+1] = track

                    matches[#matches+1] = {
                        text = track.text,
                        id = track.id,
                        selected = track.selected,
                    }

                    if track.id == secondary_sid then
                        selected_match = #subs
                    end
                end
            end

            opened()
        end,
        edited = function (text)
            matches = {}
            selected_match = 1

            for _, match in ipairs(fuzzy_find(text, subs)) do
                local sub = subs[match]

                matches[#matches+1] = {
                    text = sub.text,
                    id = sub.id,
                    selected = sub.selected,
                }
            end

            update_log()
        end,
        submit = function ()
            if #matches > 0 then
                local sub = matches[selected_match]
                mp.set_property('secondary-sid', sub.selected and 'no' or sub.id)
            end
            input.terminate()
        end,
        closed = closed,
    })
end)

local function format_time(t)
    local h = math.floor(t / (60 * 60))
    t = t - (h * 60 * 60)
    local m = math.floor(t / 60)
    local s = t - (m * 60)

    return string.format('%.2d:%.2d:%.2d', h, m, s)
end

mp.add_forced_key_binding('g-c', 'select-chapter', function ()
    local chapters = {}

    input.get({
        prompt = 'Select a chapter:',
        opened = function ()
            local current_chapter = mp.get_property_native('chapter')

            for i, chapter in ipairs(mp.get_property_native('chapter-list')) do
                chapters[i] = format_time(chapter.time) .. ' ' .. chapter.title
                matches[i] = { text = chapters[#chapters], number = i }

                if i - 1 == current_chapter then
                    selected_match = i
                end
            end

            opened()
        end,
        edited = function (text)
            matches = {}
            selected_match = 1

            for _, match in ipairs(fuzzy_find(text, chapters)) do
                matches[#matches+1] = { text = chapters[match], number = match }
            end

            update_log()
        end,
        submit = function ()
            if #matches > 0 then
                mp.set_property('chapter', matches[selected_match].number - 1)
            end
            input.terminate()
        end,
        closed = closed,
    })
end)

local function show_error(message)
    mp.msg.error(message)
    if mp.get_property_native('vo-configured') then
        mp.osd_message(message, 5)
    end
end

mp.add_forced_key_binding('g-s', 'sub-seek', function ()
    local sub = mp.get_property_native('current-tracks/sub')

    if sub == nil then
        show_error('No subtitle is loaded')
        return
    end

    local r = mp.command_native({
        name = 'subprocess',
        capture_stdout = true,
        args = sub.external
            and {'ffmpeg', '-loglevel', 'quiet', '-i', sub['external-filename'], '-f', 'lrc', '-map_metadata', '-1', '-fflags', '+bitexact', '-'}
            or {'ffmpeg', '-loglevel', 'quiet', '-i', mp.get_property('path'), '-map', 's:' .. sub['id'] - 1, '-f', 'lrc', '-map_metadata', '-1', '-fflags', '+bitexact', '-'}
    })

    if r.status < 0 then
        show_error('subprocess error: ' .. r.error_string)
        return
    end

    if r.status > 0 then
        show_error('ffmpeg failed with code ' .. r.status)
        return
    end

    local sub_lines = {}

    input.get({
        prompt = 'Select a line to seek to:',
        opened = function ()
            local sub_start = mp.get_property_native('sub-start', 0)
            local m = math.floor(sub_start / 60)
            local s = sub_start - m * 60
            sub_start = string.format('%.2d:%05.2f', m, s)

            for line in r.stdout:gsub('<.->', ''):gsub('{\\.-}', ''):gmatch('[^\n]+') do
                sub_lines[#sub_lines+1] = line
                matches[#matches+1] = { text = line }

                if line:find('^%[' .. sub_start) then
                    selected_match = #sub_lines
                end
            end

            opened()
        end,
        edited = function (text)
            matches = {}
            selected_match = 1

            for _, match in ipairs(fuzzy_find(text, sub_lines)) do
                matches[#matches+1] = { text = sub_lines[match] }
            end

            update_log()
        end,
        submit = function ()
            if #matches > 0 then
                mp.commandv('seek', matches[selected_match].text:match('[%d:%.]+'), 'absolute')
            end
            input.terminate()
        end,
        closed = closed,
    })
end)


--[[ https://github.com/swarn/fzy-lua
Just copy paste this to not inconvenience users by making them install modules.

The MIT License (MIT)

Copyright (c) 2020 Seth Warn

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE. ]]

-- The lua implementation of the fzy string matching algorithm

local SCORE_GAP_LEADING = -0.005
local SCORE_GAP_TRAILING = -0.005
local SCORE_GAP_INNER = -0.01
local SCORE_MATCH_CONSECUTIVE = 1.0
local SCORE_MATCH_SLASH = 0.9
local SCORE_MATCH_WORD = 0.8
local SCORE_MATCH_CAPITAL = 0.7
local SCORE_MATCH_DOT = 0.6
local SCORE_MAX = math.huge
local SCORE_MIN = -math.huge
local MATCH_MAX_LENGTH = 1024

-- Check if `needle` is a subsequence of the `haystack`.
--
-- Usually called before `score` or `positions`.
--
-- Args:
--   needle (string)
--   haystack (string)
--   case_sensitive (bool, optional): defaults to false
--
-- Returns:
--   bool
function fzy.has_match(needle, haystack, case_sensitive)
  if not case_sensitive then
    needle = string.lower(needle)
    haystack = string.lower(haystack)
  end

  local j = 1
  for i = 1, string.len(needle) do
    j = string.find(haystack, needle:sub(i, i), j, true)
    if not j then
      return false
    else
      j = j + 1
    end
  end

  return true
end

local function is_lower(c)
  return c:match("%l")
end

local function is_upper(c)
  return c:match("%u")
end

local function precompute_bonus(haystack)
  local match_bonus = {}

  local last_char = "/"
  for i = 1, string.len(haystack) do
    local this_char = haystack:sub(i, i)
    if last_char == "/" or last_char == "\\" then
      match_bonus[i] = SCORE_MATCH_SLASH
    elseif last_char == "-" or last_char == "_" or last_char == " " then
      match_bonus[i] = SCORE_MATCH_WORD
    elseif last_char == "." then
      match_bonus[i] = SCORE_MATCH_DOT
    elseif is_lower(last_char) and is_upper(this_char) then
      match_bonus[i] = SCORE_MATCH_CAPITAL
    else
      match_bonus[i] = 0
    end

    last_char = this_char
  end

  return match_bonus
end

local function compute(needle, haystack, D, M, case_sensitive)
  -- Note that the match bonuses must be computed before the arguments are
  -- converted to lowercase, since there are bonuses for camelCase.
  local match_bonus = precompute_bonus(haystack)
  local n = string.len(needle)
  local m = string.len(haystack)

  if not case_sensitive then
    needle = string.lower(needle)
    haystack = string.lower(haystack)
  end

  -- Because lua only grants access to chars through substring extraction,
  -- get all the characters from the haystack once now, to reuse below.
  local haystack_chars = {}
  for i = 1, m do
    haystack_chars[i] = haystack:sub(i, i)
  end

  for i = 1, n do
    D[i] = {}
    M[i] = {}

    local prev_score = SCORE_MIN
    local gap_score = i == n and SCORE_GAP_TRAILING or SCORE_GAP_INNER
    local needle_char = needle:sub(i, i)

    for j = 1, m do
      if needle_char == haystack_chars[j] then
        local score = SCORE_MIN
        if i == 1 then
          score = ((j - 1) * SCORE_GAP_LEADING) + match_bonus[j]
        elseif j > 1 then
          local a = M[i - 1][j - 1] + match_bonus[j]
          local b = D[i - 1][j - 1] + SCORE_MATCH_CONSECUTIVE
          score = math.max(a, b)
        end
        D[i][j] = score
        prev_score = math.max(score, prev_score + gap_score)
        M[i][j] = prev_score
      else
        D[i][j] = SCORE_MIN
        prev_score = prev_score + gap_score
        M[i][j] = prev_score
      end
    end
  end
end

-- Compute a matching score.
--
-- Args:
--   needle (string): must be a subequence of `haystack`, or the result is
--     undefined.
--   haystack (string)
--   case_sensitive (bool, optional): defaults to false
--
-- Returns:
--   number: higher scores indicate better matches. See also `get_score_min`
--     and `get_score_max`.
function fzy.score(needle, haystack, case_sensitive)
  local n = string.len(needle)
  local m = string.len(haystack)

  if n == 0 or m == 0 or m > MATCH_MAX_LENGTH or n > m then
    return SCORE_MIN
  elseif n == m then
    return SCORE_MAX
  else
    local D = {}
    local M = {}
    compute(needle, haystack, D, M, case_sensitive)
    return M[n][m]
  end
end

-- Compute the locations where fzy matches a string.
--
-- Determine where each character of the `needle` is matched to the `haystack`
-- in the optimal match.
--
-- Args:
--   needle (string): must be a subequence of `haystack`, or the result is
--     undefined.
--   haystack (string)
--   case_sensitive (bool, optional): defaults to false
--
-- Returns:
--   {int,...}: indices, where `indices[n]` is the location of the `n`th
--     character of `needle` in `haystack`.
--   number: the same matching score returned by `score`
function fzy.positions(needle, haystack, case_sensitive)
  local n = string.len(needle)
  local m = string.len(haystack)

  if n == 0 or m == 0 or m > MATCH_MAX_LENGTH or n > m then
    return {}, SCORE_MIN
  elseif n == m then
    local consecutive = {}
    for i = 1, n do
      consecutive[i] = i
    end
    return consecutive, SCORE_MAX
  end

  local D = {}
  local M = {}
  compute(needle, haystack, D, M, case_sensitive)

  local positions = {}
  local match_required = false
  local j = m
  for i = n, 1, -1 do
    while j >= 1 do
      if D[i][j] ~= SCORE_MIN and (match_required or D[i][j] == M[i][j]) then
        match_required = (i ~= 1) and (j ~= 1) and (
        M[i][j] == D[i - 1][j - 1] + SCORE_MATCH_CONSECUTIVE)
        positions[i] = j
        j = j - 1
        break
      else
        j = j - 1
      end
    end
  end

  return positions, M[n][m]
end

-- Apply `has_match` and `positions` to an array of haystacks.
--
-- Args:
--   needle (string)
--   haystack ({string, ...})
--   case_sensitive (bool, optional): defaults to false
--
-- Returns:
--   {{idx, positions, score}, ...}: an array with one entry per matching line
--     in `haystacks`, each entry giving the index of the line in `haystacks`
--     as well as the equivalent to the return value of `positions` for that
--     line.
function fzy.filter(needle, haystacks, case_sensitive)
  local result = {}

  for i, line in ipairs(haystacks) do
    if fzy.has_match(needle, line, case_sensitive) then
      local p, s = fzy.positions(needle, line, case_sensitive)
      table.insert(result, {i, p, s})
    end
  end

  return result
end

-- The lowest value returned by `score`.
--
-- In two special cases:
--  - an empty `needle`, or
--  - a `needle` or `haystack` larger than than `get_max_length`,
-- the `score` function will return this exact value, which can be used as a
-- sentinel. This is the lowest possible score.
function fzy.get_score_min()
  return SCORE_MIN
end

-- The score returned for exact matches. This is the highest possible score.
function fzy.get_score_max()
  return SCORE_MAX
end

-- The maximum size for which `fzy` will evaluate scores.
function fzy.get_max_length()
  return MATCH_MAX_LENGTH
end

-- The minimum score returned for normal matches.
--
-- For matches that don't return `get_score_min`, their score will be greater
-- than than this value.
function fzy.get_score_floor()
  return MATCH_MAX_LENGTH * SCORE_GAP_INNER
end

-- The maximum score for non-exact matches.
--
-- For matches that don't return `get_score_max`, their score will be less than
-- this value.
function fzy.get_score_ceiling()
  return MATCH_MAX_LENGTH * SCORE_MATCH_CONSECUTIVE
end

-- The name of the currently-running implmenetation, "lua" or "native".
function fzy.get_implementation_name()
  return "lua"
end

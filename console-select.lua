local input = require 'mp.input'
local matches = {}
local selected_match = 1
local first_match_to_print = 1
local global_margins

mp.observe_property('user-data/osc/margins', 'native', function(_, val)
    global_margins = val or { t = 0, b = 0 }
end)

local function calculate_max_log_lines()
    local screeny = mp.get_property_native('osd-height') / mp.get_property_native('display-hidpi-scale', 1)

    -- Terminal output.
    if screeny == 0 then
        return 25
    end

    local screeny_factor = 1 - global_margins.t - global_margins.b

    -- Subtract 3.5 lines for the input line and the (n hidden items) lines.
    return math.floor(screeny * screeny_factor / mp.get_opt('console-font_size', 16) - 3.5)
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
        log[1] = { text = '↑ (' .. (first_match_to_print - 1) .. ' hidden items)', style = '{\\1c&Hcccccc&}' }
    end

    local last_match_to_print  = math.min(first_match_to_print + max_log_lines - 1, #matches)

    for i = first_match_to_print, last_match_to_print do
        log[#log+1] = { text = matches[i].text, style = i == selected_match and '{\\1c&H2fbdfa&\\b1}' or '' }
    end

    if last_match_to_print < #matches then
        log[#log+1] = { text = '↓ (' .. (#matches - last_match_to_print) .. ' hidden items)', style = '{\\1c&Hcccccc&}' }
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
            text = text:lower()

            for i, filename in ipairs(playlist) do
                if filename:lower():find(text, 1, true) then
                    matches[#matches+1] = { text = filename, pos = i }
                end
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
            text = text:lower()

            for _, track in ipairs(tracks) do
                if track.text:lower():find(text, 1, true) then
                    matches[#matches+1] = {
                        text = track.text,
                        type = track.type,
                        id = track.id,
                        selected = track.selected,
                    }
                end
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
            text = text:lower()

            for _, sub in ipairs(subs) do
                if sub.text:lower():find(text, 1, true) then
                    matches[#matches+1] = {
                        text = sub.text,
                        id = sub.id,
                        selected = sub.selected,
                    }
                end
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

                if i == current_chapter then
                    selected_match = i
                end
            end

            opened()
        end,
        edited = function (text)
            matches = {}
            selected_match = 1
            text = text:lower()

            for i, chapter in ipairs(chapters) do
                if chapter:lower():find(text, 1, true) then
                    matches[#matches+1] = { text = chapter, number = i }
                end
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
            text = text:lower()

            for _, line in ipairs(sub_lines) do
                if line:lower():find(text, 1, true) then
                    matches[#matches+1] = { text = line }
                end
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

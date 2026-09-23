---@diagnostic disable: lowercase-global, undefined-global

local msg = require("mp.msg")
local utils = require("mp.utils")

-- ============================================================================
-- 1. CONFIGURATION
-- ============================================================================
local Config = {
    key_mark_cut = "c",
    web_key_mark_cut = "shift+c",
    video_extension = "mp4",
    ytdl_path = "yt-dlp",

    web = {
        audio_target_bitrate = 192,
        video_target_file_size = 8,
        video_target_scale = "1280:-2",
        min_video_bitrate = 150
    }
}

local EncoderChain = {
    {
        name = "AMD AMF (Hardware)",
        c_v = "h264_amf",
        standard_args = {"-rc", "cqp", "-qp_i", "16", "-qp_p", "16", "-pix_fmt", "yuv420p"},
        web_args = {"-rc", "vbr_peak", "-pix_fmt", "yuv420p"},
        needs_2pass = false
    },
    {
        name = "VA-API (Hardware - Open Source)",
        c_v = "h264_vaapi",
        init_args = {"-vaapi_device", "/dev/dri/renderD128"},
        filter_prefix = "format=nv12,hwupload",
        standard_args = {"-qp", "16"},
        web_args = {},
        needs_2pass = false
    },
    {
        name = "x264 (Software Fallback)",
        c_v = "libx264",
        standard_args = {"-crf", "16", "-preset", "fast", "-pix_fmt", "yuv420p", "-profile:v", "high"},
        web_args = {"-pix_fmt", "yuv420p", "-profile:v", "high"},
        needs_2pass = true
    }
}

-- ============================================================================
-- 2. STATE MANAGEMENT
-- ============================================================================
local State = {
    file = { path = nil, filename = nil, directory = nil, basename = nil, is_remote = false },
    pos = { start_time = nil, end_time = nil, duration = 0 },
    progress = { is_encoding = false, timer = nil, file_path = nil, total_duration = 0, current_pass = 1, total_passes = 1 },
    is_web_mode = false
}

function State.reset_pos()
    State.pos.start_time = nil
    State.pos.end_time = nil
    State.pos.duration = 0
end

-- ============================================================================
-- 3. UTILITIES & LOGGING
-- ============================================================================
local Logger = {}

function Logger.log(level, text, osd_delay)
    if osd_delay and osd_delay > 0 then mp.osd_message(text, osd_delay) end
    level(text)
end

local function to_timestamp(seconds)
    if not seconds or seconds < 0 then seconds = 0 end
    local h, m = math.floor(seconds / 3600), math.floor((seconds % 3600) / 60)
    local s, cs = math.floor(seconds % 60), math.floor((seconds % 1) * 100)
    return string.format("%02d:%02d:%02d.%02d", h, m, s, cs)
end

local function get_output_path(filename)
    if State.file.directory and State.file.directory ~= "" then
        return utils.join_path(State.file.directory, filename)
    end
    return filename
end

-- Only http/https trigger the streamed-source path below; everything else
-- (plain local paths, smb://, etc.) falls through to the original,
-- untouched local-file logic.
local function is_url(path)
    return path ~= nil and path:match("^https?://") ~= nil
end

local function sanitize_filename(name)
    name = name:gsub('[<>:"/\\|?*%%]', "_")
    name = name:gsub("^%s+", ""):gsub("%s+$", "")
    if name == "" then name = "stream" end
    return name
end

-- ============================================================================
-- 4. SYSTEM & SUBPROCESS
-- ============================================================================
local System = {}

function System.exec_async(args, callback)
    Logger.log(msg.info, string.format("Executing: %s", table.concat(args, " ")))
    mp.command_native_async({
        name = "subprocess", args = args, capture_stdout = false, capture_stderr = true, playback_only = false
    }, function(success, result)
        if result.status ~= 0 then
            local err = result.stderr and result.stderr:gsub("^%s*(.-)%s*$", "%1") or "Unknown error"
            Logger.log(msg.warn, string.format("Command failed: %s", err))
            if callback then callback(false, err) end
        else
            if callback then callback(true, nil) end
        end
    end)
end

-- Like exec_async, but captures stdout (used to read yt-dlp's JSON output).
function System.exec_capture_async(args, callback)
    Logger.log(msg.info, string.format("Executing: %s", table.concat(args, " ")))
    mp.command_native_async({
        name = "subprocess", args = args, capture_stdout = true, capture_stderr = true, playback_only = false
    }, function(success, result)
        callback(success, result)
    end)
end

function System.cleanup_temp_files(passlog_path)
    if not passlog_path then return end
    for _, file in ipairs({ passlog_path .. "-0.log", passlog_path .. "-0.log.mbtree" }) do
        os.remove(file)
    end
end

-- ============================================================================
-- 5. USER INTERFACE (OSD)
-- ============================================================================
local UI = {}

function UI.update_progress()
    if not State.progress.is_encoding or not State.progress.file_path then return end
    local file = io.open(State.progress.file_path, "r")
    if not file then return end
    
    local data = {}
    for line in file:lines() do
        local key, value = line:match("([^=]+)=(.+)")
        if key and value then data[key:gsub("^%s*(.-)%s*$", "%1")] = value:gsub("^%s*(.-)%s*$", "%1") end
    end
    file:close()

    if not data.frame then return end
    local out_time = data.out_time_ms and (tonumber(data.out_time_ms) / 1000000.0) or 0
    local percent = State.progress.total_duration > 0 and math.min(100, math.max(0, (out_time / State.progress.total_duration) * 100)) or 0
    
    local pass_info = State.progress.total_passes > 1 and string.format("Pass %d/%d - ", State.progress.current_pass, State.progress.total_passes) or ""
    local status_text = string.format("%sEncoding: %.1f%%\nTime: %s / %s | Speed: %s", pass_info, percent, to_timestamp(out_time), to_timestamp(State.progress.total_duration), data.speed or "1.0x")
    
    local filled = math.floor(50 * percent / 100)
    mp.osd_message(string.format("%s\n[%s]", status_text, string.rep("█", filled) .. string.rep("░", 50 - filled)), 0.1)
end

function UI.start_tracking(progress_file, duration, current_pass, total_passes)
    State.progress.is_encoding = true
    State.progress.file_path = progress_file
    State.progress.total_duration = duration
    State.progress.current_pass = current_pass
    State.progress.total_passes = total_passes
    local file = io.open(progress_file, "w")
    if file then file:close() end
    State.progress.timer = mp.add_periodic_timer(0.1, UI.update_progress)
end

function UI.stop_tracking()
    State.progress.is_encoding = false
    if State.progress.timer then State.progress.timer:kill(); State.progress.timer = nil end
    if State.progress.file_path then os.remove(State.progress.file_path); State.progress.file_path = nil end
    mp.osd_message("", 0)
end

-- ============================================================================
-- 6. MEDIA ENCODING WITH FALLBACK
-- ============================================================================
local Media = {}

-- Finds the 0-based ffmpeg input index of the first source flagged with `key`
-- ("is_video" / "is_audio"). For a single local/progressive source this is
-- always 0, matching the original hardcoded "0:v:0" / "0:a:*" behavior.
local function find_source_index(sources, key)
    for i, s in ipairs(sources) do
        if s[key] then return i - 1 end
    end
    return 0
end

local function map_audio(args, sources)
    local video_idx = find_source_index(sources, "is_video")
    table.insert(args, "-map") table.insert(args, string.format("%d:v:0", video_idx))

    if #sources > 1 then
        -- Adaptive stream: video and audio came from two separate inputs.
        local audio_idx = find_source_index(sources, "is_audio")
        table.insert(args, "-map") table.insert(args, string.format("%d:a:0", audio_idx))
    elseif State.file.is_remote then
        -- Single progressive stream URL - just take whatever audio it has.
        table.insert(args, "-map") table.insert(args, "0:a?")
    else
        -- Local file: original behavior, respects mpv's selected audio track.
        local aid = mp.get_property_number("aid")
        table.insert(args, "-map") table.insert(args, aid and aid > 0 and string.format("0:a:%d", aid - 1) or "0:a?")
    end
end

function Media.format_headers(headers)
    if not headers then return nil end
    local lines = {}
    for k, v in pairs(headers) do
        table.insert(lines, string.format("%s: %s", k, v))
    end
    if #lines == 0 then return nil end
    return table.concat(lines, "\r\n") .. "\r\n"
end

-- Resolves a page URL (YouTube, etc.) to direct, ffmpeg-fetchable media
-- URL(s) via yt-dlp. Called right when the cut is confirmed, so the links
-- (which typically expire) are as fresh as possible.
function Media.resolve_remote_source(url, callback)
    Logger.log(msg.info, "Resolving stream with yt-dlp...", 0)
    mp.osd_message("Resolving stream URL...", 0)

    System.exec_capture_async(
        { Config.ytdl_path, "-j", "--no-warnings", "--no-playlist", url },
        function(success, result)
            mp.osd_message("", 0)

            if not success or not result.stdout or result.stdout == "" then
                local err = (result and result.stderr) or "yt-dlp failed to run"
                return callback(false, err)
            end

            local json, err = utils.parse_json(result.stdout)
            if not json then
                return callback(false, "Could not parse yt-dlp output: " .. tostring(err))
            end

            local sources = {}
            if json.requested_formats and #json.requested_formats > 0 then
                -- Adaptive/DASH: separate video-only and audio-only streams.
                for _, fmt in ipairs(json.requested_formats) do
                    table.insert(sources, {
                        url = fmt.url,
                        headers = Media.format_headers(fmt.http_headers),
                        is_video = fmt.vcodec and fmt.vcodec ~= "none",
                        is_audio = fmt.acodec and fmt.acodec ~= "none"
                    })
                end
            elseif json.url then
                -- Progressive: a single URL carries both video and audio.
                table.insert(sources, {
                    url = json.url,
                    headers = Media.format_headers(json.http_headers),
                    is_video = true,
                    is_audio = true
                })
            end

            if #sources == 0 then
                return callback(false, "yt-dlp did not return a usable stream URL")
            end

            callback(true, sources)
        end
    )
end

function Media.calculate_web_params(duration)
    local a_bitrate = Config.web.audio_target_bitrate
    local v_bitrate = ((Config.web.video_target_file_size * 8192) / duration) - a_bitrate
    local scale = Config.web.video_target_scale

    if v_bitrate < 1000 then scale = "1280:-2" end 
    if v_bitrate < 500 then scale = "854:-2" end   
    if v_bitrate < Config.web.min_video_bitrate then
        v_bitrate = Config.web.min_video_bitrate
        scale = "426:-2" 
    end
    return string.format("%dk", math.floor(v_bitrate)), string.format("%dk", a_bitrate), scale
end

-- `sources` is a list of { url, headers, is_video, is_audio } tables:
-- one entry for a local file or a progressive stream, two entries
-- (video-only + audio-only) for an adaptive stream resolved via yt-dlp.
function Media.build_base_args(encoder, sources, progress_file)
    local args = {"ffmpeg", "-y", "-v", "error"}
    if encoder.init_args then
        for _, arg in ipairs(encoder.init_args) do table.insert(args, arg) end
    end
    for _, source in ipairs(sources) do
        if source.headers then
            table.insert(args, "-headers")
            table.insert(args, source.headers)
        end
        for _, arg in ipairs({"-ss", to_timestamp(State.pos.start_time), "-t", to_timestamp(State.pos.duration), "-i", source.url}) do
            table.insert(args, arg)
        end
    end
    return args
end

function Media.execute_with_fallback(encoder_idx, is_web, sources, output_file, callback)
    local encoder = EncoderChain[encoder_idx]
    if not encoder then
        Logger.log(msg.error, "All encoders failed! Check console for FFmpeg errors.", 5)
        return callback(false)
    end

    Logger.log(msg.info, string.format("Attempting encode with: %s", encoder.name), 2)
    local progress_file = get_output_path("ffmpeg_prog.txt")
    local args = Media.build_base_args(encoder, sources, progress_file)
    local video_idx = find_source_index(sources, "is_video")

    if is_web then
        local v_bitrate, a_bitrate, scale = Media.calculate_web_params(State.pos.duration)
        local scale_cmd = scale == "original" and "scale=iw:ih" or string.format("scale=%s", scale)
        if encoder.filter_prefix then scale_cmd = scale_cmd .. "," .. encoder.filter_prefix end

        if encoder.needs_2pass then
            local passlog_path = get_output_path("passlog_" .. os.time())
            local dev_null = package.config:sub(1,1) == "\\" and "NUL" or "/dev/null"
            
            -- Pass 1
            local p1_args = {unpack(args)}
            for _, arg in ipairs({"-map", string.format("%d:v:0", video_idx), "-c:v", encoder.c_v, "-vf", scale_cmd, "-b:v", v_bitrate, "-pass", "1", "-passlogfile", passlog_path, "-an", "-progress", progress_file, "-f", "null", dev_null}) do table.insert(p1_args, arg) end
            
            UI.start_tracking(progress_file, State.pos.duration, 1, 2)
            System.exec_async(p1_args, function(s1)
                UI.stop_tracking()
                if not s1 then
                    System.cleanup_temp_files(passlog_path)
                    return Media.execute_with_fallback(encoder_idx + 1, is_web, sources, output_file, callback)
                end
                
                -- Pass 2
                local p2_args = {unpack(args)}
                for _, arg in ipairs({"-c:v", encoder.c_v, "-vf", scale_cmd, "-b:v", v_bitrate, "-maxrate", v_bitrate, "-bufsize", v_bitrate, "-pass", "2", "-passlogfile", passlog_path}) do table.insert(p2_args, arg) end
                for _, arg in ipairs(encoder.web_args) do table.insert(p2_args, arg) end
                map_audio(p2_args, sources)
                for _, arg in ipairs({"-c:a", "aac", "-b:a", a_bitrate, "-progress", progress_file, output_file}) do table.insert(p2_args, arg) end
                
                UI.start_tracking(progress_file, State.pos.duration, 2, 2)
                System.exec_async(p2_args, function(s2)
                    UI.stop_tracking()
                    System.cleanup_temp_files(passlog_path)
                    if not s2 then return Media.execute_with_fallback(encoder_idx + 1, is_web, sources, output_file, callback) end
                    callback(true)
                end)
            end)
        else
            -- 1-Pass Hardware Web Encode
            for _, arg in ipairs({"-c:v", encoder.c_v, "-vf", scale_cmd, "-b:v", v_bitrate, "-maxrate", v_bitrate, "-bufsize", v_bitrate}) do table.insert(args, arg) end
            for _, arg in ipairs(encoder.web_args) do table.insert(args, arg) end
            map_audio(args, sources)
            for _, arg in ipairs({"-c:a", "aac", "-b:a", a_bitrate, "-progress", progress_file, output_file}) do table.insert(args, arg) end
            
            UI.start_tracking(progress_file, State.pos.duration, 1, 1)
            System.exec_async(args, function(s1)
                UI.stop_tracking()
                if not s1 then return Media.execute_with_fallback(encoder_idx + 1, is_web, sources, output_file, callback) end
                callback(true)
            end)
        end
    else
        local filter = encoder.filter_prefix and { "-vf", encoder.filter_prefix } or {}
        for _, arg in ipairs(filter) do table.insert(args, arg) end
        table.insert(args, "-c:v") table.insert(args, encoder.c_v)
        for _, arg in ipairs(encoder.standard_args) do table.insert(args, arg) end
        map_audio(args, sources)
        for _, arg in ipairs({"-c:a", "aac", "-b:a", "320k", "-progress", progress_file, output_file}) do table.insert(args, arg) end

        UI.start_tracking(progress_file, State.pos.duration, 1, 1)
        System.exec_async(args, function(success)
            UI.stop_tracking()
            if not success then return Media.execute_with_fallback(encoder_idx + 1, is_web, sources, output_file, callback) end
            callback(true)
        end)
    end
end

-- ============================================================================
-- 7. APPLICATION LOGIC & BINDS
-- ============================================================================
local function process_cut()
    local current_time = mp.get_property_number("time-pos")
    if not current_time then return end

    if not State.pos.start_time then
        State.pos.start_time = current_time
        return Logger.log(msg.info, string.format("Start marked: %s", to_timestamp(current_time)), 3)
    end

    State.pos.end_time = current_time
    if State.pos.start_time >= State.pos.end_time then
        State.reset_pos()
        return Logger.log(msg.error, "Invalid selection.", 3)
    end

    State.pos.duration = State.pos.end_time - State.pos.start_time
    
    local suffix = State.is_web_mode and "_web" or "_cut"
    local output = get_output_path(string.format("%s%s.%s", State.file.basename, suffix, Config.video_extension))

    local function start_encode(sources)
        Media.execute_with_fallback(1, State.is_web_mode, sources, output, function(success)
            if success then Logger.log(msg.info, string.format("Saved: %s", output), 5) end
            State.reset_pos()
            mp.set_property("keep-open", "no")
        end)
    end

    if State.file.is_remote then
        -- Resolve fresh direct URL(s) right now, since streamed links expire.
        Media.resolve_remote_source(State.file.path, function(ok, result)
            if not ok then
                Logger.log(msg.error, "Failed to resolve stream: " .. tostring(result), 5)
                State.reset_pos()
                return
            end
            start_encode(result)
        end)
    else
        start_encode({ { url = State.file.path, is_video = true, is_audio = true } })
    end
end

mp.register_event("file-loaded", function()
    State.file.path = mp.get_property("path")
    State.file.is_remote = is_url(State.file.path)

    if State.file.is_remote then
        State.file.directory = mp.get_property("working-directory") or ""
        State.file.basename = sanitize_filename(mp.get_property("media-title") or "stream")
    else
        State.file.filename = mp.get_property("filename")
        State.file.directory, _ = utils.split_path(State.file.path)
        State.file.basename = State.file.filename:match("^(.+)%..+$") or State.file.filename
    end

    mp.set_property("keep-open", "always")
    State.reset_pos()
end)

mp.add_key_binding(Config.key_mark_cut, "mark_pos", function() State.is_web_mode = false process_cut() end)
mp.add_key_binding(Config.web_key_mark_cut, "web_mark_pos", function() State.is_web_mode = true process_cut() end)

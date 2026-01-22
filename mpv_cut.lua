---@diagnostic disable: lowercase-global, undefined-global

msg = require("mp.msg")
utils = require("mp.utils")

-- #region globals
local settings = {
    key_mark_cut = "c",
    video_extension = "mp4",

    -- if you want faster cutting, leave this blank
    ffmpeg_custom_parameters = "",

    web = {
        -- small file settings
        key_mark_cut = "shift+c",

        audio_target_bitrate = 128, -- ((kbps))
        video_target_file_size = 8,  -- MB
        video_target_scale = "1280:-2" -- https://trac.ffmpeg.org/wiki/Scaling everything after "scale=" will be considered, keep "original" for no changes to the scaling
    }
}

local vars = {
    path = nil,
    filename = nil,
    only_filename = nil,
    directory = nil,

    is_web_mark_pos = nil,

    pos = {
        start_pos = nil,
        end_pos = nil,
        cut_duration = nil
    },
    
    -- Progress tracking
    progress = {
        is_encoding = false,
        current_pass = nil,
        total_passes = 1,
        progress_file = nil,
        progress_timer = nil,
        duration = nil
    }
}
-- #endregion

-- #region utils
function str_split(input, separator)
    if not separator then
        separator = "%s"
    end

    local t = {}
    for str in string.gmatch(input, "([^" .. separator .. "]+)") do
        table.insert(t, str)
    end

    return t
end

function to_timestamp(time)
    if not time or time < 0 then
        time = 0
    end
    
    local hrs = math.floor(time / 3600)
    local mins = math.floor((time % 3600) / 60)
    local secs = math.floor(time % 60)
    local centisecs = math.floor((time % 1) * 100)

    return string.format("%02d:%02d:%02d.%02d", hrs, mins, secs, centisecs)
end

function reset_pos()
    vars.pos.start_pos = nil
    vars.pos.end_pos = nil
    vars.pos.cut_duration = nil
end

function get_output_path(basename)
    -- Use the same directory as the input file
    if vars.directory then
        return utils.join_path(vars.directory, basename)
    end
    return basename
end

function exec_native(args)
    log(msg.info, string.format("Executing command: %s", table.concat(args, " ")))

    local ret = mp.command_native({
        name = "subprocess",
        args = args,
        capture_stdout = true,
        capture_stderr = true,
        playback_only = false
    })

    if ret.status == 0 then
        log(msg.info, string.format("Finished executing %s.", args[1]))
    else
        log(msg.error, string.format("Command failed: %s", args[1]))
    end

    return ret.status, ret.stdout, ret.stderr
end

function exec_async(args, callback)
    log(msg.info, string.format("Executing command (async): %s", table.concat(args, " ")))

    mp.command_native_async({
        name = "subprocess",
        args = args,
        capture_stdout = true,
        capture_stderr = true,
        playback_only = false
    }, function(success, result)
        if result.status ~= 0 then
            local err = result.stderr:gsub("^%s*(.-)%s*$", "%1")
            log(msg.error, string.format("Command failed: %s", args[1]), nil, err)
            if callback then callback(false, result) end
        else
            log(msg.info, string.format("Finished executing %s.", args[1]))
            if callback then callback(true, result) end
        end
    end)
end

function log(type, fmt, delay, log_msg)
    if delay and delay > 0 then
        mp.osd_message(fmt, delay)
    end

    if log_msg then
        local log_path = get_output_path("mpv-cut.log")
        local file_object = io.open(log_path, 'a')

        if not file_object then
            log(msg.error, "Unable to open log file for appending!")
            return
        end

        local timestamp = os.date("%Y-%m-%d %H:%M:%S")
        file_object:write(string.format("[%s] %s\n", timestamp, log_msg))
        file_object:close()
    end

    type(fmt)
end

function check_ffmpeg()
    local status, stdout, stderr = exec_native({"ffmpeg", "-version"})
    return status == 0
end

function cleanup_temp_files()
    local temp_files = {
        "ffmpeg2pass-0.log",
        "ffmpeg2pass-0.log.mbtree"
    }
    
    for _, file in ipairs(temp_files) do
        local file_path = get_output_path(file)
        local status, err_msg = os.remove(file_path)
        if not status and err_msg ~= "No such file or directory" then
            log(msg.warn, string.format("Could not remove temp file %s: %s", file, err_msg))
        end
    end
end

-- #region progress tracking
function parse_progress_file(progress_file)
    local file = io.open(progress_file, "r")
    if not file then
        return nil
    end
    
    local progress_data = {}
    for line in file:lines() do
        local key, value = line:match("([^=]+)=(.+)")
        if key and value then
            progress_data[key:gsub("^%s*(.-)%s*$", "%1")] = value:gsub("^%s*(.-)%s*$", "%1")
        end
    end
    file:close()
    
    return progress_data
end

function time_to_seconds(time_str)
    -- Parse time in format HH:MM:SS.microseconds or MM:SS.microseconds
    local parts = {}
    for part in time_str:gmatch("[^:]+") do
        table.insert(parts, tonumber(part))
    end
    
    if #parts == 3 then
        return parts[1] * 3600 + parts[2] * 60 + parts[3]
    elseif #parts == 2 then
        return parts[1] * 60 + parts[2]
    elseif #parts == 1 then
        return parts[1]
    end
    return 0
end

function update_progress_osd()
    if not vars.progress.is_encoding or not vars.progress.progress_file then
        return
    end
    
    local progress_data = parse_progress_file(vars.progress.progress_file)
    if not progress_data or not progress_data.frame then
        -- Show "Starting..." message while waiting for progress data
        local pass_info = ""
        if vars.progress.total_passes > 1 then
            pass_info = string.format("Pass %d/%d - ", vars.progress.current_pass or 1, vars.progress.total_passes)
        end
        mp.osd_message(string.format("%sStarting encoding...", pass_info), 0.1)
        return
    end
    
    local out_time = 0
    
    -- Try different time formats from ffmpeg progress
    if progress_data.out_time_ms then
        -- out_time_ms is in microseconds
        out_time = tonumber(progress_data.out_time_ms) / 1000000.0
    elseif progress_data.out_time then
        local time_str = progress_data.out_time
        if time_str:match(":") then
            out_time = time_to_seconds(time_str)
        else
            out_time = tonumber(time_str) or 0
        end
    end
    
    local duration = vars.progress.duration or 0
    local percent = 0
    if duration > 0 and out_time > 0 then
        percent = math.min(100, math.max(0, (out_time / duration) * 100))
    end
    
    local frame = progress_data.frame or "0"
    local fps = progress_data.fps or "0"
    local bitrate_kbps = "0"
    if progress_data.bitrate then
        -- bitrate is in bits/s, convert to kbps
        local bitrate_bps = tonumber(progress_data.bitrate) or 0
        bitrate_kbps = string.format("%.0f", bitrate_bps / 1000)
    end
    local speed = progress_data.speed or "1.0x"
    
    -- Calculate ETA
    local eta_str = "N/A"
    local speed_num = tonumber(speed:match("([%d.]+)")) or 1.0
    if duration > 0 and out_time > 0 and speed_num > 0 then
        local remaining = duration - out_time
        local eta_seconds = remaining / speed_num
        if eta_seconds > 0 and eta_seconds < 86400 then  -- Less than 24 hours
            local eta_h = math.floor(eta_seconds / 3600)
            local eta_m = math.floor((eta_seconds % 3600) / 60)
            local eta_s = math.floor(eta_seconds % 60)
            eta_str = string.format("%02d:%02d:%02d", eta_h, eta_m, eta_s)
        end
    end
    
    -- Build OSD text
    local pass_info = ""
    if vars.progress.total_passes > 1 then
        pass_info = string.format("Pass %d/%d - ", vars.progress.current_pass or 1, vars.progress.total_passes)
    end
    
    local status_text = string.format(
        "%sEncoding: %.1f%%\n" ..
        "Time: %s / %s | Speed: %s\n" ..
        "Frame: %s | FPS: %s | Bitrate: %s kbps\n" ..
        "ETA: %s",
        pass_info,
        percent,
        to_timestamp(out_time),
        to_timestamp(duration),
        speed,
        frame,
        fps,
        bitrate_kbps,
        eta_str
    )
    
    -- Draw progress bar
    local bar_width = 50
    local filled = math.floor(bar_width * percent / 100)
    local bar = string.rep("█", filled) .. string.rep("░", bar_width - filled)
    
    local osd_text = string.format("%s\n[%s]", status_text, bar)
    
    -- Display OSD
    mp.osd_message(osd_text, 0.1)
end

function start_progress_tracking(progress_file, duration, current_pass, total_passes)
    vars.progress.is_encoding = true
    vars.progress.progress_file = progress_file
    vars.progress.duration = duration
    vars.progress.current_pass = current_pass
    vars.progress.total_passes = total_passes or 1
    
    -- Clear/create progress file
    local file = io.open(progress_file, "w")
    if file then
        file:close()
    end
    
    -- Update OSD every 0.1 seconds
    vars.progress.progress_timer = mp.add_periodic_timer(0.1, update_progress_osd)
    update_progress_osd()
end

function stop_progress_tracking()
    vars.progress.is_encoding = false
    if vars.progress.progress_timer then
        vars.progress.progress_timer:kill()
        vars.progress.progress_timer = nil
    end
    
    -- Clean up progress file
    if vars.progress.progress_file then
        local status, err_msg = os.remove(vars.progress.progress_file)
        vars.progress.progress_file = nil
    end
    
    -- Clear OSD
    mp.osd_message("", 0)
end
-- #endregion
-- #endregion

-- #region main
function ffmpeg_cut(time_start, time_end, input_file, output_file, callback)
    local progress_file = get_output_path("ffmpeg_progress.txt")
    local cut_duration = vars.pos.cut_duration or 0
    
    local args = {"ffmpeg", "-y", "-ss", time_start, "-to", time_end, "-i", input_file}
    
    -- Add progress reporting
    table.insert(args, "-progress")
    table.insert(args, progress_file)
    
    -- Add custom parameters if specified and not in web mode
    if string.len(settings.ffmpeg_custom_parameters) > 0 and not vars.is_web_mark_pos then
        for substr in settings.ffmpeg_custom_parameters:gmatch("%S+") do
            table.insert(args, substr)
        end
    else
        -- Default: copy video, encode audio to AAC
        table.insert(args, "-c:v")
        table.insert(args, "copy")
        table.insert(args, "-c:a")
        table.insert(args, "aac")
        table.insert(args, "-b:a")
        table.insert(args, "320k")
    end
    
    table.insert(args, output_file)
    
    -- Start progress tracking
    start_progress_tracking(progress_file, cut_duration, 1, 1)
    
    -- Use async execution for progress tracking
    exec_async(args, function(success, result)
        stop_progress_tracking()
        
        if not success then
            local stderr = result.stderr:gsub("^%s*(.-)%s*$", "%1")
            log(msg.error, string.format("FFmpeg cut failed: %s", stderr), 10, stderr)
            if callback then callback(false) end
        else
            log(msg.info, "FFmpeg cut completed successfully", 3)
            if callback then callback(true) end
        end
    end)
    
    -- Return immediately for async execution
    return true
end

function ffmpeg_resize(input_file, output_file, callback)
    if not vars.pos.cut_duration or vars.pos.cut_duration <= 0 then
        log(msg.error, "Invalid cut duration!", 10)
        if callback then callback(false) end
        return false
    end
    
    local cut_duration = vars.pos.cut_duration
    log(msg.info, string.format("Cut duration: %.2f seconds", cut_duration))

    -- Calculate target bitrate (in kbps)
    -- Convert MB to bits: MB * 8 * 1024 * 1024 / duration (seconds) / 1000 = kbps
    local total_bitrate = (settings.web.video_target_file_size * 8192) / cut_duration
    local video_bitrate = total_bitrate - settings.web.audio_target_bitrate

    if video_bitrate < 100 then
        log(msg.error, string.format("Target video bitrate too low: %d kbps. Increase target file size or duration.", math.floor(video_bitrate)), 10)
        if callback then callback(false) end
        return false
    end

    local formatted_video_bitrate = string.format("%dk", math.floor(video_bitrate))
    log(msg.info, string.format("Target video bitrate: %s", formatted_video_bitrate), 5)

    -- Build video filter
    local vf, video_target_scale = "-vf", "scale=iw:ih"
    if settings.web.video_target_scale ~= "original" then
        video_target_scale = string.format("scale=%s", settings.web.video_target_scale)
    end

    local progress_file = get_output_path("ffmpeg_progress.txt")

    -- Two-pass encoding for better quality
    -- Pass 1: Analyze video (no audio, no output)
    local pass1_args = {
        "ffmpeg", "-y", "-i", input_file,
        "-c:v", "libx264",
        vf, video_target_scale,
        "-b:v", formatted_video_bitrate,
        "-pass", "1",
        "-an",
        "-progress", progress_file,
        "-f", "null"
    }
    
    -- Use /dev/null for Unix, NUL for Windows, or let ffmpeg handle it
    if package.config:sub(1,1) == "\\" then
        -- Windows
        table.insert(pass1_args, "NUL")
    else
        -- Unix-like
        table.insert(pass1_args, "/dev/null")
    end
    
    -- Start progress tracking for pass 1
    start_progress_tracking(progress_file, cut_duration, 1, 2)
    
    exec_async(pass1_args, function(success, result)
        stop_progress_tracking()
        
        if not success then
            local stderr = result.stderr:gsub("^%s*(.-)%s*$", "%1")
            log(msg.error, string.format("FFmpeg pass 1 failed: %s", stderr), 10, stderr)
            cleanup_temp_files()
            if callback then callback(false) end
            return
        end
        
        log(msg.info, "Pass 1 completed, starting pass 2...", 3)
        
        -- Pass 2: Encode with audio
        local pass2_args = {
            "ffmpeg", "-y", "-i", input_file,
            "-c:v", "libx264",
            vf, video_target_scale,
            "-b:v", formatted_video_bitrate,
            "-pass", "2",
            "-c:a", "aac",
            "-b:a", string.format("%dk", settings.web.audio_target_bitrate),
            "-progress", progress_file,
            output_file
        }
        
        -- Start progress tracking for pass 2
        start_progress_tracking(progress_file, cut_duration, 2, 2)
        
        exec_async(pass2_args, function(success2, result2)
            stop_progress_tracking()
            
            if not success2 then
                local stderr = result2.stderr:gsub("^%s*(.-)%s*$", "%1")
                log(msg.error, string.format("FFmpeg pass 2 failed: %s", stderr), 10, stderr)
                cleanup_temp_files()
                if callback then callback(false) end
                return
            end
            
            -- Clean up two-pass temp files
            cleanup_temp_files()
            
            log(msg.info, "Encoding completed successfully", 3)
            if callback then callback(true) end
        end)
    end)
    
    return true
end

function web_mark_pos()
    vars.is_web_mark_pos = true
    mark_pos(vars.is_web_mark_pos)
end

function mark_pos(is_web)
    local current_pos = mp.get_property_number("time-pos")
    
    if not current_pos then
        log(msg.error, "Could not get current position!", 3)
        return
    end

    msg.info(string.format("Current position: %s", to_timestamp(current_pos)))

    if not vars.pos.start_pos then
        vars.pos.start_pos = current_pos
        log(msg.info, string.format("Marked %s as start position", to_timestamp(current_pos)), 3)
        return
    end

    vars.pos.end_pos = current_pos

    if vars.pos.start_pos >= vars.pos.end_pos then
        log(msg.error, "Invalid time selected! End must be after start.", 3)
        reset_pos()
        return
    end

    -- Calculate duration correctly (end - start)
    vars.pos.cut_duration = vars.pos.end_pos - vars.pos.start_pos

    log(msg.info, string.format("Marked %s as end position (duration: %.2f s)", 
        to_timestamp(current_pos), vars.pos.cut_duration), 3)

    -- Generate output filename
    local base_name = vars.only_filename:match("^(.+)%..+$") or vars.only_filename
    local output_name = string.format("%s cut.%s", base_name, settings.video_extension)
    local output_path = get_output_path(output_name)

    -- Cut the video (async with callback)
    ffmpeg_cut(to_timestamp(vars.pos.start_pos), to_timestamp(vars.pos.end_pos), vars.path, output_path, function(success)
        if not success then
            log(msg.error, "Failed to cut video! Check log for details.", 10)
            reset_pos()
            return
        end

        -- Resize video if web mode
        if is_web then
            local output_name_resized = string.format("%s cutr.%s", base_name, settings.video_extension)
            local output_path_resized = get_output_path(output_name_resized)

            log(msg.info, "Starting encoding pass 2...", 3)

            ffmpeg_resize(output_path, output_path_resized, function(resize_success)
                if not resize_success then
                    log(msg.error, "Failed to resize video! Check log for details.", 10)
                    reset_pos()
                    vars.is_web_mark_pos = false
                    return
                end

                -- Remove intermediate cut file
                local status, err_msg = os.remove(output_path)
                if not status and err_msg ~= "No such file or directory" then
                    log(msg.warn, string.format("Could not delete intermediate file: %s", err_msg))
                end

                log(msg.info, string.format("Saved as %s", output_path_resized), 10)
                reset_pos()
                vars.is_web_mark_pos = false
                mp.set_property("keep-open", "no")
            end)
        else
            -- Reset vars
            reset_pos()
            mp.set_property("keep-open", "no")
            log(msg.info, string.format("Saved as %s", output_path), 10)
        end
    end)
end
-- #endregion

-- #region events
mp.register_event("file-loaded", function()
    local only_filename = mp.get_property("filename")
    local path = mp.get_property("path")
    local directory, filename = utils.split_path(path)

    mp.set_property("keep-open", "always")

    -- Populate variables
    vars.path = path
    vars.filename = filename
    vars.only_filename = only_filename
    vars.directory = directory
    
    -- Reset position markers for new file
    reset_pos()
    
    -- Check if ffmpeg is available
    if not check_ffmpeg() then
        log(msg.error, "FFmpeg not found! Please install ffmpeg.", 10)
    end
end)

mp.add_key_binding(settings.key_mark_cut, "mark_pos", mark_pos)
mp.add_key_binding(settings.web.key_mark_cut, "web_mark_pos", web_mark_pos)
-- #endregion

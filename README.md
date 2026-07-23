# mpv-cut
A video cutting/clipping/slicing script for [mpv](https://mpv.io/)

## Features
- Frame-accurate standard and web cutting using `c` and `shift` + `c`.
- GPU hardware-accelerated encoding (AMD AMF / VA-API) with automatic fallback to optimized software encoding (`libx264`).
- Ensures 100% compatibility with Discord and web platforms by enforcing H.264 and YUV420P.
- Live OSD progress tracking showing percentage, elapsed time, processing speed, and pass info.
- You're able to input custom FFmpeg parameters in the cutting process.

## Installation
### Linux
Place it inside the Linux mpv scripts folder normally on: `~/.config/mpv/scripts`, and install the FFmpeg package if not already installed.
- Ubuntu: `sudo apt install ffmpeg`
- Arch: `sudo pacman -S ffmpeg` or `yay -S ffmpeg`

### Windows
Place it inside the Windows mpv scripts folder normally on `%appdata%\mpv\scripts`, and install the FFmpeg package if not already installed with [Chocolatey](https://chocolatey.org/install).
- Chocolatey (open cmd/powershell as admin): `choco install ffmpeg-full` or `cinst ffmpeg-full`

## Usage
Press the default key `C` to mark the first position, and where you desire to save, on the last position, press `C` again.  
Use `Shift+C` for cutting with a smaller, web-optimized file size.

## Settings
The settings can be changed by editing the [script](https://github.com/b1scoito/mpv-cut/blob/main/mpv_cut.lua#L7) file.

### Further explanation

- `key_mark_cut`: The key for standard cutting.
- `web_key_mark_cut`: The key for cutting with a shareable web file size.
- `video_extension`: The output extension of the video.
- `ffmpeg_custom_parameters`: FFmpeg custom parameters to use.
- `web.audio_target_bitrate`: Target audio bitrate for the web cut.
- `web.video_target_file_size`: Target file size for the web cut.
- `web.video_target_scale`: Target video scale (https://trac.ffmpeg.org/wiki/Scaling), keep "original" for no changes to the scaling.
- `web.min_video_bitrate`: Hard floor bitrate to protect against encoder crashes on oversized clips.

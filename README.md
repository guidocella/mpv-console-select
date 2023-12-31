This depends on the unmerged https://github.com/mpv-player/mpv/pull/10282

Use the console to select a playlist entry, track, chapter, or subtitle line to seek to by typing part of the desired option and/or by navigating the options with the keyboard.

The default keybindings are:

- `script-binding select-playlist`: `g-p`
- `script-binding select-track`: `g-t`
- `script-binding select-secondary-sub`: `g-j`
- `script-binding select-chapter`: `g-c`
- `script-binding sub-seek`: `g-s` (requires `ffmpeg` in `PATH`, or in the same directory as mpv on Windows)

The keybindings to navigate the options are:

- Go down: `Down`, `Ctrl+j`, `Ctrl+n`
- Go up: `Up`, `Ctrl+k`, `Ctrl+p`
- Scroll down one page: `Page down`, `Ctrl+f`
- Scroll up one page: `Page up`, `Ctrl+b`

`select-playlist` also binds `Ctrl+Shift+d` to removing the selected entry from the playlist.

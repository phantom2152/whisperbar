# WhisperBar

A tiny menu bar app that runs your local `whisper-server` and lets you dictate: click the icon, press the mic, speak, get text.
Built with plain Swift + AppKit. No Xcode project; Command Line Tools are enough.

## Build & run

    ./build.sh

Creates `WhisperBar.app` (with icon, mic permission string, ad-hoc signature) and launches it.
Stable signing (keeps the mic permission across rebuilds): create a self-signed code-signing
certificate in Keychain Access, then `SIGN_ID="Your Cert Name" ./build.sh`.

## Configure

Paths, port and history size: `Sources/WhisperBar/Config.swift`.
Model, language, start-on-launch and auto-copy: the gear icon in the tile.

## Layout

    Sources/WhisperBar/
      main.swift                 entry point
      AppDelegate.swift          status item, tile open/close, signals, Esc
      PanelViewController.swift  the tile: home / history / permission screens
      ServerController.swift     whisper-server process lifecycle + readiness probe
      AudioRecorder.swift        16 kHz mono WAV recording + level metering
      TranscriptionClient.swift  multipart POST to /inference
      TranscriptStore.swift      saved takes (~/Library/Application Support/WhisperBar)
      ExportController.swift     Save as .txt / .md, Share…
      TranscriptRow.swift        one row in History
      Components.swift           IconButton, layout + format helpers
      MenuBarIcon.swift          menu bar glyph drawn in code (off / ready / recording)
      WaveformView.swift         live level meter
      Config.swift               fixed paths + defaults
      Settings.swift             saved choices (model, language, …) + model scanner
      WhisperInfo.swift          reads the whisper.cpp version for the footer
    Resources/                   AppIcon.icns, AppIcon-1024.png, icon-preview.png
    Tools/make_icon.py           regenerates the icons (pip install pillow numpy)

Logs: `/tmp/whisperbar.log` (also behind the log button in the tile).

## License

WhisperBar is licensed under the [MIT License](LICENSE).

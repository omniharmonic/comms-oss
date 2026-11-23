# Network marks: attribution

The vector paths in `NetworkMarks.swift` (WhatsApp, Telegram, Messenger, X, Discord, Matrix, Signal, Slack, Instagram, LinkedIn, and the Messages bubble from the iMessage mark) are transcribed from **Simple Icons v13.21.0** (<https://github.com/simple-icons/simple-icons>). The badge colours in `design/tokens.json` (`brand`) come from the same release, with two exceptions:

- Signal uses `#3A76F0`, the blue of Signal's own app icon (Simple Icons' `#3B45FD` is the website's violet-leaning blue, not what people see on their home screen).
- Slack's hash is drawn in its four brand colours (`#36C5F0`, `#2EB67D`, `#ECB22E`, `#E01E5A`, Slack media kit) on a white disc; Simple Icons' single path is split into its four bars for that. `brand.slack` (`#4A154B`, aubergine) is used only where one colour is needed.

- Simple Icons is released under **CC0 1.0 Universal** (public domain dedication): <https://creativecommons.org/publicdomain/zero/1.0/>.
- The marks themselves are trademarks of their respective owners (Meta, Telegram, X Corp., Discord, The Matrix.org Foundation, Signal Technology Foundation, Slack Technologies / Salesforce, Meta (Instagram), LinkedIn / Microsoft, Apple). Comms uses them only nominatively, to show which network a conversation is on, and follows each owner's brand guidelines as linked in Simple Icons' data.
- Generic email uses the SF Symbol `envelope.fill`; SMS has no brand and reuses the Messages bubble on a neutral grey.

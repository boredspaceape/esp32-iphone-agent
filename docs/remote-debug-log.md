# Remote debug log

**English** | [简体中文](remote-debug-log.zh-CN.md)

Pull the app's **text** debug log (`Documents/logs/debug.log`) from your own iPhone when you can't reach it, for
example on cellular with the board plugged in. The iPhone can't accept connections, so the app polls a small
server you run; you file a request there and the app uploads the asked-for tail of the log.

- **Off by default.** Settings › Developer › Remote debug log: endpoint URL and token. Both empty = no network
  calls at all. The token is kept in the Keychain; neither value is in the settings backup.
- **Text only.** Only lines of debug.log go out, never screenshots, video or run files. Before upload the app removes
  the model key, other stored keys, the channel token, anything shaped like a token, `Authorization` header
  or `key=…` pair, inline images, IP addresses and typed text.
- **When it polls:** about every 30 s while the app is open or a run is going (no extra background mode).
- **Setting it without typing:** put `remote-debug-log.json` with `{"url": "https://…", "token": "…"}` in the
  app's Documents (Finder › iPhone › Files, or
  `xcrun devicectl device copy to --device <id> --domain-type appDataContainer --domain-identifier <bundle id> --source remote-debug-log.json --destination Documents/remote-debug-log.json`).
  The app imports it within ~30 s and deletes the file.

## Server API (self-host)

Any HTTPS server works, e.g. a Cloudflare Worker with a private R2 bucket. `<url>` is the endpoint URL from the app.

| Route | Request | Reply |
|---|---|---|
| `POST <url>/poll` | `Authorization: Bearer <token>`, body `{}` | `{"want": {"id": "ab12cd34", "minutes": 5}}` (or `"lines": 2000`), or `{}` for nothing to do |
| `POST <url>/upload` | `Authorization: Bearer <token>`, `Content-Type: text/plain; charset=utf-8`, `X-Request-Id: <want.id>`, body = the log text (≤ 1.9 MB) | `200` on success |

`minutes` = lines stamped within the last N minutes; `lines` = the last N lines. A server should compare tokens in
constant time, refuse bodies that aren't UTF-8 text, cap the size (2 MB), rate-limit uploads and delete old logs.
An admin side (file a request, list and read uploads) is up to you.

```sh
# what the app sends
curl -X POST -H "Authorization: Bearer $TOKEN" -d '{}' https://logs.example.com/poll
curl -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: text/plain; charset=utf-8" \
     -H "X-Request-Id: ab12cd34" --data-binary @tail.log https://logs.example.com/upload
```

## Remote tasks (this fork)

Separate from the debug log. Settings › Developer › Remote tasks has its own **Allow remote tasks** switch (off by
default), server URL and token (Keychain account `remote-tasks-token`). The debug-log token and a dropped
`remote-debug-log.json` never turn it on. When on, the app polls about every 15 s while nothing runs (also in the
background while the board is connected), posts a local notification for each task, runs it unattended and posts
the final answer back **unredacted**.

| Route | Request | Reply |
|---|---|---|
| `POST <url>/task` | `Authorization: Bearer <token>`, body `{}` | `{"task": {"id": "t1", "text": "…"}}` or `{}`; id ≤ 64 chars of `A-Z a-z 0-9 - _` |
| `POST <url>/result` | `{"id", "outcome": "done\|failed\|stopped\|not_started\|unknown", "answer", "steps", "seconds", "run"}` | `200` |

"continue" and phone-call tasks are refused (`not_started`). A result is retried until the server answers 200.
The server should give each task its own timeout: a task can be lost if the `/task` reply never arrives.

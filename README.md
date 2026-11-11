# MoneyPrinterTurbo on Railway

[MoneyPrinterTurbo](https://github.com/harry0703/MoneyPrinterTurbo) turns a topic into a finished short video: an LLM writes the script, stock footage is matched to it, a voice reads it, subtitles are burned in. This repository packages it for [Railway](https://railway.com) as one service with a volume.

<p align="center"><img src="assets/icon.png" width="96" alt=""></p>

## What this template adds

| | Stock MoneyPrinterTurbo image | This template |
|---|---|---|
| Web UI | No login: anyone with the URL can use your API keys | Login with a generated password (works in Safari too) |
| REST API | Open unless you configure a key | On, behind a generated API key (`x-api-key`) |
| Version | `latest` | Pinned release (v1.3.10), dependencies locked by hash |
| Bundled music | Tracks upstream says come from YouTube videos | Removed |
| Bundled fonts | Includes Microsoft YaHei and STHeiti, which may not be redistributed | Removed; Noto Sans CJK (open license) is the default |
| Settings and videos | Lost on redeploy unless you mount two paths | One volume at `/data` holds everything |
| Runs as | root | An unprivileged user |

## Deploy

1. Deploy the template on Railway. Nothing needs to be filled in.
2. Open the service's public URL. Log in as `admin` with the `WEBUI_PASSWORD` value from the service's **Variables** tab.
3. In **Settings**, choose your LLM provider and paste its API key, then add a free [Pexels](https://www.pexels.com/api/) API key for stock footage.
4. Type a subject and press **Generate Video**.

The default voice service (Edge TTS) needs no key. See [Good to know](#good-to-know) before you publish videos made with it.

## Variables

All are optional. The template generates the two secrets for you.

| Variable | Default | What it does |
|---|---|---|
| `WEBUI_USERNAME` | `admin` | Login name for the web UI |
| `WEBUI_PASSWORD` | generated | Login password for the web UI |
| `MPT_API_KEY` | generated | Key for the REST API, sent as the `x-api-key` header |
| `LLM_PROVIDER` | *(web UI setting)* | `openai`, `gemini`, `deepseek`, `anthropic`, `moonshot`, ... |
| `LLM_API_KEY` | | API key for that provider |
| `LLM_MODEL` | | Model name, spelled the way your provider spells it |
| `LLM_BASE_URL` | | Only for a proxy or a self-hosted, OpenAI-compatible server |
| `PEXELS_API_KEYS` | | One or more Pexels keys, comma-separated |
| `PIXABAY_API_KEYS` | | One or more Pixabay keys, comma-separated |
| `MPT_TASK_RETENTION_DAYS` | `0` | Delete generated videos and cached footage older than this many days. `0` keeps everything |

A variable that is set wins over the same setting in the web UI at every start. Leave the `LLM_*` and `*_API_KEYS` variables empty if you prefer to manage those settings in the web UI.

If you deploy this repository without the template and leave `WEBUI_PASSWORD` or `MPT_API_KEY` empty, a value is generated on the first start, printed once in the deploy logs and kept on the volume.

## Using the API

Interactive documentation is at `/docs` on your domain. Every call needs the `x-api-key` header:

```bash
curl -X POST "https://<your-domain>/api/v1/videos" \
  -H "x-api-key: $MPT_API_KEY" -H "Content-Type: application/json" \
  -d '{"video_subject": "Why octopuses have three hearts", "video_aspect": "9:16", "voice_name": "en-US-AriaNeural-Female"}'
```

The answer contains a `task_id`. Poll `GET /api/v1/tasks/<task_id>` until `progress` is 100; the finished files are listed there and are downloaded with the same header.

From another service in the same Railway project (n8n, for example), use the private network instead of the public domain: `http://${{MoneyPrinterTurbo.RAILWAY_PRIVATE_DOMAIN}}:${{MoneyPrinterTurbo.PORT}}`.

The API reads its settings when the service starts. After changing providers or keys in the web UI, restart the service so the API uses them too.

## Good to know

- **Background music.** None is bundled. Upload your own tracks in the web UI (Audio Settings, Background Music Source, Custom), and only music you have the right to use, or pick one of the AI music services there. Until you do, videos are made without music.
- **Fonts.** Noto Sans CJK (Latin, Chinese, Japanese, Korean), Be Vietnam Pro and Charm are included, all under the SIL Open Font License. To add a font, put a `.ttf` or `.ttc` file in `/data/resource/fonts`.
- **Edge TTS.** The default, keyless voice service uses the read-aloud voices of Microsoft Edge through an unofficial interface. It works well, but Microsoft does not offer it as a product. For commercial work, consider one of the official voice services in the list (Azure Speech, ElevenLabs, ...).
- **Stock footage.** Pexels and Pixabay are free; their own terms apply to what you publish.
- **What you publish is yours to answer for.** Check each platform's rules on AI-generated content.
- **Disk space.** Every video stays on the volume until you delete it in the Task Manager, or set `MPT_TASK_RETENTION_DAYS`. Railway's Hobby plan gives a volume 5 GB.
- **Memory.** Rendering needs about 2 GB of RAM. Railway's Trial plan caps a service at 1 GB, so use the Hobby plan or higher.

## How it is built

- `Dockerfile` downloads the pinned MoneyPrinterTurbo release, runs `scripts/prepare-source.sh` on it (which removes the files that are not freely licensed and fails the build if the release layout changed), and installs the Python dependencies from upstream's lock file with hash checking.
- `entrypoint.sh` fixes the volume's ownership, drops root, resolves the login and API key, and supervises three processes: the web UI (Streamlit), the API (FastAPI) and Caddy. If one stops, the container stops and Railway restarts it.
- `bootstrap.py` writes `config.toml` on the volume from your variables. It only touches the keys listed at the top of the file, so settings made in the web UI are kept.
- `Caddyfile` is the only public listener. The web UI and the API listen on `127.0.0.1`.

`scripts/smoke-test.sh <url> <webui-password> <api-key>` checks a deployment's login, cookie and API key without making a video.

## Updating MoneyPrinterTurbo

Change `MPT_VERSION` and `MPT_COMMIT` at the top of the `Dockerfile` to a newer [release](https://github.com/harry0703/MoneyPrinterTurbo/releases) and redeploy. Your settings and videos on the volume are kept.

## License and credits

MoneyPrinterTurbo is Copyright (c) 2024 Harry and MIT-licensed. The packaging in this repository is MIT-licensed too. `NOTICE` lists what was changed and the licenses of the bundled fonts.

This is a community template. It is not affiliated with or endorsed by the MoneyPrinterTurbo project.

# Text for the Railway template form

Copy each block into the matching field when you publish the template.

---

## Name

```
MoneyPrinterTurbo | AI Short Video Generator with Login & API
```

## Short description

```
AI short videos from a topic. Password-protected web UI and REST API.
```

## Category

```
AI/ML
```

## Icon

```
https://raw.githubusercontent.com/jean82290/moneyprinterturbo-railway/main/assets/icon.png
```

## Overview (Markdown)

```markdown
# Deploy and Host MoneyPrinterTurbo on Railway

MoneyPrinterTurbo is an open-source AI short-video generator. Give it a topic: an LLM writes the script, stock footage is matched to it, a voice reads it and subtitles are burned in. You get a finished vertical or horizontal video for TikTok, Reels or YouTube Shorts.

## About Hosting MoneyPrinterTurbo

This template builds the pinned MoneyPrinterTurbo release (v1.3.10) from source and runs it as one service with a Railway volume at `/data` for your settings, uploads and videos.

Things a bare MoneyPrinterTurbo deploy gets wrong on a public URL, handled here:

- **Anyone could use it.** Upstream's web UI has no login, so a stranger with the URL can spend your LLM credits. Here it sits behind a login with a generated password, and it works in Safari and on iPhone too.
- **The API would be open.** The REST API is on, behind a generated key (`x-api-key` header), so n8n, Make or your own code can order videos.
- **It would ship files nobody may redistribute.** Upstream bundles background music it says was taken from YouTube videos, and fonts owned by Microsoft and SinoType. This template removes them and uses Noto Sans CJK, an open font that covers Latin, Chinese, Japanese and Korean.
- **It would forget everything.** Settings and videos live on the volume and survive redeploys. The app runs as an unprivileged user.
- **It would drift.** The release is pinned and every Python dependency is installed from upstream's lock file with hash checking, so today's deploy and next month's are the same.

## Common Use Cases

- Faceless short-video channels: turn a list of topics into TikTok, Reels and Shorts videos
- Automated content pipelines: order videos from n8n, Make or a script through the REST API
- Marketing teams: quick product explainers and social clips in many languages, with subtitles
- Trying AI video without installing Python, FFmpeg and ImageMagick on your own computer

## Dependencies for MoneyPrinterTurbo Hosting

- An API key for one LLM provider (OpenAI, Gemini, DeepSeek, Anthropic, Moonshot and many more), to write scripts
- A free Pexels or Pixabay API key, for stock footage
- A Railway volume mounted at `/data` (included)
- Railway Hobby plan or higher: rendering needs about 2 GB of RAM

### Deployment Dependencies

- MoneyPrinterTurbo (MIT): https://github.com/harry0703/MoneyPrinterTurbo
- Pexels API keys: https://www.pexels.com/api/
- Template source, variables and smoke test: https://github.com/jean82290/moneyprinterturbo-railway

### Implementation Details

First use:

1. Open the public URL and log in as `admin` with the `WEBUI_PASSWORD` value from the service's Variables tab.
2. In Settings, choose your LLM provider and paste its key, then add your Pexels key. You can also set them at deploy time with `LLM_PROVIDER`, `LLM_API_KEY`, `LLM_MODEL` and `PEXELS_API_KEYS`.
3. Type a subject and press Generate Video.

Order a video through the API (interactive docs at `/docs`):

    curl -X POST "https://<your-domain>/api/v1/videos" \
      -H "x-api-key: <MPT_API_KEY>" -H "Content-Type: application/json" \
      -d '{"video_subject": "Why octopuses have three hearts", "video_aspect": "9:16"}'

Good to know:

- No background music is bundled. Upload your own tracks in the web UI, or use one of the AI music services there.
- The default voice service, Edge TTS, needs no key but is an unofficial interface to Microsoft Edge's voices. Official voice services (Azure Speech, ElevenLabs and others) are in the same list.
- Videos stay on the volume until you delete them. Set `MPT_TASK_RETENTION_DAYS` to clean up automatically.
- The API reads its settings at start-up: restart the service after changing providers or keys in the web UI.

This is a community-maintained template, not affiliated with the MoneyPrinterTurbo project. You are responsible for the content you generate and publish.

## Why Deploy MoneyPrinterTurbo on Railway?

Railway is a singular platform to deploy your infrastructure stack. Railway will host your infrastructure so you don't have to deal with configuration, while allowing you to vertically and horizontally scale it.

By deploying MoneyPrinterTurbo on Railway, you are one step closer to supporting a complete full-stack application with minimal burden. Host your servers, databases, AI agents, and more on Railway.
```

## Service settings to enter in the template composer

| Setting | Value |
|---|---|
| Service name | `MoneyPrinterTurbo` |
| Source | GitHub repository `jean82290/moneyprinterturbo-railway` |
| Volume mount path | `/data` |
| Public networking | HTTP, target port `8080` |
| Healthcheck path | `/healthz` (also set by `railway.json`) |
| Restart policy | On failure (also set by `railway.json`) |

| Variable | Value | Notes |
|---|---|---|
| `PORT` | `8080` | |
| `WEBUI_USERNAME` | `admin` | |
| `WEBUI_PASSWORD` | `${{secret(24)}}` | |
| `MPT_API_KEY` | `${{secret(48)}}` | |
| `LLM_PROVIDER` | *(empty)* | optional: `openai`, `gemini`, `deepseek`, `anthropic`, ... |
| `LLM_API_KEY` | *(empty)* | optional |
| `LLM_MODEL` | *(empty)* | optional |
| `PEXELS_API_KEYS` | *(empty)* | optional |
| `MPT_TASK_RETENTION_DAYS` | `0` | optional |

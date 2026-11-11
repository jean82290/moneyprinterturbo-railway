#!/usr/bin/env python3
"""End-to-end self-test: make one short video through the local API.

It needs no LLM key and no stock-footage key: the script is supplied, the
footage is a test pattern generated with FFmpeg, and the voice is Edge TTS
(keyless). A pass means FFmpeg, the fonts, the voice service, subtitles and
rendering all work in this deployment.

Run it one of two ways:
  * set the variable MPT_SELFTEST=1 and redeploy: it runs once after start-up
    and reports in the deploy logs (remove the variable afterwards);
  * or from `railway ssh`:  python /opt/railway/selftest.py

The finished video stays in the Task Manager so you can watch it. Pass
--delete to remove it once checked.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path

import toml

DATA_DIR = Path(os.environ.get("MPT_HOME") or os.environ.get("MPT_DATA_DIR", "/data"))
SCRIPT = (
    "This is a test video made by the Railway template. "
    "If you can hear this voice and read these subtitles, everything works."
)
TIMEOUT_SECONDS = 900


def log(message: str) -> None:
    print(f"mpt-selftest: {message}", flush=True)


def load_api() -> tuple[str, str]:
    with open(DATA_DIR / "config.toml", encoding="utf-8-sig") as handle:
        config = toml.load(handle)
    port = int(config.get("listen_port", 8502))
    return f"http://127.0.0.1:{port}", str(config.get("app", {}).get("api_key", ""))


def call(base: str, key: str, method: str, path: str, body: bytes | None = None,
         content_type: str = "application/json") -> dict:
    request = urllib.request.Request(base + path, data=body, method=method)
    request.add_header("x-api-key", key)
    if body is not None:
        request.add_header("Content-Type", content_type)
    try:
        with urllib.request.urlopen(request, timeout=120) as response:
            return json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", "replace")[:500]
        raise RuntimeError(f"{method} {path} answered {exc.code}: {detail}") from exc


def make_test_clip(path: Path) -> None:
    subprocess.run(
        [
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "testsrc2=size=1080x1920:rate=30:duration=10",
            "-c:v", "libx264", "-preset", "veryfast", "-pix_fmt", "yuv420p", str(path),
        ],
        check=True,
    )


def upload(base: str, key: str, clip: Path) -> str:
    boundary = uuid.uuid4().hex
    body = (
        f"--{boundary}\r\n"
        f'Content-Disposition: form-data; name="file"; filename="{clip.name}"\r\n'
        "Content-Type: video/mp4\r\n\r\n"
    ).encode() + clip.read_bytes() + f"\r\n--{boundary}--\r\n".encode()
    answer = call(base, key, "POST", "/api/v1/video_materials", body,
                  f"multipart/form-data; boundary={boundary}")
    return answer["data"]["file"]


def probe(path: Path) -> str:
    try:
        out = subprocess.run(
            ["ffprobe", "-v", "error", "-show_entries",
             "format=duration:stream=codec_type,codec_name,width,height",
             "-of", "json", str(path)],
            check=True, capture_output=True, text=True,
        ).stdout
        info = json.loads(out)
        streams = info.get("streams", [])
        video = next((s for s in streams if s.get("codec_type") == "video"), {})
        audio = next((s for s in streams if s.get("codec_type") == "audio"), {})
        duration = float(info.get("format", {}).get("duration", 0))
        return (f"{video.get('width')}x{video.get('height')} {video.get('codec_name')}, "
                f"audio {audio.get('codec_name', 'MISSING')}, {duration:.1f} s, "
                f"{path.stat().st_size / 1_000_000:.1f} MB")
    except Exception as exc:  # noqa: BLE001 - diagnostics only
        return f"could not probe ({exc})"


def main() -> int:
    delete_after = "--delete" in sys.argv[1:]
    base, key = load_api()
    started = time.monotonic()

    with tempfile.TemporaryDirectory() as temp:
        clip = Path(temp) / "selftest-pattern.mp4"
        make_test_clip(clip)
        stored = upload(base, key, clip)
    log(f"test footage uploaded as {stored}")

    task = call(base, key, "POST", "/api/v1/videos", json.dumps({
        "video_subject": "Railway template self-test",
        "video_script": SCRIPT,
        "video_terms": "test",
        "video_aspect": "9:16",
        "video_source": "local",
        "video_materials": [{"provider": "local", "url": stored}],
        "video_clip_duration": 3,
        "video_count": 1,
        "voice_name": "en-US-AriaNeural-Female",
        "bgm_type": "",
        "subtitle_enabled": True,
    }).encode())
    task_id = task["data"]["task_id"]
    log(f"video task {task_id} started (voice: Edge TTS, subtitles on)")

    last_progress = -1
    while True:
        if time.monotonic() - started > TIMEOUT_SECONDS:
            log(f"FAILED: no result after {TIMEOUT_SECONDS} s")
            return 1
        time.sleep(5)
        data = call(base, key, "GET", f"/api/v1/tasks/{task_id}")["data"]
        progress = int(data.get("progress") or 0)
        if progress != last_progress:
            log(f"progress {progress}%")
            last_progress = progress
        state = data.get("state")
        if state == -1:
            log(f"FAILED at stage {data.get('failed_stage')!r}: {data.get('error')!r}")
            return 1
        if state == 1:
            break

    task_dir = DATA_DIR / "storage" / "tasks" / task_id
    finals = sorted(task_dir.glob("final-*.mp4"))
    if not finals:
        log(f"FAILED: the task finished but {task_dir} holds no final video")
        return 1
    elapsed = time.monotonic() - started
    log(f"PASSED in {elapsed:.0f} s: {finals[0].name} is {probe(finals[0])}")
    subtitle = task_dir / "subtitle.srt"
    if subtitle.is_file():
        log(f"subtitles: {len(subtitle.read_text(encoding='utf-8').strip().splitlines())} lines in subtitle.srt")
    else:
        log("WARNING: no subtitle.srt was produced")
    if delete_after:
        call(base, key, "DELETE", f"/api/v1/tasks/{task_id}")
        log("test video deleted")
    else:
        log("the test video is in the web UI's Task Manager; delete it there when you are done")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:  # noqa: BLE001 - report and fail
        log(f"FAILED: {exc}")
        sys.exit(1)

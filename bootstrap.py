#!/usr/bin/env python3
"""Prepare MoneyPrinterTurbo's config.toml from Railway variables.

Runs on every boot, before the web UI and the API start. It never throws away
settings you made in the web UI: it creates config.toml on the first boot, and
afterwards only touches the few keys listed below.

Always enforced (the template depends on them):
  listen_host, listen_port   the API listens on 127.0.0.1 behind Caddy
  app.api_key                the API key (MPT_API_KEY)

Applied when the variable is set (the variable wins over the web UI):
  LLM_PROVIDER      app.llm_provider            e.g. openai, gemini, deepseek
  LLM_API_KEY       app.<provider>_api_key
  LLM_MODEL         app.<provider>_model_name
  LLM_BASE_URL      app.<provider>_base_url
  PEXELS_API_KEYS   app.pexels_api_keys         comma-separated
  PIXABAY_API_KEYS  app.pixabay_api_keys        comma-separated

Set once, when config.toml is created:
  log_level                  INFO instead of upstream's DEBUG
"""

from __future__ import annotations

import json
import os
import shutil
import sys
import tempfile
from pathlib import Path

import toml

APP_DIR = Path(os.environ.get("MPT_APP_DIR", "/app"))
DATA_DIR = Path(os.environ.get("MPT_HOME") or os.environ.get("MPT_DATA_DIR", "/data"))
CONFIG_FILE = DATA_DIR / "config.toml"
TEMPLATE_FILE = APP_DIR / "config.example.toml"


def log(message: str) -> None:
    print(f"mpt-railway: {message}", flush=True)


def die(message: str) -> None:
    print(f"mpt-railway: ERROR: {message}", file=sys.stderr, flush=True)
    sys.exit(1)


class _Encoder(toml.TomlEncoder):
    """Write strings the way MoneyPrinterTurbo's own save_config() does.

    toml 0.10.2 mis-escapes some backslashes; upstream works around it by
    emitting JSON strings, which are valid TOML basic strings. Doing the same
    here keeps the file byte-compatible with what the web UI writes.
    """

    def __init__(self) -> None:
        super().__init__()
        self.dump_funcs[str] = self._dump_str

    @staticmethod
    def _dump_str(value: object) -> str:
        return json.dumps(str(value), ensure_ascii=False).replace("\x7f", "\\u007f")


def env(name: str) -> str:
    return os.environ.get(name, "").strip()


def split_keys(value: str) -> list[str]:
    return [item.strip() for item in value.replace("\n", ",").split(",") if item.strip()]


def known_providers() -> set[str]:
    """Provider ids from MoneyPrinterTurbo's own registry (empty if it moved)."""
    try:
        sys.path.insert(0, str(APP_DIR))
        from app.models.llm_provider import LLM_PROVIDER_REGISTRY

        return {spec.provider_id for spec in LLM_PROVIDER_REGISTRY}
    except Exception:  # noqa: BLE001 - only used for a friendlier warning
        return set()
    finally:
        if sys.path and sys.path[0] == str(APP_DIR):
            sys.path.pop(0)


def load_config() -> tuple[dict, bool]:
    created = False
    if not CONFIG_FILE.is_file():
        if not TEMPLATE_FILE.is_file():
            die(f"{TEMPLATE_FILE} is missing from the image")
        DATA_DIR.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(TEMPLATE_FILE, CONFIG_FILE)
        os.chmod(CONFIG_FILE, 0o600)
        created = True
    try:
        # utf-8-sig: tolerate a byte-order mark left by a Windows editor.
        with open(CONFIG_FILE, encoding="utf-8-sig") as handle:
            return toml.load(handle), created
    except (toml.TomlDecodeError, UnicodeError, OSError) as exc:
        die(
            f"{CONFIG_FILE} cannot be read ({exc}). Fix it, or delete it to start "
            "from the defaults (your videos are not affected)."
        )
    raise AssertionError("unreachable")


def save_config(data: dict) -> None:
    serialized = toml.dumps(data, encoder=_Encoder())
    fd, temp_path = tempfile.mkstemp(prefix=".config-", suffix=".toml.tmp", dir=DATA_DIR)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(serialized)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temp_path, 0o600)
        os.replace(temp_path, CONFIG_FILE)
    finally:
        if os.path.exists(temp_path):
            os.remove(temp_path)


def main() -> None:
    api_key = env("MPT_API_KEY")
    if not api_key:
        die("MPT_API_KEY is empty (the entrypoint should have set it)")
    try:
        api_port = int(env("MPT_API_PORT") or "8502")
    except ValueError:
        die("MPT_API_PORT must be a number")

    data, created = load_config()
    before = json.dumps(data, sort_keys=True, default=str)
    app = data.setdefault("app", {})
    if not isinstance(app, dict):
        die("[app] in config.toml is not a table")

    # Always enforced.
    data["listen_host"] = "127.0.0.1"
    data["listen_port"] = api_port
    app["api_key"] = api_key

    if created:
        data["log_level"] = "INFO"

    # Variables win over the web UI when they are set.
    provider = env("LLM_PROVIDER").lower()
    if provider:
        providers = known_providers()
        if providers and provider not in providers:
            log(
                f"WARNING: LLM_PROVIDER={provider!r} is not a provider this release knows. "
                f"Known: {', '.join(sorted(providers))}"
            )
        app["llm_provider"] = provider
    active_provider = str(app.get("llm_provider") or "").strip()
    for variable, suffix in (
        ("LLM_API_KEY", "api_key"),
        ("LLM_MODEL", "model_name"),
        ("LLM_BASE_URL", "base_url"),
    ):
        value = env(variable)
        if not value:
            continue
        if not active_provider:
            log(f"WARNING: {variable} is set but no LLM provider is selected; ignored")
            continue
        app[f"{active_provider}_{suffix}"] = value
    for variable, key in (
        ("PEXELS_API_KEYS", "pexels_api_keys"),
        ("PIXABAY_API_KEYS", "pixabay_api_keys"),
    ):
        keys = split_keys(env(variable))
        if keys:
            app[key] = keys

    if json.dumps(data, sort_keys=True, default=str) != before or created:
        save_config(data)
        log("config.toml created" if created else "config.toml updated from variables")

    # One line of status, never the secrets themselves.
    llm_ready = bool(str(app.get(f"{active_provider}_api_key") or "").strip())
    footage_ready = bool(app.get("pexels_api_keys") or app.get("pixabay_api_keys"))
    log(
        f"LLM provider: {active_provider or 'none'} "
        f"({'key set' if llm_ready else 'no key yet - add it in the web UI or LLM_API_KEY'}); "
        f"stock footage: {'key set' if footage_ready else 'no Pexels/Pixabay key yet'}"
    )


if __name__ == "__main__":
    main()

#!/bin/sh
# Prepares a MoneyPrinterTurbo source tree for redistribution in this image.
#
# Usage: prepare-source.sh <source-dir>
#
# MoneyPrinterTurbo's code is MIT-licensed, but the upstream repository also
# carries files the MIT license does not cover. This script removes them and
# points the defaults at a freely licensed font instead. Every step is checked,
# so the image build fails loudly if a new upstream release changes the layout.
#
#   1. resource/songs/*   Background music that upstream's README says was taken
#                         from YouTube videos. Removed; add your own music from
#                         the web UI.
#   2. resource/fonts/    Microsoft YaHei, STHeiti (SinoType) and UTM Kabel are
#                         not licensed for redistribution. Removed. Be Vietnam
#                         Pro and Charm are under the SIL Open Font License and
#                         stay.
#   3. Default font       The code names the removed fonts as defaults. They are
#                         replaced with Noto Sans CJK (SIL Open Font License),
#                         which the Dockerfile installs next to the others.
#   4. Docs, tests, CI    Not needed at runtime (and docs/ holds sponsor logos).
set -eu

SRC="${1:?usage: prepare-source.sh <source-dir>}"
DEFAULT_FONT="NotoSansCJK-Bold.ttc"
cd "$SRC"

fail() { echo "prepare-source: ERROR: $*" >&2; exit 1; }

[ -f webui/Main.py ] && [ -f main.py ] && [ -d resource/fonts ] \
  || fail "$SRC does not look like a MoneyPrinterTurbo checkout"

# 1. Background music.
rm -rf resource/songs
mkdir -p resource/songs
[ -z "$(ls -A resource/songs)" ] || fail "resource/songs is not empty"

# 2. Fonts: keep only the ones whose license we have checked.
for font in resource/fonts/*; do
  case "$(basename "$font")" in
    BeVietnamPro-Bold.ttf|BeVietnamPro-Medium.ttf|Charm-Bold.ttf|Charm-Regular.ttf) ;;
    *) rm -rf "$font" ;;
  esac
done
for font in BeVietnamPro-Bold.ttf BeVietnamPro-Medium.ttf Charm-Bold.ttf Charm-Regular.ttf; do
  [ -f "resource/fonts/$font" ] || fail "expected font resource/fonts/$font is missing upstream"
done
# The kept files must be the exact ones whose embedded license was read.
sha256sum -c - <<'EOF' || fail "a kept font differs from the reviewed file"
2fe6c3f9dbb65f61554d530c16b2eb4ec32ca437dc8f9999a6ec0f6403b30bfe  resource/fonts/BeVietnamPro-Bold.ttf
f493144cb53c78c6f0819bc9b73de274486618ac609bc92b3b79d4efc76f95c6  resource/fonts/BeVietnamPro-Medium.ttf
e7b614c116724be24140c25f71a218be04cd7f0c32c33423aa0571963a0027eb  resource/fonts/Charm-Bold.ttf
e3df8c7ae07f5d8cde91b4a033f4d281c0b9f3014f00c53644a11907b0ad08f6  resource/fonts/Charm-Regular.ttf
EOF

# 3. Default font names in the code and the config template.
code_files="webui/Main.py app/models/schema.py app/services/video.py app/controllers/v1/video.py cli.py config.example.toml"
for f in $code_files; do
  [ -f "$f" ] || fail "expected file $f is missing upstream"
done
# shellcheck disable=SC2086
sed -i \
  -e "s/MicrosoftYaHeiBold\.ttc/$DEFAULT_FONT/g" \
  -e "s/MicrosoftYaHeiNormal\.ttc/NotoSansCJK-Regular.ttc/g" \
  -e "s/STHeitiMedium\.ttc/$DEFAULT_FONT/g" \
  -e "s/STHeitiLight\.ttc/NotoSansCJK-Regular.ttc/g" \
  -e "s/STHeitiMedium 黑体-中/$DEFAULT_FONT/g" \
  $code_files
grep -q "\"font_name\": \"$DEFAULT_FONT\"" webui/Main.py \
  || fail "the web UI default font was not replaced"
grep -q "font_name: Optional\[str\] = \"$DEFAULT_FONT\"" app/models/schema.py \
  || fail "the API default font was not replaced"

# 4. Files the running app does not need.
rm -rf .git .github docs test sites Dockerfile* docker-compose*.yml *.bat \
       README*.md CHANGELOG*.md .dockerignore .gitignore .gitattributes

# Nothing that runs may still name a removed font.
if grep -rnE "MicrosoftYaHei|STHeiti|UTM Kabel" --include='*.py' --include='*.toml' \
     --exclude=pyproject.toml . ; then
  fail "the files above still reference a removed font"
fi

[ -f LICENSE ] || fail "upstream LICENSE is missing; it must ship with the code"
echo "prepare-source: ok ($(find resource/fonts -type f | wc -l) fonts kept, 0 songs)"

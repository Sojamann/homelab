#!/usr/bin/env bash
# mdBook preprocessor. Build guide pages include the stage docs verbatim, so
# their relative links resolve against the mirrored repo path under build/.
# Links to docs/src/ become book links to the topic page; links to
# non-markdown files (.tf, .yaml, dirs) go to GitHub, flux/ to the apps repo.
set -euo pipefail

[ "${1:-}" = supports ] && exit 0

jq '.[1] | walk(
  if type == "object" and (.Chapter.source_path? // "" | startswith("build/")) then
    (.Chapter.source_path | sub("/[^/]*$"; "")) as $dir
    | .Chapter.content |= gsub("\\]\\((?<l>[^)\\s]+)\\)"; "](" + (
        .l
        | if test("^[a-z]+:|^#|^/") then .
          else
            (split("#") | .[0]) as $path
            | (if test("#") then "#" + (split("#") | .[1]) else "" end) as $frag
            | ($dir + "/" + $path | split("/")
                | reduce .[] as $s ([];
                    if $s == "." or $s == "" then .
                    elif $s == ".." then .[:-1]
                    else . + [$s] end)) as $p
            | if $p[0] != "build" then .
              elif $p[1:3] == ["docs", "src"] then
                ("../" * ($dir | split("/") | length)) + ($p[3:] | join("/")) + $frag
              elif test("\\.md(#|$)") then .
              elif $p[1] == "flux" then
                "https://github.com/Sojamann/homelab-apps/blob/main/" + ($p[2:] | join("/")) + $frag
              else
                "https://github.com/Sojamann/homelab/blob/main/" + ($p[1:] | join("/")) + $frag
              end
          end
      ) + ")")
  else . end
)'

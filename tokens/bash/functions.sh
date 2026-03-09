#!/bin/bash
set -euo pipefail

to_epoch() {
    local date_str="$1"
    # Normalize: strip trailing Z, replace +00:00 style offsets with nothing (treat as UTC)
    local normalized="${date_str%Z}"
    normalized="${normalized%+00:00}"
    normalized="${normalized%-00:00}"

    if [[ "$(uname)" == "Darwin" ]]; then
        date -jf "%Y-%m-%dT%H:%M:%S" "$normalized" "+%s" 2>/dev/null
    else
        date -d "$date_str" "+%s" 2>/dev/null
    fi
}

floor_days() {
    local diff=$1
    if [ "$diff" -ge 0 ]; then
        echo $(( diff / 86400 ))
    else
        echo $(( (diff - 86399) / 86400 ))
    fi
}

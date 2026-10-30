#!/bin/sh
# Run FPV jobs one after another (results in fv/<job>/result.txt).
# AD_FV_LIMIT: seconds per solver run; a BMC that reaches it reports the
# deepest step proven clean ("BOUNDED").
cd "$(dirname "$0")/.."
: "${AD_FV_LIMIT:=600}"
export AD_FV_LIMIT
for m in "$@"; do python3 tools/ad_fv.py "$m" 2>&1 | grep -v "^##" | head -4; done

#!/bin/sh
# Fetch the first-party home view bundle so it can be eval-tested in a real browser.
set -e
mkdir -p /tmp/glviews
for v in home overview clients; do
    if [ -f /www/views/gl-sdk4-ui-$v.common.js.gz ]; then
        gunzip -c /www/views/gl-sdk4-ui-$v.common.js.gz > /tmp/glviews/$v.js
        echo "extracted $v.js $(wc -c < /tmp/glviews/$v.js) bytes"
    fi
done
ls -la /tmp/glviews/

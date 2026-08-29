#!/bin/sh

# sed -i "s/$(grep -oP 'version=\K[^ ]+' module.prop)/$(cat module.prop | grep 'version=' | awk -F '=' '{print $2}')($(git log --oneline -n 1 | awk '{print $1}'))/g" module.prop

# 模块名支持外部传入（如 GitHub Actions 中的仓库名），未传入时回退为原硬编码值
MODULE_NAME="${MODULE_NAME:-crond4Android}"

zip -r -o -X -ll "${MODULE_NAME}-$(cat module.prop | grep 'version=' | awk -F '=' '{print $2}').zip" ./ -x '.git/*' -x 'CHANGELOG.md' -x 'README.md' -x 'update.json' -x 'build.sh' -x '.github/*' -x 'LICENSE'

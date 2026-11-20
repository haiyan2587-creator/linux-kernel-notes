#!/usr/bin/env bash
#
# 检查仓库里所有 Markdown 的相对链接是否指向真实存在的文件。
#
# 用法：
#   ./tools/check-links.sh           # 检查本仓库
#   ./tools/check-links.sh <目录>    # 检查指定目录
#
# 为什么需要它：
#   笔记多了以后，改一次目录名就会让若干索引和互链静默失效——
#   Markdown 不会报错，点开才发现 404。这个脚本把这种错误变成立即可见。
#
# 退出码：0 全部有效；1 有失效链接

set -u

ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"

if [ ! -d "$ROOT" ]; then
	printf '目录不存在: %s\n' "$ROOT" >&2
	exit 2
fi

total=0
bad=0
broken_list=""

while IFS= read -r f; do
	dir=$(dirname "$f")
	rel="${f#"$ROOT"/}"

	while IFS= read -r link; do
		# 去掉外链、锚点、邮件
		case "$link" in
			http://*|https://*|mailto:*|\#*) continue ;;
		esac
		# 去掉锚点部分
		target="${link%%#*}"
		[ -z "$target" ] && continue

		total=$((total + 1))
		if [ ! -e "$dir/$target" ]; then
			printf 'NG  %s\n      -> %s\n' "$rel" "$link"
			broken_list="$broken_list$rel -> $link\n"
			bad=$((bad + 1))
		fi
	done < <(grep -oE '\]\([^)]+\)' "$f" 2>/dev/null | sed -e 's/^](//' -e 's/)$//')
done < <(find "$ROOT" -name '*.md' -not -path '*/.git/*' -type f | sort)

# 反向检查：登记在索引表里的文件名是否真实存在
echo
printf '共检查 %d 个相对链接，失效 %d 个\n' "$total" "$bad"

if [ "$bad" -gt 0 ]; then
	printf '\n修复建议：改链接，或确认文件是否被移动/删除。\n'
	exit 1
fi

printf '全部有效。\n'
exit 0

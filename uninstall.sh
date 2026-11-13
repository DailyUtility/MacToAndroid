#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Waldron
# 卸载 MacToAndroid
# 用法: ./uninstall.sh [--purge] [--yes] [--app-dir DIR]
#   --purge        同时删除配置目录与日志，并卸载手机端客户端
#   --yes          不询问，直接执行
#   --app-dir DIR  App 装在非 /Applications 时指定
set -uo pipefail

# 三个脚本共用同一份 PATH 重建，check.sh 会校验它们逐字节一致——
# 不一致的话守护进程和控制器可能在不同目录里找到不同版本的 adb，
# 而 adb server 只有一个，版本不符时后启动的一方会 kill-server 再重启。
#
# 为什么必须自己重建：LaunchAgent 拿到的 PATH 极干净（基本只有系统目录），
# 不重建连包管理器装的东西都找不到。代价是**调用方的 PATH 完全不参与**。
#
# 顺序：系统目录永远最前；额外目录里包管理器优先，用户可写目录靠后，Android SDK 最后兜底。
PATH="/usr/bin:/bin:/usr/sbin:/sbin"
# Android SDK 的 platform-tools 不属于任何包管理器。Android Studio 装的 SDK 默认落在
# ~/Library/Android/sdk，所以这个默认路径必须写死：ANDROID_HOME / ANDROID_SDK_ROOT
# 在 launchd 环境里通常是空的，指望环境变量等于指望不上。
# 踩过：机器上只有 Android Studio 那份 adb 时，界面一直报「缺少依赖: adb」，
# 而用户在自己终端里 which adb 明明找得到——因为查的不是同一个 PATH。
#
# 额外目录先在 _extra 里逐个「前置」（越靠后优先级越高），最后整体**接在系统目录后面**：
# 包管理器里的同名 grep / awk / stat（例如 GNU 版）不能盖掉脚本依赖的 BSD 版本。
_extra=""
[ -d "$HOME/Library/Android/sdk/platform-tools" ] && _extra="$HOME/Library/Android/sdk/platform-tools"
for _p in "${ANDROID_SDK_ROOT:-}" "${ANDROID_HOME:-}"; do
	[ -n "$_p" ] && [ -d "$_p/platform-tools" ] && _extra="$_p/platform-tools${_extra:+:$_extra}"
done
for _p in "$HOME/.local/bin" /opt/local/bin /usr/local/bin /opt/homebrew/bin; do
	[ -d "$_p" ] && _extra="$_p${_extra:+:$_extra}"
done
PATH="$PATH${_extra:+:$_extra}"
unset _extra
export PATH

LABEL="com.local.mactoandroid"
MENU_LABEL="com.local.mactoandroid.menubar"
BUNDLE_MENU="com.local.mactoandroid.menubar"
BUNDLE_MENU_LEGACY="com.local.mactoandroid.app"   # 旧版的标识，卸载旧版装的 App 时要认得
RUNTIME_DIR="$HOME/Library/Application Support/MacToAndroid"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
CONF_DIR="$HOME/.config/mactoandroid"
LOG_DIR="$HOME/Library/Logs/MacToAndroid"
# 与 mta-ctl 用同一份解析：TMPDIR 在 SSH / cron 里可能是空的，
# ${TMPDIR:-/tmp} 的兜底会让状态落到所有用户可写的 /tmp，还和守护进程分叉成两份。
# getconf DARWIN_USER_TEMP_DIR 给的就是 launchd 那个每用户目录。
_state_root="$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || true)"
case "$_state_root" in
	/*) _state_root="${_state_root%/}" ;;
	*)  case "${TMPDIR:-}" in
		/*) _state_root="${TMPDIR%/}" ;;
		*)  echo "拿不到每用户临时目录" >&2; exit 1 ;;
	esac ;;
esac
STATE_DIR="$_state_root/MacToAndroid"
PKG="com.genymobile.gnirehtet"

# relay 未必在默认端口上：31416 被占时 mta-ctl 会在 31416..31425 里自动换一个。
# 只看 31416 的话，relay 跑在 31417 上时「残留检查」会报告「干净」而其实没清掉。
# 整个范围一起扫，不依赖状态目录里的 port 文件（那个文件本来就要被删掉）。
PORT_BASE=31416
PORT_TRIES=10
PORTS=""
i=0
while [ "$i" -lt "$PORT_TRIES" ]; do
	PORTS="$PORTS $((PORT_BASE + i))"
	i=$((i + 1))
done

# 只认「本用户的 gnirehtet」：同一台机器上别的用户也可能在跑，那个既不该杀也杀不掉
our_gnirehtet() {
	local pid="$1" comm owner
	comm="$(ps -o comm= -p "$pid" 2>/dev/null || true)"
	owner="$(ps -o uid= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
	case "$comm" in *gnirehtet* ) [ "$owner" = "$(id -u)" ] && return 0 ;; esac
	return 1
}

gnirehtet_pids() {
	local port p
	for port in $PORTS; do
		for p in $(lsof -nP -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null); do
			our_gnirehtet "$p" && echo "$p	$port"
		done
	done
}

PURGE=0
ASSUME_YES=0
APP_DIR="/Applications"

while [ $# -gt 0 ]; do
	case "$1" in
		--purge) PURGE=1; shift ;;
		--yes|-y) ASSUME_YES=1; shift ;;
		--app-dir) APP_DIR="${2:-}"; shift 2 ;;
		*) echo "未知参数: $1" >&2; exit 1 ;;
	esac
done

# 构建时记下的绝对路径最准，优先用它
APP=""
if [ -r "$RUNTIME_DIR/app-path" ]; then
	APP="$(cat "$RUNTIME_DIR/app-path" 2>/dev/null || true)"
fi
[ -n "$APP" ] && [ -d "$APP" ] || APP="$APP_DIR/MacToAndroid.app"

case "$APP" in
	"" | "/" | "/Applications" ) echo "App 路径不合法: '$APP'" >&2; exit 1 ;;
esac
# app-path 是个普通文本文件，内容陈旧或被改坏时不能照着 rm -rf。
# 只删确实是本 App 的 bundle：.app 结尾且 bundle id 对得上，否则跳过删除
APP_OK=0
case "$APP" in
	*.app)
		case "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist" 2>/dev/null)" in
			"$BUNDLE_MENU" | "$BUNDLE_MENU_LEGACY") APP_OK=1 ;;
		esac ;;
esac

echo "将执行："
echo "  • 停止所有共享与守护进程"
echo "  • 删除 $PLIST"
echo "  • 删除 $RUNTIME_DIR"
if [ "$APP_OK" -eq 1 ]; then echo "  • 删除 $APP"; else echo "  • 不删除 App（$APP 不是 MacToAndroid，请手动处理）"; fi
echo "  • 删除 $STATE_DIR"
if [ "$PURGE" -eq 1 ]; then
	echo "  • 删除 ${CONF_DIR}（设备允许/拒绝列表）"
	echo "  • 删除 $LOG_DIR"
	echo "  • 卸载手机端 $PKG"
fi
echo "  （不会动源码目录，也不会卸载 gnirehtet / adb）"
echo

if [ "$ASSUME_YES" -eq 0 ]; then
	printf "继续？[y/N] "
	read -r ans
	case "$ans" in y|Y|yes|YES) ;; *) echo "已取消"; exit 0 ;; esac
fi

# 顺序很重要：先把会「重新拉起共享」的一方全部停掉，再停共享。
# 以前先 stop-all、隔几行才停守护进程，中间来一次心跳或设备事件，
# 守护进程就会把 relay 和手机端重新拉起，随后 relay 被强杀，
# 手机挂着一个指向空端口的 VPN——彻底没网。

# 先让前端退出，再卸 agent，避免残留进程占着 bundle id
for _bid in "$BUNDLE_MENU" "$BUNDLE_MENU_LEGACY"; do
	osascript -e "tell application id \"$_bid\" to quit" >/dev/null 2>&1 || true
done
pkill -f "/MacToAndroid.app/Contents/MacOS/" 2>/dev/null || true

launchctl bootout "gui/$UID/$MENU_LABEL" 2>/dev/null || true
launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$MENU_LABEL.plist"
pkill -f "$RUNTIME_DIR/watcher.sh" 2>/dev/null || true

# App 派生出来的 ctl（比如正在跑的 install-client，最长 180 秒）不会随它一起死。
# 那个孤儿之后任何一步都会 mkdir -p 状态目录，于是刚删掉的目录又回来了。
pkill -f "$RUNTIME_DIR/mta-ctl.sh" 2>/dev/null || true
# 改状态的 ctl 装了 TERM trap，正卡在 adb 里时要等 adb 结束才退，还会继续持锁——
# 下面的 stop-all 等不到锁就会白白失败。给 3 秒，还不走就强杀
for _i in 1 2 3 4 5 6; do
	pgrep -f "$RUNTIME_DIR/mta-ctl.sh" >/dev/null 2>&1 || break
	sleep 0.5
done
pkill -9 -f "$RUNTIME_DIR/mta-ctl.sh" 2>/dev/null || true

# 现在没人会再拉起共享了：让控制器把所有 client 与 relay 停干净，趁 adb 还通。
# 被 pkill 的 ctl 可能把锁留在原地，stop-all 会按「持有者已死」回收
if [ -x "$RUNTIME_DIR/mta-ctl.sh" ]; then
	"$RUNTIME_DIR/mta-ctl.sh" stop-all >/dev/null 2>&1 \
		|| echo "  ! 没能正常停止共享；手机上的 VPN 如果还亮着，请在手机上手动断开"
fi

# 只杀确认是 gnirehtet 的进程，端口可能被别的程序占着
gnirehtet_pids | while IFS='	' read -r p port; do
	[ -n "$p" ] || continue
	kill -9 "$p" 2>/dev/null || true
done

rm -f "$PLIST"
rm -rf "$RUNTIME_DIR" "$STATE_DIR"
[ "$APP_OK" -eq 1 ] && rm -rf "$APP"

if [ "$PURGE" -eq 1 ]; then
	rm -rf "$CONF_DIR" "$LOG_DIR"
	if command -v adb >/dev/null 2>&1; then
		# 必须逐台带 -s：插着两台时光跑 `adb uninstall` 会报 more than one device
		devs="$(adb devices 2>/dev/null | tail -n +2 | awk '$2=="device"{print $1}')"
		if [ -z "$devs" ]; then
			echo "手机端客户端未卸载（没有在线设备）"
		else
			for d in $devs; do
				adb -s "$d" uninstall "$PKG" >/dev/null 2>&1 \
					&& echo "手机端客户端已从 $d 卸载" \
					|| echo "$d 上的手机端客户端未卸载（可能本来就没装）"
			done
		fi
	fi
fi

echo
echo "已卸载。残留检查："
leftover=0
while IFS='	' read -r p port; do
	[ -n "$p" ] || continue
	echo "  ! 仍有 gnirehtet 占用端口 $port (pid $p)"
	leftover=1
done <<EOF
$(gnirehtet_pids)
EOF
[ "$leftover" -eq 0 ] && echo "  端口 ${PORT_BASE}..$((PORT_BASE + PORT_TRIES - 1)) 无 gnirehtet 残留"
pgrep -f 'MacToAndroid/watcher.sh' >/dev/null 2>&1 && echo "  ! 守护进程仍在运行" || echo "  守护进程已停止"
launchctl print "gui/$UID/$LABEL" >/dev/null 2>&1 && echo "  ! LaunchAgent 仍已加载" || echo "  LaunchAgent 已卸载"
[ -d "$APP" ] && echo "  ! App 仍存在: $APP" || echo "  App 已删除"
launchctl print "gui/$UID/$MENU_LABEL" >/dev/null 2>&1 && echo "  ! 登录项仍已加载" || echo "  登录项已卸载"
if [ -d "$STATE_DIR" ]; then
	echo "  ! 状态目录被重建: ${STATE_DIR}（有 ctl 进程在收尾，重启会清空）"
else
	echo "  状态目录已删除"
fi

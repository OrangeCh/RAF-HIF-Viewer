#!/bin/bash
# 把 build/ 里的 .app 打成拖拽式安装用的 DMG
#
# 两个已知的坑（都踩过）：
#   1. 少了 mkdir -p "$STAGE"，cp 会把暂存目录直接变成 App 的副本，
#      打出来的 DMG 里根本没有 App（症状会伪装成 Finder 报 -10006）。
#   2. Finder 的窗口有竞态：open 之后不等它进入图标视图就设属性，
#      设背景图和图标位置都会失败。所以 delay + 校验 + 重试。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APPNAME="RAF-HIF 对照查看器"
VERSION="1.0"
VOLNAME="$APPNAME $VERSION"
APP="$ROOT/build/$APPNAME.app"
OUT="$ROOT/build/$APPNAME $VERSION.dmg"
STAGE="$ROOT/build/dmg-stage"
RW="$ROOT/build/dmg-rw.dmg"
MOUNT="/Volumes/$VOLNAME"

[ -d "$APP" ] || { echo "找不到 $APP —— 先跑 ./build.sh"; exit 1; }

# ── 暂存目录 ────────────────────────────────────────────────
echo "==> 准备暂存目录"
rm -rf "$STAGE" "$RW" "$OUT"
mkdir -p "$STAGE/.background"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp "$ROOT/Resources/dmg/background.png"    "$STAGE/.background/"
cp "$ROOT/Resources/dmg/background@2x.png" "$STAGE/.background/"
# MIT 许可要求分发二进制时附带版权声明，所以放进安装包里
cp "$ROOT/LICENSE" "$STAGE/LICENSE.txt"

if [ ! -d "$STAGE/$APPNAME.app" ]; then
  echo "❌ App 未正确拷入暂存目录：$STAGE"
  exit 1
fi

cat > "$STAGE/首次打开请先读我.txt" <<'TXT'
RAF-HIF 对照查看器
==================

安装
----
把左边的 App 拖进右边的 Applications 文件夹。

首次打开被系统拦住了？
----------------------
这个 App 没有 Apple 开发者签名（纯本地构建），所以 macOS 会提示
「Apple 无法验证……是否包含恶意软件」。这是正常的，不是它真的有问题。

三种解决办法，任选其一：

1) 命令行（最省事）
   打开「终端」，粘贴执行：

   xattr -dr com.apple.quarantine "/Applications/RAF-HIF 对照查看器.app"

   然后就能正常双击打开了。

2) 系统设置
   先双击一次让它报错，然后打开
   系统设置 → 隐私与安全性 → 拉到底部 → 点「仍要打开」。

3) 自己构建（最干净）
   如果这台 Mac 上有源码，直接在源码目录执行 ./build.sh，
   本地构建出来的 App 不带隔离属性，系统不会拦。

系统要求
--------
· Apple Silicon（M 系列）Mac
· macOS 14.0 或更高

说明
----
· 纯本地工具，不联网、不上传任何东西。
· 删除功能是把文件移进废纸篓，可随时撤销。
· 支持 RAF / HIF 对照、Ctrl+滚轮缩放、滚轮翻页、右键删除与分享。
TXT

# ── 设置 DMG 窗口的外观 ─────────────────────────────────────
# 背景图放在最后设；窗口的工具栏/尺寸等单独一趟，避开 Finder 的重排
apply_layout() {
  osascript <<APPLESCRIPT >/dev/null 2>&1 || true
tell application "Finder"
    tell disk "$VOLNAME"
        open
        delay 2
        set current view of container window to icon view
        set opts to the icon view options of container window
        set arrangement of opts to not arranged
        set icon size of opts to 104
        set position of item "$APPNAME.app" of container window to {170, 200}
        set position of item "Applications" of container window to {490, 200}
        set position of item "首次打开请先读我.txt" of container window to {245, 352}
        set position of item "LICENSE.txt" of container window to {425, 352}
        update without registering applications
        delay 1
    end tell
end tell
APPLESCRIPT

  osascript <<APPLESCRIPT >/dev/null 2>&1 || true
tell application "Finder"
    tell disk "$VOLNAME"
        set opts to the icon view options of container window
        set background picture of opts to file ".background:background.png"
        update without registering applications
        delay 1
    end tell
end tell
APPLESCRIPT

  osascript <<APPLESCRIPT >/dev/null 2>&1 || true
tell application "Finder"
    tell disk "$VOLNAME"
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 165, 860, 685}
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT
}

cleanup_mounts() {
  while IFS= read -r m; do
    [ -n "$m" ] && hdiutil detach "$m" -force >/dev/null 2>&1 || true
  done < <(ls -d /Volumes/"$VOLNAME"* 2>/dev/null || true)
}

# ── 制作，带重试 ────────────────────────────────────────────
#
# 关键坑：hdiutil detach 时 Finder 会把内存状态回写 .DS_Store，
# 背景图设置会被抹掉（DS_Store 从 10244 字节缩回 6148 字节，图标坐标留下、
# 背景图没了）。所以：
#   ① 可浏览挂载 → 设布局 → 立刻把好的 .DS_Store 存出来
#   ② 卸载（此时会被 Finder 回写覆盖，无所谓）
#   ③ 用 -nobrowse 再挂载（Finder 不接管）→ 把好的 .DS_Store 写回去 → 卸载
#   ④ 转档，背景图就能保住
SAVED="$ROOT/build/dmg-dsstore"
BUILT=0
for attempt in 1 2 3; do
  echo "==> 第 $attempt 次尝试"
  cleanup_mounts
  sleep 1
  rm -f "$RW" "$OUT" "$SAVED"

  hdiutil create -srcfolder "$STAGE" -volname "$VOLNAME" \
    -fs HFS+ -format UDRW -ov "$RW" >/dev/null 2>&1

  # ① 设布局
  hdiutil attach "$RW" -readwrite -noverify -noautoopen >/dev/null 2>&1
  sleep 3
  if [ ! -d "$MOUNT" ]; then
    echo "    ⚠️ 卷没挂到预期位置，重来"
    continue
  fi
  apply_layout
  sleep 2

  if ! strings "$MOUNT/.DS_Store" 2>/dev/null | grep -q backgroundImageAlias; then
    echo "    ⚠️ 背景图没设上，重来"
    hdiutil detach "$MOUNT" -force >/dev/null 2>&1
    continue
  fi
  if ! strings "$MOUNT/.DS_Store" 2>/dev/null | grep -q 'Iloc'; then
    echo "    ⚠️ 图标位置没设上，重来"
    hdiutil detach "$MOUNT" -force >/dev/null 2>&1
    continue
  fi
  echo "    ✅ 布局已设好（背景图 + 图标位置）"

  # ② 抢在 Finder 回写之前把好的 .DS_Store 存出来
  #
  # 然后**必须清理**：Finder 会把卷的别名信息写进 .DS_Store，里面带着
  # 构建机上的绝对路径（用户名、目录结构）。实测发布出去的 DMG 里就有
  #   /Volumes/<盘>/<用户名>/Documents/.../build/dmg-rw.dmg
  # 清理用等长替换，不动其它字节，所以二进制结构不受影响；
  # 背景图那条别名用的是卷内相对路径，不会被误伤。
  cp "$MOUNT/.DS_Store" "$SAVED"
  PY="$ROOT/../dsh-runtimes/dsh-primary-runtime/dependencies/python/bin/python3"
  if [ -x "$PY" ]; then
    "$PY" "$ROOT/Tools/sanitize-dsstore.py" "$SAVED" "dmg-rw" | sed 's/^/    /'
  else
    python3 "$ROOT/Tools/sanitize-dsstore.py" "$SAVED" "dmg-rw" | sed 's/^/    /' || true
  fi
  hdiutil detach "$MOUNT" >/dev/null 2>&1 || hdiutil detach "$MOUNT" -force >/dev/null 2>&1
  sleep 2

  # ③ -nobrowse 挂载写回
  hdiutil attach "$RW" -readwrite -nobrowse -noverify >/dev/null 2>&1
  sleep 3
  NB=$(ls -d /Volumes/"$VOLNAME"* 2>/dev/null | head -1 || true)
  if [ -z "$NB" ]; then
    echo "    ⚠️ -nobrowse 挂载失败，重来"
    continue
  fi
  cp "$SAVED" "$NB/.DS_Store"
  sync
  sleep 1
  hdiutil detach "$NB" >/dev/null 2>&1 || hdiutil detach "$NB" -force >/dev/null 2>&1
  sleep 2

  # ④ 转档
  rm -f "$OUT"
  if ! hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$OUT" >/dev/null 2>&1; then
    echo "    ⚠️ 转档失败，重来"
    continue
  fi

  # 校验成品
  hdiutil attach "$OUT" -noverify >/dev/null 2>&1
  sleep 3
  ok=1
  [ -d "$MOUNT/$APPNAME.app" ] || { echo "    ⚠️ 成品里没有 App"; ok=0; }
  [ -f "$MOUNT/LICENSE.txt" ] || { echo "    ⚠️ 成品里没有许可证"; ok=0; }
  strings "$MOUNT/.DS_Store" 2>/dev/null | grep -q backgroundImageAlias \
    || { echo "    ⚠️ 成品里背景图丢了"; ok=0; }
  strings "$MOUNT/.DS_Store" 2>/dev/null | grep -q 'Iloc' \
    || { echo "    ⚠️ 成品里图标位置丢了"; ok=0; }
  # 隐私复查：成品里不能残留构建机路径
  if strings "$MOUNT/.DS_Store" 2>/dev/null | grep -qE "$(whoami)|$(echo "$ROOT" | sed 's|/|\\/|g')"; then
    echo "    ❌ 成品 .DS_Store 里仍残留构建机路径"; ok=0
  else
    echo "    ✅ .DS_Store 已清理，无构建机路径"
  fi
  hdiutil detach "$MOUNT" -force >/dev/null 2>&1

  if [ "$ok" = 1 ]; then
    echo "    ✅ 成品校验通过：App、背景图、图标位置都在"
    BUILT=1
    break
  fi
done

rm -f "$RW" "$SAVED"
rm -rf "$STAGE"

if [ "$BUILT" != 1 ]; then
  echo "⚠️ 多次尝试都没保住背景图，改为生成不带背景的 DMG（功能完全一样）"
  cleanup_mounts
  sleep 1
  rm -f "$RW" "$OUT"
  hdiutil create -srcfolder "$STAGE" -volname "$VOLNAME" \
    -fs HFS+ -format UDZO -ov "$OUT" >/dev/null 2>&1 || true
  [ -f "$OUT" ] || { echo "❌ 连不含背景的 DMG 都没做出来"; exit 1; }
fi

echo "==> 签名（ad-hoc）"
codesign --force --sign - "$OUT" 2>&1 | sed 's/^/    /' || true

echo
echo "==> 完成"
echo "    $OUT"
echo "    大小 $(du -h "$OUT" | cut -f1)"

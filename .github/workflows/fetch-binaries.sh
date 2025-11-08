#!/bin/bash
set -e

echo "🟦 开始执行二进制更新任务 $(date '+%F %T')"

CONFIG_FILE=".github/workflows/binaries.conf"
BASE_DIR="/tmp/update_binaries"

count=$(yq '.binaries | length' "$CONFIG_FILE")
echo "📦 读取到 $count 个二进制任务"

for ((i=0; i<count; i++)); do
  name=$(yq -r ".binaries[$i].name" "$CONFIG_FILE")
  repo=$(yq -r ".binaries[$i].repo" "$CONFIG_FILE")
  keyword=$(yq -r ".binaries[$i].keyword" "$CONFIG_FILE")
  exec=$(yq -r ".binaries[$i].exec" "$CONFIG_FILE")
  type=$(yq -r ".binaries[$i].type" "$CONFIG_FILE")
  extract=$(yq -r ".binaries[$i].extract" "$CONFIG_FILE")
  keep_pkg=$(yq -r ".binaries[$i].keep_pkg" "$CONFIG_FILE")
  target_base=$(yq -r ".binaries[$i].target_base // \"bin\"" "$CONFIG_FILE")

  mkdir -p "$BASE_DIR/${name}_tmp" "$target_base"

  echo "🟩 更新 $name..."
  release_json=$(curl -s "https://api.github.com/repos/${repo}/releases/latest")

  IFS='|' read -ra keywords <<< "$keyword"
  IFS='|' read -ra types <<< "$type"
  IFS='|' read -ra extract_types <<< "$extract"
  IFS='|' read -ra keep_types <<< "$keep_pkg"

  for kw in "${keywords[@]}"; do
    for ft in "${types[@]}"; do
      url=$(echo "$release_json" | jq -r ".assets[] | select(.name | contains(\"${kw}\") and endswith(\"${ft}\")) | .browser_download_url" | head -n1)
      [[ -z "$url" ]] && continue

      pkgfile="$BASE_DIR/${name}_tmp/$(basename "$url")"
      echo "    ⬇️ 下载: $url"
      curl -L -o "$pkgfile" "$url"

      target_dir="$target_base/$name/$kw"
      mkdir -p "$target_dir"

      if [[ " ${extract_types[*]} " == *"$ft"* ]]; then
        echo "    📂 解压 $ft"
        if [[ "$ft" == "zip" ]]; then unzip -qo "$pkgfile" -d "$target_dir"; fi
        if [[ "$ft" == "tar.gz" ]]; then tar -xzf "$pkgfile" -C "$target_dir"; fi

        # 平铺文件
        shopt -s dotglob
        for item in "$target_dir"/*; do
          if [[ -d "$item" ]]; then
            for sub in "$item"/*; do
              # 如果已存在文件，覆盖
              mv -f "$sub" "$target_dir"/
            done
            rmdir "$item" || true
          fi
        done
        shopt -u dotglob

        # 保留压缩包
        keep_this=false
        for k in "${keep_types[@]}"; do [[ "$k" == "$ft" ]] && keep_this=true && break; done
        if [[ "$keep_this" == true ]]; then
          mkdir -p "$target_base/$name"
          cp -f "$pkgfile" "$target_base/$name/$kw.$ft"
        fi

        # 删除临时 pkgfile
        rm -f "$pkgfile"

      else
        # 不解压文件 (deb/ipk)
        target_file="$target_base/$name/$kw.$ft"
        mkdir -p "$(dirname "$target_file")"
        mv -f "$pkgfile" "$target_file"
      fi

      # 设置可执行权限
      binpath=$(find "$target_base/$name/$kw" -type f -name "$exec*" 2>/dev/null | head -n1)
      [[ -n "$binpath" ]] && chmod +x "$binpath"
    done
  done
  echo "✅ $name 更新完成"
done

echo "🎉 全部更新完成 $(date '+%F %T')"

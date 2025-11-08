#!/bin/bash
set -e
echo "🟦 开始执行二进制更新任务 $(date '+%F %T')"

# CONFIG_FILE 路径需要调整，使其相对于工作流的根目录
CONFIG_FILE=".github/workflows/binaries.conf"
BASE_DIR="/tmp/update_binaries"

# 确保脚本不会在没有配置文件的环境下失败
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "❌ 错误：配置文件 $CONFIG_FILE 不存在！"
    exit 1
fi

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
  # 兼容旧配置（如 target_base 为空），使用默认值 "bin"
  target_base=$(yq -r ".binaries[$i].target_base // \"bin\"" "$CONFIG_FILE")

  mkdir -p "$BASE_DIR/${name}_tmp" "$target_base"

  echo "🟩 更新 $name..."
  # 从环境变量读取 GitHub Token，如果存在，用于提高 API 限制
  if [[ -n "$GITHUB_TOKEN" ]]; then
      auth_header="-H \"Authorization: Bearer $GITHUB_TOKEN\""
  else
      auth_header=""
  fi
  
  # 使用 eval 来正确执行带有引用的 curl 命令
  release_json=$(eval "curl -s $auth_header https://api.github.com/repos/${repo}/releases/latest")

  # 检查 API 调用是否成功
  if [[ "$(echo "$release_json" | jq -r '.message')" == "Not Found" ]]; then
      echo "    ⚠️ 仓库 $repo 未找到或 API 调用失败，跳过。"
      continue
  fi

  IFS='|' read -ra keywords <<< "$keyword"
  IFS='|' read -ra types <<< "$type"
  IFS='|' read -ra extract_types <<< "$extract"
  IFS='|' read -ra keep_types <<< "$keep_pkg"

  for kw in "${keywords[@]}"; do
    for ft in "${types[@]}"; do
      # 匹配 asset name 中包含 keyword 且以 file_type 结尾的 URL
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

        # 平铺文件 (Move contents of sub-directories to the target_dir)
        shopt -s dotglob
        for item in "$target_dir"/*; do
          if [[ -d "$item" ]]; then
            # 移动子目录内容到父目录
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
      # 查找目标目录下名字以 $exec 开头的文件并设置可执行权限
      # find "$target_base/$name/$kw" -type f -name "$exec*" 2>/dev/null | head -n1 会在提取目录中找
      # 更好的方式是查找所有目标文件，因为非压缩包直接放在了上级目录
      
      # 检查是否是压缩包解压（在 target_dir 中查找）
      if [[ " ${extract_types[*]} " == *"$ft"* ]]; then
        binpath=$(find "$target_dir" -type f -name "$exec*" 2>/dev/null | head -n1)
      else
        # 非压缩包（deb/ipk）直接是 target_file
        if [[ "$(basename "$target_file")" == "$exec"* ]]; then
            binpath="$target_file"
        fi
      fi

      if [[ -n "$binpath" ]]; then
          echo "    ⚙️ 设置可执行权限: $(basename "$binpath")"
          chmod +x "$binpath"
      fi
      
    done
  done
  echo "✅ $name 更新完成"
done

echo "🎉 全部更新完成 $(date '+%F %T')"

# 清理临时目录
rm -rf "$BASE_DIR"

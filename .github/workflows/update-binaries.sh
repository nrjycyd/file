#!/bin/bash
# ====================================================================
# 二进制自动更新脚本
# ====================================================================

set -euo pipefail

# 配置
readonly CONFIG_FILE=".github/workflows/binaries.conf"
readonly BASE_DIR="/tmp/update_binaries"
readonly GITHUB_API="https://api.github.com"

# 颜色输出
log_info() { echo "🟦 $*"; }
log_success() { echo "✅ $*"; }
log_warn() { echo "⚠️  $*"; }
log_error() { echo "❌ $*" >&2; }

# 下载文件（带重试）
download_file() {
  local url="$1"
  local output="$2"
  local max_retries=3
  local retry=0

  while [[ $retry -lt $max_retries ]]; do
    if curl -fsSL --connect-timeout 30 --max-time 300 -o "$output" "$url"; then
      return 0
    fi
    retry=$((retry + 1))
    [[ $retry -lt $max_retries ]] && log_warn "下载失败，重试 $retry/$max_retries..."
  done
  
  log_error "下载失败: $url"
  return 1
}

# 解压文件
extract_archive() {
  local file="$1"
  local dest="$2"
  local type="$3"

  case "$type" in
    zip)
      unzip -qo "$file" -d "$dest" 2>/dev/null || {
        log_error "解压 ZIP 失败: $file"
        return 1
      }
      ;;
    tar.gz)
      tar -xzf "$file" -C "$dest" 2>/dev/null || {
        log_error "解压 TAR.GZ 失败: $file"
        return 1
      }
      ;;
    *)
      log_warn "未知压缩格式: $type"
      return 1
      ;;
  esac
}

# 平铺目录结构
flatten_directory() {
  local target_dir="$1"
  
  shopt -s dotglob nullglob
  for item in "$target_dir"/*; do
    if [[ -d "$item" ]]; then
      for sub in "$item"/*; do
        mv -f "$sub" "$target_dir"/ 2>/dev/null || true
      done
      rmdir "$item" 2>/dev/null || true
    fi
  done
  shopt -u dotglob nullglob
}

# 处理单个二进制任务
process_binary() {
  local index="$1"
  
  # 读取配置
  local name repo keyword exec type extract keep_pkg target_base
  name=$(yq -r ".binaries[$index].name" "$CONFIG_FILE")
  repo=$(yq -r ".binaries[$index].repo" "$CONFIG_FILE")
  keyword=$(yq -r ".binaries[$index].keyword" "$CONFIG_FILE")
  exec=$(yq -r ".binaries[$index].exec" "$CONFIG_FILE")
  type=$(yq -r ".binaries[$index].type" "$CONFIG_FILE")
  extract=$(yq -r ".binaries[$index].extract" "$CONFIG_FILE")
  keep_pkg=$(yq -r ".binaries[$index].keep_pkg" "$CONFIG_FILE")
  target_base=$(yq -r ".binaries[$index].target_base // \"bin\"" "$CONFIG_FILE")

  log_info "处理: $name (来自 $repo)"

  # 创建临时目录
  local tmp_dir="$BASE_DIR/${name}_tmp"
  mkdir -p "$tmp_dir" "$target_base"

  # 获取最新 release
  local release_json
  release_json=$(curl -fsSL "${GITHUB_API}/repos/${repo}/releases/latest" 2>/dev/null) || {
    log_error "无法获取 $repo 的 release 信息"
    return 1
  }

  # 解析配置数组
  IFS='|' read -ra keywords <<< "$keyword"
  IFS='|' read -ra types <<< "$type"
  IFS='|' read -ra extract_types <<< "$extract"
  IFS='|' read -ra keep_types <<< "$keep_pkg"

  # 遍历关键字和文件类型
  local download_count=0
  for kw in "${keywords[@]}"; do
    for ft in "${types[@]}"; do
      # 查找匹配的资源
      local url
      url=$(echo "$release_json" | jq -r \
        ".assets[] | select(.name | contains(\"${kw}\") and endswith(\"${ft}\")) | .browser_download_url" \
        | head -n1)
      
      [[ -z "$url" ]] && continue

      local pkgfile="$tmp_dir/$(basename "$url")"
      echo "    ⬇️  下载: $(basename "$url")"
      
      download_file "$url" "$pkgfile" || continue
      download_count=$((download_count + 1))

      local target_dir="$target_base/$name/$kw"
      mkdir -p "$target_dir"

      # 判断是否需要解压
      local should_extract=false
      for et in "${extract_types[@]}"; do
        [[ "$et" == "$ft" ]] && should_extract=true && break
      done

      if [[ "$should_extract" == "true" ]]; then
        echo "    📂 解压: $ft"
        extract_archive "$pkgfile" "$target_dir" "$ft" || continue
        flatten_directory "$target_dir"

        # 判断是否保留压缩包
        local should_keep=false
        for kt in "${keep_types[@]}"; do
          [[ "$kt" == "$ft" ]] && should_keep=true && break
        done

        if [[ "$should_keep" == "true" ]]; then
          mkdir -p "$target_base/$name"
          cp -f "$pkgfile" "$target_base/$name/$kw.$ft"
        fi

        rm -f "$pkgfile"
      else
        # 不解压，直接移动文件
        local target_file="$target_base/$name/$kw.$ft"
        mkdir -p "$(dirname "$target_file")"
        mv -f "$pkgfile" "$target_file"
      fi

      # 设置可执行权限
      local binpath
      binpath=$(find "$target_base/$name/$kw" -type f -name "$exec*" 2>/dev/null | head -n1)
      if [[ -n "$binpath" ]]; then
        chmod +x "$binpath"
        echo "    🔑 设置权限: $(basename "$binpath")"
      fi
    done
  done

  if [[ $download_count -eq 0 ]]; then
    log_warn "$name 没有找到匹配的资源"
    return 1
  fi

  log_success "$name 更新完成 (下载 $download_count 个文件)"
  return 0
}

# 主函数
main() {
  log_info "开始执行二进制更新任务 $(date '+%F %T')"

  if [[ ! -f "$CONFIG_FILE" ]]; then
    log_error "配置文件不存在: $CONFIG_FILE"
    exit 1
  fi

  local count
  count=$(yq '.binaries | length' "$CONFIG_FILE")
  log_info "读取到 $count 个二进制任务"

  local success=0
  local failed=0

  for ((i=0; i<count; i++)); do
    if process_binary "$i"; then
      success=$((success + 1))
    else
      failed=$((failed + 1))
    fi
    echo ""
  done

  # 清理临时目录
  rm -rf "$BASE_DIR"

  log_info "=========================================="
  log_success "成功: $success 个"
  [[ $failed -gt 0 ]] && log_warn "失败: $failed 个"
  log_info "任务完成 $(date '+%F %T')"
  log_info "=========================================="

  # 如果全部失败则返回错误
  [[ $success -eq 0 ]] && exit 1
  exit 0
}

# 执行主函数
main

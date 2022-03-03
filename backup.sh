#!/usr/bin/env bash

set -Eeuo pipefail

usage() {
  bold=$(tput bold)
  normal=$(tput sgr0)

  cat <<EOF
${bold}Usage:${normal}

$(basename "${BASH_SOURCE[0]}") [-h] [-v] -b BUCKET_NAME -n BACKUP_NAME -p BACKUP_PATH

Backup all files and directories from a specified location to an AWS S3 bucket.

Directories will be archived as a separate .tar.gz files.
The depth on which directories will be archived is controled by the --split-depth parameter.

${bold}Available options:${normal}

-h, --help               Print this help and exit
-v, --verbose            Print script debug info
-b, --bucket string      S3 bucket name
-n, --name string        Backup name, acts as a S3 path prefix
-p, --path string        Path to the file or directory to backup
--storage-class string   S3 storage class (default "GLACIER")
--dry-run                Don't upload files

If the BACKUP_PATH is a directory:

--max-size int           Maximum expected size of a single archive in GiB, used to calculate number of transfer chunks (default 1024 - 1 TiB)
--split-depth int        Directory level to create separate archive files (default 0)

${bold}Split depth:${normal}

- 0 - backup the whole directory from BACKUP_PATH as a single archive
- 1 - backup every directory in BACKUP_PATH as a separate archive
- 2 - backup every subdirectory of directory in BACKUP_PATH as a separate archive
etc.
EOF
  exit
}

main() {
  root_path=$(
    cd "$(dirname "$root_path")"
    pwd -P
  )/$(basename "$root_path") # convert to absolute path

  # division by 10k gives integer (without fraction), round result up by adding 1
  chunk_size_mb=$((max_size_gb * 1024 / 10000 + 1))

  # common rclone parameters
  rclone_args=(
    "-P"
    "--s3-storage-class" "$storage_class"
    "--s3-upload-concurrency" 8
    "--s3-no-check-bucket"
  )

  if [[ -f "$root_path" ]]; then
    backup_file "$root_path" "$(basename "$root_path")"
  elif [[ "$split_depth" -eq 0 ]]; then
    backup_path "$root_path" "$(basename "$root_path")"
  else
    traverse_path .
  fi
}

parse_params() {
  split_depth=0
  max_size_gb=1024
  storage_class="GLACIER"
  dry_run=false

  while :; do
    case "${1-}" in
    -h | --help) usage ;;
    -v | --verbose) set -x ;;
    -b | --bucket)
      bucket="${2-}"
      shift
      ;;
    -n | --name)
      backup_name="${2-}"
      shift
      ;;
    -p | --path)
      root_path="${2-}"
      shift
      ;;
    --max-size)
      max_size_gb="${2-}"
      shift
      ;;
    --split-depth)
      split_depth="${2-}"
      shift
      ;;
    --storage-class)
      storage_class="${2-}"
      shift
      ;;
    --dry-run) dry_run=true ;;
    -?*) die "Unknown option: $1" ;;
    *) break ;;
    esac
    shift
  done

  [[ -z "${bucket-}" ]] && die "Missing required parameter: bucket"
  [[ -z "${backup_name-}" ]] && die "Missing required parameter: name"
  [[ -z "${root_path-}" ]] && die "Missing required parameter: path"

  return 0
}

msg() {
  echo >&2 -e "$(date +"%Y-%m-%d %H:%M:%S") ${1-}"
}

die() {
  local msg=$1
  local code=${2-1} # default exit status 1
  msg "$msg"
  exit "$code"
}

# Arguments:
# - path - absolute path to backup
# - name - backup file name
backup_file() {
  local path=$1
  local name=$2

  msg "⬆️ Uploading file $name"

  args=("${rclone_args[@]}" "--checksum")
  [[ "$dry_run" = true ]] && args+=("--dry-run")

  rclone copy "${args[@]}" "$path" "backup:$bucket/$backup_name"
}

# Arguments:
# - path - absolute path to backup
# - name - backup name, without an extension, optionally being an S3 path
# - files_only - whether to backup only dir-level files, or directory as a whole
backup_path() {
  (
    local path=$1
    local name=$2
    local files_only=${3-false}

    local archive_name files hash s3_hash

    path=$(echo "$path" | sed -E 's#(/(\./)+)|(/\.$)#/#g' | sed 's|/$||')     # remove /./ and trailing /
    archive_name=$(echo "$backup_name/$name.tar.gz" | sed -E 's|/(\./)+|/|g') # remove /./

    cd "$path" || die "Can't access $path"

    if [[ "$files_only" == true ]]; then
      msg "🔍 Listing files in \"$path\"..."
      files=$(find . -type f -maxdepth 1 | sed 's/^\.\///g')
    else
      msg "🔍 Listing all files under \"$path\"..."
      files=$(find . -type f | sed 's/^\.\///g')
    fi

    # sort to maintain always the same order for hash
    files=$(echo "$files" | LC_ALL=C sort)

    if [[ -z "$files" ]]; then
      msg "🟫 No files found"
      return
    fi

    files_count=$(echo "$files" | wc -l | awk '{ print $1 }')
    msg "ℹ️ Found $files_count files"

    if [[ "$files_only" == true ]]; then
      msg "#️⃣ Calculating hash for files in path \"$path\"..."
    else
      msg "#️⃣ Calculating hash for directory \"$path\"..."
    fi

    # replace newlines with zero byte to distinct between whitespaces in names and next files
    # "md5sum --" to signal start of file names in case file name starts with "-"
    hash=$(echo "$files" | tr '\n' '\0' | parallel -0 -k -m md5sum -- | md5sum | awk '{ print $1 }')
    msg "ℹ️ Hash is: $hash"

    s3_hash=$(rclone cat --error-on-no-transfer "backup:$bucket/$archive_name.md5" || echo "")

    if [[ "$hash" == "$s3_hash" ]] && [[ $(rclone lsf "backup:$bucket/$archive_name" | wc -l) -eq 1 ]]; then
      msg "🟨 File $archive_name already exists with the same content hash"
    else
      msg "⬆️ Uploading file $archive_name"

      if [[ "$dry_run" != true ]]; then
        args=(
          "${rclone_args[@]}"
          "--s3-chunk-size" "${chunk_size_mb}Mi"
        )

        echo "$files" | tr '\n' '\0' | xargs -0 tar -zcf - -- |
          rclone rcat "${args[@]}" "backup:$bucket/$archive_name"

        echo "$hash" | rclone rcat --s3-no-check-bucket "backup:$bucket/$archive_name.md5"
        echo "$files" | rclone rcat --s3-no-check-bucket "backup:$bucket/$archive_name.txt"

        msg "🟩 File $archive_name uploaded"
      fi
    fi
  )
}

# Arguments:
# - path - the path relative to $root_path
# - depth - the level from the $root_path
traverse_path() {
  local path=$1
  local depth=${2-1}

  cd "$root_path/$path" || die "Can't access $root_path/$path"

  backup_path "$root_path/$path" "$path/_files" true

  # read directories to array, taking into account possible spaces in names, see: https://stackoverflow.com/a/23357277/2512304
  local dirs=()
  while IFS= read -r -d $'\0'; do
    dirs+=("$REPLY")
  done < <(find . -mindepth 1 -maxdepth 1 -type d -print0)

  if [[ -n "${dirs:-}" ]]; then # if dirs is not unbound due to no elements
    for dir in "${dirs[@]}"; do
      if [[ "$dir" != *\$RECYCLE.BIN && "$dir" != *.Trash-1000 && "$dir" != *System\ Volume\ Information ]]; then
        if [[ $depth -eq $split_depth ]]; then
          backup_path "$root_path/$path/$dir" "$path/$dir" false
        else
          traverse_path "$path/$dir" $((depth + 1))
        fi
      fi
    done
  fi
}

parse_params "$@"
main

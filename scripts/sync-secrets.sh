#!/bin/sh
# sops binary の設定ファイルを利用者の権限で復号する。秘密は出力にも Nix 評価にも渡さない。
# 第1引数 sync|prune、第2引数 .env.d、第3引数保存先、第4引数ツール、第5引数YubiKey識別子。
set -eu
action=$1
env_dir=$2
state_dir=$3
tools=$4
identities=$5
umask 077
mkdir -p "$state_dir"
[ ! -L "$state_dir" ] || { echo 'error: 秘密の保存先がシンボリックリンクです' >&2; exit 1; }
chmod 700 "$state_dir"
lock="$state_dir/.lock"
mkdir "$lock" 2>/dev/null || { echo 'error: 秘密の同期が実行中です。実行が終了したか確認してください' >&2; exit 1; }
tmp=""
tty_state=""
cleanup() {
  status=$?
  trap - EXIT
  trap '' HUP INT TERM PIPE
  if [ -n "$tty_state" ]; then stty "$tty_state" </dev/tty 2>/dev/null || :; fi
  [ -z "$tmp" ] || rm -rf -- "$tmp"
  rmdir "$lock" 2>/dev/null || :
  exit "$status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 141' PIPE
if [ "$action" = prune ]; then
  for snapshot in "$state_dir"/.*.sops; do
    [ -f "$snapshot" ] || continue
    name=${snapshot##*/}; name=${name#.}; name=${name%.sops}
    [ -f "$env_dir/$name.sops" ] || rm -f -- "$snapshot" "$state_dir/$name"
  done
  exit 0
fi
[ "$action" = sync ] || exit 2
# 秘密の名前はファイル名に使うので、パスや制御文字を認めない。
for cipher in "$env_dir"/*.sops; do
  [ -f "$cipher" ] || continue
  name=${cipher##*/}; name=${name%.sops}
  case $name in ''|*[!a-zA-Z0-9_-]*) echo 'error: .sops の名前は英数字、_、-にしてください' >&2; exit 1;; esac
done
tmp=$(mktemp -d "$state_dir/.work.XXXXXX")
mkdir "$tmp/config"
: >"$state_dir/.warnings"
warn() {
  printf 'warning: %s: %s。前回の復号結果があれば保持します。\n' "$name" "$1" >&2
  printf '  %s: %s\n' "$name" "$1" >>"$state_dir/.warnings"
}
ready=0
blocked=0
for cipher in "$env_dir"/*.sops; do
  [ -f "$cipher" ] || continue
  name=${cipher##*/}; name=${name%.sops}
  output="$state_dir/$name"
  snapshot="$state_dir/.$name.sops"
  # 出力がリンクなら信用しない。暗号文の更新成功時にだけ比較用の写しを更新する。
  if [ -f "$output" ] && [ ! -L "$output" ] && cmp -s "$cipher" "$snapshot"; then
    chmod 400 "$output"
    continue
  fi
  if [ "$blocked" = 1 ]; then warn '先の復号失敗後のため、PIN試行を増やさず復号を省略'; continue; fi
  cp -- "$cipher" "$tmp/cipher"
  # 自動検出のソフトウェア鍵や別の .sops.yaml を使わせない。filestatus は鍵を使用しない。
  if ! status=$(env -u SOPS_AGE_KEY -u SOPS_AGE_KEY_CMD -u SOPS_AGE_SSH_PRIVATE_KEY_FILE \
    -u SOPS_AGE_SSH_PRIVATE_KEY_CMD -u SOPS_AGE_RECIPIENTS \
    XDG_CONFIG_HOME="$tmp/config" SOPS_AGE_KEY_FILE="$tmp/selected" \
    "$tools/bin/sops" --config /dev/null filestatus --input-type binary "$tmp/cipher" 2>/dev/null) ||
    [ "$status" != '{"encrypted":true}' ]; then
    warn 'sopsのbinary暗号文として読めません'; continue
  fi
  if [ "$ready" = 0 ]; then
    if ! ( : </dev/tty ) 2>/dev/null; then warn '対話端末がないため復号できません'; continue; fi
    if [ ! -r "$identities" ]; then warn 'YubiKey識別子がありません。READMEの手順で登録してください'; continue; fi
    # --list は公開情報だけ。失敗しても、途中まで取得できた公開鍵を利用する。
    "$tools/bin/age-plugin-yubikey" --list >"$tmp/connected" 2>/dev/null || :
    # 登録順で、挿している1本の1スロットだけを選ぶ。ソフトウェア秘密鍵は読み込まない。
    awk '
      NR == FNR { if ($0 ~ /^age1yubikey1/) connected[$0]=1; next }
      /^#/ && /Recipient:/ { recipient=$NF }
      /^AGE-PLUGIN-YUBIKEY-/ && connected[recipient] { print; exit }
    ' "$tmp/connected" "$identities" >"$tmp/selected"
    if [ ! -s "$tmp/selected" ]; then warn '登録したYubiKeyが接続されていません'; continue; fi
    awk '
      NR == FNR { if ($0 ~ /^age1yubikey1/) connected[$0]=1; next }
      /^#/ && /Recipient:/ { recipient=$NF }
      /^AGE-PLUGIN-YUBIKEY-/ && connected[recipient] { print recipient; exit }
    ' "$tmp/connected" "$identities" >"$tmp/recipient"
    tty_state=$(stty -g </dev/tty)
    ready=1
    printf 'YubiKeyで復号します。PINを求められたら入力し、LEDが点滅したらタッチしてください。\n'
  fi
  recipient=$(cat "$tmp/recipient")
  if ! grep -qF "$recipient" "$tmp/cipher"; then warn '接続したYubiKeyが暗号文の受信者にありません'; continue; fi
  printf '%s を復号します。\n' "$name"
  # 設定ファイルの中身や秘密を含み得るエラー詳細は表示しない。
  if ! env -u SOPS_AGE_KEY -u SOPS_AGE_KEY_CMD -u SOPS_AGE_SSH_PRIVATE_KEY_FILE \
    -u SOPS_AGE_SSH_PRIVATE_KEY_CMD -u SOPS_AGE_RECIPIENTS \
    XDG_CONFIG_HOME="$tmp/config" SOPS_AGE_KEY_FILE="$tmp/selected" PATH="$tools/bin:$PATH" \
    "$tools/bin/sops" --config /dev/null decrypt --input-type binary --output-type binary "$tmp/cipher" \
    >"$tmp/plain" 2>"$tmp/error"; then
    stty "$tty_state" </dev/tty 2>/dev/null || :
    warn '復号に失敗しました。PINやタッチを確認してください'; blocked=1; continue
  fi
  stty "$tty_state" </dev/tty 2>/dev/null || :
  chmod 400 "$tmp/plain"
  # 先に古い写しを外す。出力更新後に写しの更新が失敗しても、次回は必ず再復号する。
  rm -f -- "$snapshot"
  mv -f -- "$tmp/plain" "$output"
  cp -- "$tmp/cipher" "$tmp/snapshot"
  chmod 600 "$tmp/snapshot"
  mv -f -- "$tmp/snapshot" "$snapshot"
done

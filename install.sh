#!/usr/bin/env bash
# Установка BBS Terminal по приглашению ББШ. Код приглашения приходит в BBS_INVITE.
set -euo pipefail
umask 077

API=https://babloshot.com/user/bbs-distribution
REPO=freefragv2/bbs-terminal-releases
PUBLIC_KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKDU47vx44Hfugrc96xTgvCQlFOprhdpfJBFIxXNoBni'
STATE=/etc/bbs-client-distribution

fail() { printf 'Установка BBS Terminal: %s\n' "$*" >&2; exit 1; }

main() {
  local package="" namespace="" script="" target_key=""
  case "${1:-}" in
    core)
      package=core
      namespace=bbs-terminal-release
      script=install.sh
      target_key=/etc/bbs/releases_token
      ;;
    superclient)
      package=superclient
      namespace=bbs-superclient-release
      script=install-sc.sh
      target_key=/etc/bbs-superclient/releases_token
      ;;
    *) fail 'укажите пакет core или superclient' ;;
  esac
  [ "$#" = 1 ] || fail 'допускается один пакет'
  [ "$(id -u)" = 0 ] || fail 'откройте root-консоль (sudo -i) и повторите команду'
  command -v curl >/dev/null || fail 'установите curl и повторите команду'
  command -v flock >/dev/null || fail 'нужна команда flock из util-linux'
  [ "$(dpkg --print-architecture 2>/dev/null)" = amd64 ] || fail 'пакет рассчитан на Linux amd64'
  local invite="${BBS_INVITE:-}"
  unset BBS_INVITE
  [[ "$invite" =~ ^[a-f0-9]{64}$ ]] || fail 'скопируйте команду со страницы приглашения'

  install -d -m 700 "$STATE"
  local key="$STATE/$package.key" installation
  exec 9>"$STATE/$package.lock"
  flock -n 9 || fail 'установка этого пакета уже запущена'
  if [ ! -e "$key" ]; then
    [ ! -e "$target_key" ] || fail 'на сервере уже настроен другой канал обновлений'
    od -An -N32 -tx1 /dev/urandom | tr -d ' \n' > "$key.new"
    mv -f -- "$key.new" "$key"
  fi
  installation=$(cat "$key")
  [[ "$installation" =~ ^[a-f0-9]{64}$ ]] || fail 'повреждён локальный ключ установки'
  if [ -e "$target_key" ] && [ "$(tr -d ' \r\n' < "$target_key")" != "$installation" ]; then
    fail 'на сервере уже настроен другой канал обновлений'
  fi
  if ! command -v ssh-keygen >/dev/null; then
    DEBIAN_FRONTEND=noninteractive apt-get update -q &&
      DEBIAN_FRONTEND=noninteractive apt-get install -y -q openssh-client ||
      fail 'не удалось установить openssh-client'
  fi

  local tmp
  tmp=$(mktemp -d /root/.bbs-client.XXXXXX)
  trap "rm -rf -- '$tmp'" EXIT
  # После первой успешной привязки повтор может пройти с той же командой даже после истечения ссылки.
  if ! printf 'header = "Authorization: Bearer %s"\nheader = "X-BBS-Installation: %s"\n' "$invite" "$installation" |
    curl --silent --show-error --fail --proto =https --max-time 20 -K - \
      -H "X-BBS-Package: $package" -X POST -o /dev/null "$API/claim"; then
    fail 'приглашение недоступно. Проверьте срок действия или запросите новую ссылку'
  fi

  download() {
    printf 'header = "Authorization: Bearer %s"\n' "$installation" |
      curl --silent --show-error --fail --proto =https --max-time 60 --max-filesize 1048576 -K - \
        -o "$2" "$API/repos/$REPO/contents/$1?ref=channels"
  }
  download "$script" "$tmp/install.sh" && download "$script.sig" "$tmp/install.sig" ||
    fail 'не удалось скачать установщик. Повторите ту же команду'
  printf '%s namespaces="%s" %s\n' "$namespace" "$namespace" "$PUBLIC_KEY" > "$tmp/signers"
  ssh-keygen -Y verify -f "$tmp/signers" -I "$namespace" -n "$namespace" \
    -s "$tmp/install.sig" < "$tmp/install.sh" >/dev/null 2>&1 ||
    fail 'подпись установщика не сошлась'

  if [ "$package" = core ]; then
    BBS_RELEASES_API="$API" BBS_TOKEN="$installation" bash "$tmp/install.sh"
  else
    SC_RELEASES_API="$API" SC_TOKEN="$installation" bash "$tmp/install.sh"
  fi
  if ! printf 'header = "Authorization: Bearer %s"\n' "$installation" |
    curl --silent --show-error --fail --proto =https --max-time 15 -K - \
      -X POST -o /dev/null "$API/installed"; then
    printf 'Пакет установлен. ББШ пока не получил отметку об установке.\n' >&2
  fi
}

main "$@"

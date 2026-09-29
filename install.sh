#!/usr/bin/env bash
#
# Hermes Agent - auto instalador (ponto de entrada)
#
# Baixa este repositorio e inicia a instalacao escolhida:
#
#   curl -fsSL https://raw.githubusercontent.com/AstraOnlineWeb/hermes-autoinstall/main/install.sh | sudo bash
#
# Para pular o menu, informe o modo:
#
#   curl -fsSL .../install.sh | sudo bash -s -- docker
#
# As variaveis de ambiente dos instaladores (ASSUME_YES, HERMES_DOMAIN, ACME_EMAIL...)
# sao repassadas. Veja o README de cada modo.

set -euo pipefail

AUTOINSTALL_REPO="${AUTOINSTALL_REPO:-AstraOnlineWeb/hermes-autoinstall}"
AUTOINSTALL_BRANCH="${AUTOINSTALL_BRANCH:-main}"
AUTOINSTALL_TARBALL_URL="${AUTOINSTALL_TARBALL_URL:-https://github.com/$AUTOINSTALL_REPO/archive/refs/heads/$AUTOINSTALL_BRANCH.tar.gz}"
AUTOINSTALL_DIR="${AUTOINSTALL_DIR:-/opt/hermes-autoinstall}"
ASSUME_YES="${ASSUME_YES:-0}"
MODE="${1:-${MODE:-}}"
NATIVO_DISPONIVEL=0   # o modo nativo (sem Docker) esta em validacao

C_RESET="\033[0m"; C_BLUE="\033[1;34m"; C_GREEN="\033[1;32m"; C_YELLOW="\033[1;33m"; C_RED="\033[1;31m"
log() { echo -e "${C_BLUE}==>${C_RESET} $*"; }
ok()  { echo -e "${C_GREEN}  ✓${C_RESET} $*"; }
die() { echo -e "${C_RED}  ✗${C_RESET} $*" >&2; exit 1; }

main() {
  [ "$(id -u)" -eq 0 ] || die "Execute como root. Exemplo: curl -fsSL <endereco> | sudo bash"
  command -v apt-get >/dev/null 2>&1 || die "Este instalador suporta apenas Debian e Ubuntu."

  # Com "curl | bash" a entrada padrao e o proprio script; as perguntas sao lidas do terminal.
  local tty_ok=0
  if [ -t 0 ]; then tty_ok=1
  elif [ "$ASSUME_YES" != "1" ] && { : < /dev/tty; } 2>/dev/null; then tty_ok=2
  fi

  echo -e "${C_GREEN}"
  echo "============================================================"
  echo "  Hermes Agent - Auto Instalador"
  echo "============================================================"
  echo -e "${C_RESET}"

  if [ "$NATIVO_DISPONIVEL" != "1" ]; then
    case "$MODE" in
      ""|docker) MODE="docker" ;;
      nativo|native|manual) die "O modo nativo (sem Docker) ainda esta em validacao e sera publicado em breve. Use o modo docker." ;;
    esac
  fi

  case "$MODE" in
    docker|nativo) ;;
    native|manual) MODE="nativo" ;;
    "")
      [ "$ASSUME_YES" != "1" ] || die "Modo nao-interativo: informe o modo (docker ou nativo). Exemplo: ... | sudo bash -s -- nativo"
      [ "$tty_ok" != "0" ] || die "Sem terminal para perguntar. Informe o modo: ... | sudo bash -s -- docker   (ou nativo)"
      echo "  Como voce quer instalar o Hermes?"
      echo
      echo "    1) Docker  - Docker Swarm + Traefik + Portainer + Hermes em container."
      echo "                 Indicado para quem vai rodar outros sistemas na mesma VPS."
      echo
      echo "    2) Nativo  - Hermes direto na VPS (sem Docker), com Caddy para o HTTPS."
      echo "                 Indicado para uma VPS dedicada ao agente: ele tem acesso"
      echo "                 ao sistema e pode instalar e usar programas da maquina."
      echo
      local reply=""
      while :; do
        if [ "$tty_ok" = "2" ]; then
          read -r -p "$(echo -e "${C_YELLOW}?${C_RESET} Escolha 1 ou 2: ")" reply < /dev/tty
        else
          read -r -p "$(echo -e "${C_YELLOW}?${C_RESET} Escolha 1 ou 2: ")" reply
        fi
        case "$reply" in
          1|docker|Docker) MODE="docker"; break ;;
          2|nativo|Nativo) MODE="nativo"; break ;;
        esac
      done
      ;;
    *) die "Modo desconhecido: '$MODE'. Use: docker ou nativo" ;;
  esac

  if ! command -v curl >/dev/null 2>&1 || ! command -v tar >/dev/null 2>&1; then
    log "Instalando curl e tar"
    DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null
    DEBIAN_FRONTEND=noninteractive apt-get install -y curl tar ca-certificates >/dev/null
  fi

  log "Baixando o instalador ($AUTOINSTALL_REPO, ramo $AUTOINSTALL_BRANCH)"
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  curl -fsSL --retry 3 "$AUTOINSTALL_TARBALL_URL" -o "$tmp/repo.tar.gz" || die "Nao foi possivel baixar $AUTOINSTALL_TARBALL_URL"
  mkdir -p "$tmp/src"
  tar -xzf "$tmp/repo.tar.gz" -C "$tmp/src" --strip-components=1 || die "Arquivo baixado invalido."
  [ -f "$tmp/src/$MODE/install.sh" ] || die "O instalador '$MODE' nao foi encontrado no pacote baixado."

  # Atualiza os arquivos do instalador. Arquivos gerados em instalacoes anteriores sao mantidos.
  mkdir -p "$AUTOINSTALL_DIR"
  cp -a "$tmp/src/." "$AUTOINSTALL_DIR/"
  chmod 700 "$AUTOINSTALL_DIR"
  chmod +x "$AUTOINSTALL_DIR/install.sh" "$AUTOINSTALL_DIR"/*/install.sh
  ok "Instalador salvo em $AUTOINSTALL_DIR"
  echo

  cd "$AUTOINSTALL_DIR/$MODE"
  if [ "$tty_ok" = "2" ]; then
    exec bash "$AUTOINSTALL_DIR/$MODE/install.sh" < /dev/tty
  else
    exec bash "$AUTOINSTALL_DIR/$MODE/install.sh"
  fi
}

# O script inteiro fica dentro de main() para que um download interrompido nao execute pela metade.
main "$@"

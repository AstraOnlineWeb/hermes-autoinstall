#!/usr/bin/env bash
#
# Auto instalador NATIVO (sem Docker): Hermes Agent + Caddy (HTTPS) + plugins
#
# O Hermes roda direto na VPS, como servico do systemd, com um usuario proprio.
# O painel escuta apenas em 127.0.0.1 e e publicado pelo Caddy com certificado
# Let's Encrypt. O subdominio e OBRIGATORIO.
#
# Uso interativo:
#   sudo bash install.sh
#
# Uso nao-interativo:
#   sudo ASSUME_YES=1 \
#        HERMES_DOMAIN=hermes.seudominio.com.br \
#        bash install.sh
#
# Simulacao sem alterar o sistema:  DRY_RUN=1 bash install.sh

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults (podem ser sobrescritos por variaveis de ambiente)
# ---------------------------------------------------------------------------
ASSUME_YES="${ASSUME_YES:-0}"
DRY_RUN="${DRY_RUN:-0}"

ACME_EMAIL="${ACME_EMAIL:-}"
HERMES_DOMAIN="${HERMES_DOMAIN:-}"                 # OBRIGATORIO
HERMES_USER="${HERMES_USER:-admin}"                # usuario do painel
HERMES_PASSWORD="${HERMES_PASSWORD:-}"             # vazio = gerada automaticamente

HERMES_SYSTEM_USER="${HERMES_SYSTEM_USER:-hermes}" # usuario Linux que roda o agente
DASHBOARD_PORT="${DASHBOARD_PORT:-9119}"           # so em 127.0.0.1
API_PORT="${API_PORT:-8642}"                       # so em 127.0.0.1
CHATWOOT_PORT="${CHATWOOT_PORT:-8646}"             # webhook do plugin chatwoot, so em 127.0.0.1
CADDY_BEGIN="# >>> hermes-autoinstall >>>"
CADDY_END="# <<< hermes-autoinstall <<<"

HERMES_SUDO_SET=0;     [ -n "${HERMES_SUDO+x}" ]     && HERMES_SUDO_SET=1
INSTALL_PLUGINS_SET=0; [ -n "${INSTALL_PLUGINS+x}" ] && INSTALL_PLUGINS_SET=1
HERMES_SUDO="${HERMES_SUDO:-0}"                    # 1 = agente com sudo sem senha
INSTALL_PLUGINS="${INSTALL_PLUGINS:-1}"
PLUGINS_REPO="${PLUGINS_REPO:-AstraOnlineWeb/hermes-plugins}"
PLUGINS="${PLUGINS:-codex-oauth hermes-pwa chatwoot}"

HERMES_INSTALL_URL="${HERMES_INSTALL_URL:-https://hermes-agent.nousresearch.com/install.sh}"
STATE_DIR="${STATE_DIR:-/opt/autoinstall}"
STATE_FILE="$STATE_DIR/credenciais-nativo.env"
ACCESS_FILE="${ACCESS_FILE:-/root/acessos.txt}"

# preenchidas em tempo de execucao
SERVER_IP=""
HERMES_AUTH_SECRET=""
HERMES_API_KEY=""
USER_HOME=""
HERMES_HOME_DIR=""
HERMES_BIN=""
SSL_OK="nao verificado"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
C_RESET="\033[0m"; C_BLUE="\033[1;34m"; C_GREEN="\033[1;32m"
C_YELLOW="\033[1;33m"; C_RED="\033[1;31m"; C_BOLD="\033[1m"

log()  { echo -e "${C_BLUE}==>${C_RESET} $*"; }
ok()   { echo -e "${C_GREEN}  ✓${C_RESET} $*"; }
warn() { echo -e "${C_YELLOW}  !${C_RESET} $*"; }
err()  { echo -e "${C_RED}  ✗${C_RESET} $*" >&2; }
die()  { err "$*"; exit 1; }

is_dry() { [ "$DRY_RUN" = "1" ]; }
run() { if is_dry; then echo "      [dry-run] $*"; else "$@"; fi; }

# Quando o script chega por "curl ... | bash", a entrada padrao e o proprio script.
# As perguntas passam a ser lidas do terminal.
if [ "$ASSUME_YES" != "1" ] && [ ! -t 0 ] && [ -r /dev/tty ]; then
  exec < /dev/tty
fi

clean_input() {
  # Remove sequencias de escape (teclas Delete, setas...) e caracteres de controle digitados sem querer
  printf '%s' "$1" | sed -e 's/\x1b\[[0-9;]*[A-Za-z~]//g' -e 's/\[[0-9;]*~//g' | tr -d '\000-\037\177'
}

ask() {
  local __var="$1" __prompt="$2" __default="${3:-}" __input=""
  local __current="${!__var:-}"
  [ -n "$__current" ] && __default="$__current"
  if [ "$ASSUME_YES" = "1" ]; then
    [ -z "$__default" ] && die "Modo nao-interativo: defina a variavel $__var"
    printf -v "$__var" '%s' "$__default"
    return
  fi
  if [ -n "$__default" ]; then
    read -e -r -p "$(echo -e "${C_YELLOW}?${C_RESET} $__prompt [$__default]: ")" __input
    __input="${__input:-$__default}"
  else
    while [ -z "$__input" ]; do
      read -e -r -p "$(echo -e "${C_YELLOW}?${C_RESET} $__prompt: ")" __input
    done
  fi
  __input="$(clean_input "$__input")"
  printf -v "$__var" '%s' "$__input"
}

confirm() {
  local __def="${2:-n}" __reply="" __hint="[s/N]"
  [ "$__def" = "s" ] && __hint="[S/n]"
  [ "$ASSUME_YES" = "1" ] && return 0
  read -e -r -p "$(echo -e "${C_YELLOW}?${C_RESET} $1 $__hint: ")" __reply
  __reply="${__reply:-$__def}"
  [[ "$__reply" =~ ^([sS]|[yY])$ ]]
}

require_root() { [ "$(id -u)" -eq 0 ] || die "Execute como root (use: sudo bash install.sh)"; }

require_supported_os() {
  command -v apt-get >/dev/null 2>&1 || die "Este instalador suporta apenas Debian/Ubuntu (apt-get nao encontrado)."
  command -v systemctl >/dev/null 2>&1 || die "systemd nao encontrado. Este instalador precisa do systemd."
}

detect_ip() {
  local ip=""
  ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '/src/ {for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n1)"
  [ -z "$ip" ] && ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  echo "$ip"
}

detect_public_ip() {
  local ip=""
  ip="$(curl -fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"
  [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || ip="$(detect_ip)"
  echo "$ip"
}

gen_password() {
  local p=""
  while [ "${#p}" -lt 20 ]; do p="$p$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9')"; done
  echo "${p:0:20}"
}
gen_hex() { openssl rand -hex 32; }

validate_secret() {
  local name="$1" value="$2" min="$3"
  [ "${#value}" -ge "$min" ] || die "$name precisa ter pelo menos $min caracteres."
  [[ "$value" =~ ^[A-Za-z0-9@%+=_.-]+$ ]] || \
    die "$name contem caracteres nao permitidos. Use apenas letras, numeros e @ % + = _ . -"
}

validate_domain() {
  local name="$1" value="$2"
  [[ "$value" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]] || \
    die "$name invalido: '$value' (informe apenas o dominio, sem http:// e sem barra)"
}

check_dns() {
  local domain="$1" resolved=""
  resolved="$( (getent ahostsv4 "$domain" 2>/dev/null || true) | awk '{print $1}' | sort -u | tr '\n' ' ')"
  if [ -z "$resolved" ]; then
    warn "DNS: '$domain' ainda nao resolve. Crie um registro A apontando para $SERVER_IP."
  elif ! echo " $resolved" | grep -q " $SERVER_IP "; then
    warn "DNS: '$domain' aponta para [ $resolved] e nao para $SERVER_IP. O certificado SSL nao sera emitido ate corrigir."
  else
    ok "DNS: '$domain' aponta para $SERVER_IP"
  fi
}

port_owner() {
  # nome do processo que escuta na porta, ou vazio
  ss -ltnpH 2>/dev/null | awk -v p=":$1" '$4 ~ p"$" {print $NF}' | grep -oE '"[^"]+"' | head -n1 | tr -d '"' || true
}

as_hermes() {
  # executa um comando como o usuario do agente, com o ambiente de login dele
  su - "$HERMES_SYSTEM_USER" -c "$*"
}

http_code() { curl -s -o /dev/null -w '%{http_code}' --max-time "${2:-5}" "$1" 2>/dev/null || true; }

# ---------------------------------------------------------------------------
# Estado
# ---------------------------------------------------------------------------
load_state() {
  [ -f "$STATE_FILE" ] || return 0
  local k v
  while IFS='=' read -r k v; do
    case "$k" in
      HERMES_PASSWORD)    [ -z "$HERMES_PASSWORD" ] && HERMES_PASSWORD="$v" ;;
      HERMES_AUTH_SECRET) HERMES_AUTH_SECRET="$v" ;;
      HERMES_API_KEY)     HERMES_API_KEY="$v" ;;
      # escolha anterior de sudo vale ao rodar de novo sem perguntas, salvo se HERMES_SUDO for informado
      HERMES_SUDO)        [ "$HERMES_SUDO_SET" = "1" ] || [ "$ASSUME_YES" != "1" ] || HERMES_SUDO="$v" ;;
    esac
  done < "$STATE_FILE"
  ok "Credenciais de uma instalacao anterior reaproveitadas ($STATE_FILE)"
}

save_state() {
  is_dry && return 0
  mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"
  umask 077
  {
    echo "HERMES_PASSWORD=$HERMES_PASSWORD"
    echo "HERMES_AUTH_SECRET=$HERMES_AUTH_SECRET"
    echo "HERMES_API_KEY=$HERMES_API_KEY"
    echo "HERMES_SUDO=$HERMES_SUDO"
  } > "$STATE_FILE"
  chmod 600 "$STATE_FILE"
}

prepare_secrets() {
  [ -n "$HERMES_PASSWORD" ]    || HERMES_PASSWORD="$(gen_password)"
  [ -n "$HERMES_AUTH_SECRET" ] || HERMES_AUTH_SECRET="$(gen_hex)"
  [ -n "$HERMES_API_KEY" ]     || HERMES_API_KEY="$(gen_hex)"
  validate_secret "HERMES_PASSWORD" "$HERMES_PASSWORD" 8
  validate_secret "HERMES_USER" "$HERMES_USER" 3
}

# ---------------------------------------------------------------------------
# Etapas
# ---------------------------------------------------------------------------
step_preflight() {
  log "Conferindo o servidor"
  local p owner
  for p in 80 443; do
    owner="$(port_owner "$p")"
    if [ -n "$owner" ] && [ "$owner" != "caddy" ]; then
      die "A porta $p ja esta em uso por '$owner'. O modo nativo usa o Caddy nas portas 80 e 443. Pare esse servico ou use o instalador Docker."
    fi
  done
  if command -v docker >/dev/null 2>&1 && docker info 2>/dev/null | grep -q "Swarm: active"; then
    warn "Este servidor tem Docker Swarm ativo. Se o Traefik estiver publicado, vai conflitar com o Caddy."
  fi
  local mem_mb disk_gb
  mem_mb="$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)"
  disk_gb="$(df -BG --output=avail / | tail -n1 | tr -dc '0-9')"
  [ "$mem_mb" -ge 1800 ] || warn "Pouca memoria (${mem_mb} MB). Recomendado: 4 GB."
  [ "$disk_gb" -ge 8 ]   || die "Pouco espaco em disco (${disk_gb} GB livres). Sao necessarios pelo menos 8 GB."
  ok "Portas 80 e 443 livres, ${mem_mb} MB de memoria, ${disk_gb} GB livres"
}

step_packages() {
  log "Atualizando pacotes e instalando dependencias"
  export DEBIAN_FRONTEND=noninteractive
  run apt-get update -qq -y
  # libatomic1: exigida pelo Node que o instalador do Hermes baixa (ausente no Ubuntu minimo)
  run apt-get install -qq -y curl git ca-certificates openssl iproute2 tar xz-utils gnupg \
      libatomic1 debian-keyring debian-archive-keyring apt-transport-https
  ok "Pacotes instalados"
}

step_user() {
  if id "$HERMES_SYSTEM_USER" >/dev/null 2>&1; then
    ok "Usuario '$HERMES_SYSTEM_USER' ja existe"
  else
    log "Criando o usuario '$HERMES_SYSTEM_USER'"
    run useradd -m -s /bin/bash "$HERMES_SYSTEM_USER"
    ok "Usuario criado"
  fi
  if is_dry && ! id "$HERMES_SYSTEM_USER" >/dev/null 2>&1; then
    USER_HOME="/home/$HERMES_SYSTEM_USER"
  else
    USER_HOME="$(getent passwd "$HERMES_SYSTEM_USER" | cut -d: -f6)"
  fi
  HERMES_HOME_DIR="$USER_HOME/.hermes"
  HERMES_BIN="$USER_HOME/.local/bin/hermes"
}

step_install_hermes() {
  if [ -x "$HERMES_BIN" ] && as_hermes "hermes --version" >/dev/null 2>&1; then
    ok "Hermes ja instalado ($(as_hermes 'hermes --version' 2>/dev/null | head -n1))"
    return
  fi
  if is_dry; then echo "      [dry-run] instalaria o Hermes com o instalador oficial"; return; fi
  log "Instalando o Hermes Agent (instalador oficial; leva de 3 a 6 minutos)"
  local logf="/var/log/hermes-autoinstall-oficial.log"
  if as_hermes "curl -fsSL '$HERMES_INSTALL_URL' | bash -s -- --skip-setup --skip-computer-use" > "$logf" 2>&1 < /dev/null; then
    ok "Hermes instalado"
  else
    err "O instalador oficial do Hermes falhou. Ultimas linhas de $logf:"
    sed 's/\x1b\[[0-9;]*m//g' "$logf" | tr '\r' '\n' | grep -vE '^\s*$|MiB|Updating files' | tail -n 12 | sed 's/^/      /'
    die "Corrija o problema acima e rode o instalador de novo."
  fi
  [ -x "$HERMES_BIN" ] || die "O executavel do Hermes nao foi encontrado em $HERMES_BIN"
}

step_configure() {
  log "Configurando o Hermes (login do painel, API e URL publica)"
  local envf="$HERMES_HOME_DIR/.env" tmp
  if is_dry; then echo "      [dry-run] gravaria o bloco de configuracao em $envf"; return; fi
  mkdir -p "$HERMES_HOME_DIR"
  touch "$envf"
  tmp="$(mktemp)"
  # remove o bloco de uma execucao anterior e grava o novo no final
  sed '/^# >>> autoinstall >>>$/,/^# <<< autoinstall <<<$/d' "$envf" > "$tmp"
  {
    cat "$tmp"
    echo "# >>> autoinstall >>>"
    echo "# Bloco gerenciado pelo auto instalador. Alteracoes aqui sao sobrescritas ao reinstalar."
    echo "HERMES_DASHBOARD_PUBLIC_URL=https://$HERMES_DOMAIN"
    echo "HERMES_DASHBOARD_BASIC_AUTH_USERNAME=$HERMES_USER"
    echo "HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=$HERMES_PASSWORD"
    echo "HERMES_DASHBOARD_BASIC_AUTH_SECRET=$HERMES_AUTH_SECRET"
    echo "API_SERVER_ENABLED=true"
    echo "API_SERVER_HOST=127.0.0.1"
    echo "API_SERVER_PORT=$API_PORT"
    echo "API_SERVER_KEY=$HERMES_API_KEY"
    echo "CHATWOOT_WEBHOOK_HOST=127.0.0.1"
    echo "CHATWOOT_WEBHOOK_PORT=$CHATWOOT_PORT"
    echo "# <<< autoinstall <<<"
  } > "$envf"
  rm -f "$tmp"
  chown "$HERMES_SYSTEM_USER":"$HERMES_SYSTEM_USER" "$envf"
  chmod 600 "$envf"
  ok "Configuracao gravada em $envf"
}

step_services() {
  log "Criando os servicos do systemd"
  local path_env="$USER_HOME/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  if is_dry; then
    echo "      [dry-run] criaria hermes-gateway.service e hermes-dashboard.service"
    return
  fi
  cat > /etc/systemd/system/hermes-gateway.service <<EOF
[Unit]
Description=Hermes Agent - gateway (canais de mensagem, API e agendamentos)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$HERMES_SYSTEM_USER
Group=$HERMES_SYSTEM_USER
WorkingDirectory=$USER_HOME
Environment=HOME=$USER_HOME
Environment=HERMES_HOME=$HERMES_HOME_DIR
Environment=PATH=$path_env
ExecStart=$HERMES_BIN gateway run --replace
Restart=always
RestartSec=5
TimeoutStopSec=90

[Install]
WantedBy=multi-user.target
EOF
  cat > /etc/systemd/system/hermes-dashboard.service <<EOF
[Unit]
Description=Hermes Agent - painel web (somente 127.0.0.1)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$HERMES_SYSTEM_USER
Group=$HERMES_SYSTEM_USER
WorkingDirectory=$USER_HOME
Environment=HOME=$USER_HOME
Environment=HERMES_HOME=$HERMES_HOME_DIR
Environment=PATH=$path_env
ExecStart=$HERMES_BIN dashboard --host 127.0.0.1 --port $DASHBOARD_PORT --no-open
Restart=always
RestartSec=5
TimeoutStopSec=90

[Install]
WantedBy=multi-user.target
EOF
  chmod 644 /etc/systemd/system/hermes-gateway.service /etc/systemd/system/hermes-dashboard.service
  systemctl daemon-reload
  systemctl enable hermes-gateway.service hermes-dashboard.service >/dev/null 2>&1
  systemctl restart hermes-gateway.service hermes-dashboard.service
  ok "Servicos criados e iniciados"
}

wait_hermes() {
  local timeout="${1:-300}" t0
  t0="$(date +%s)"
  while [ $(( $(date +%s) - t0 )) -lt "$timeout" ]; do
    if [ "$(http_code "http://127.0.0.1:$DASHBOARD_PORT/api/status")" = "200" ] && \
       [ "$(http_code "http://127.0.0.1:$API_PORT/v1/health")" = "200" ]; then
      return 0
    fi
    sleep 3
  done
  return 1
}

step_wait_and_secure() {
  is_dry && { echo "      [dry-run] aguardaria o Hermes e conferiria o login obrigatorio"; return; }
  log "Aguardando o Hermes iniciar"
  if wait_hermes 420; then
    ok "Hermes no ar (painel e API respondendo em 127.0.0.1)"
  else
    err "O Hermes nao iniciou. Ultimas linhas dos servicos:"
    journalctl -u hermes-dashboard -u hermes-gateway -n 15 --no-pager 2>/dev/null | sed 's/^/      /' || true
    die "Verifique: journalctl -u hermes-dashboard -u hermes-gateway"
  fi

  # TRAVA DE SEGURANCA. Em 127.0.0.1 sem URL publica o painel do Hermes dispensa o login e
  # entrega um token de sessao na propria pagina. Publicar isso atras de um proxy deixaria
  # o painel aberto. So seguimos se o login estiver de fato exigido.
  log "Conferindo que o painel exige login"
  local status page
  status="$(curl -s --max-time 5 "http://127.0.0.1:$DASHBOARD_PORT/api/status" || true)"
  page="$(curl -s -L --max-time 5 "http://127.0.0.1:$DASHBOARD_PORT/" || true)"
  page+="$(curl -s -L --max-time 5 -H "Host: $HERMES_DOMAIN" "http://127.0.0.1:$DASHBOARD_PORT/" || true)"
  if ! echo "$status" | grep -qE '"auth_required": *true'; then
    systemctl stop hermes-dashboard.service || true
    die "O painel NAO esta exigindo login (auth_required=false). Painel parado por seguranca; nada foi publicado."
  fi
  if echo "$page" | grep -qE '__HERMES_SESSION_TOKEN__ *= *"[A-Za-z0-9_-]{20,}"'; then
    systemctl stop hermes-dashboard.service || true
    die "O painel esta entregando um token de sessao na pagina. Painel parado por seguranca; nada foi publicado."
  fi
  if [ "$(http_code "http://127.0.0.1:$DASHBOARD_PORT/api/sessions")" != "401" ]; then
    systemctl stop hermes-dashboard.service || true
    die "Rotas internas do painel responderam sem login. Painel parado por seguranca; nada foi publicado."
  fi
  ok "Login obrigatorio confirmado"
}

caddy_block() {
  # Bloco do Hermes no Caddyfile. Fica entre marcadores para o instalador trocar so ele ao rodar de novo.
  cat <<EOF
$CADDY_BEGIN
# Bloco gerenciado pelo auto instalador do Hermes. Nao edite entre os marcadores:
# ele e regravado ao reinstalar. Outros sites podem ficar no resto do arquivo.
$HERMES_DOMAIN {
$( [ -n "$ACME_EMAIL" ] && printf '\ttls %s\n' "$ACME_EMAIL" )
	encode gzip

	# API compativel com OpenAI (protegida pela API_SERVER_KEY)
	@api path /v1 /v1/*
	handle @api {
		reverse_proxy 127.0.0.1:$API_PORT {
			flush_interval -1
		}
	}

	# Webhook do Chatwoot (plugin chatwoot; protegido pelo segredo que faz parte do endereco)
	@chatwoot path /chatwoot/webhook/*
	handle @chatwoot {
		reverse_proxy 127.0.0.1:$CHATWOOT_PORT
	}

	# Painel e app de celular
	handle {
		reverse_proxy 127.0.0.1:$DASHBOARD_PORT {
			flush_interval -1
		}
	}
}
$CADDY_END
EOF
}

write_caddyfile() {
  # Grava o bloco do Hermes preservando o que mais existir no Caddyfile (sites criados pelo
  # agente ou pelo usuario). So o bloco entre os marcadores e substituido.
  local cf="$1" tmp rest
  tmp="$(mktemp)"; rest="$(mktemp)"
  if [ -f "$cf" ]; then
    cp "$cf" "$cf.copia.$(date +%Y%m%d%H%M%S)"
    if grep -qF "$CADDY_BEGIN" "$cf"; then
      # formato atual: remove o bloco entre os marcadores
      awk -v b="$CADDY_BEGIN" -v e="$CADDY_END" '$0==b {skip=1; next} $0==e {skip=0; next} !skip' "$cf" > "$rest"
    elif grep -q "Gerado pelo auto instalador do Hermes" "$cf"; then
      # formato antigo (arquivo inteiro gerado): tira o cabecalho, o bloco global de e-mail
      # e o site do Hermes; mantem os demais sites
      awk -v d="$HERMES_DOMAIN {" '
        /^# Gerado pelo auto instalador do Hermes/ {next}
        !seen && $0=="{" {skip=1; next}
        $0==d {skip=1; seen=1; next}
        skip && $0=="}" {skip=0; next}
        skip {next}
        {if ($0 !~ /^[[:space:]]*$/) seen=1; print}' "$cf" > "$rest"
    elif grep -qE "^:80[[:space:]]*\{" "$cf" && grep -q "/usr/share/caddy" "$cf"; then
      : > "$rest"   # Caddyfile padrao do pacote (pagina de boas-vindas): descartado
    else
      # Caddyfile de terceiros: mantem tudo, menos um site antigo com o mesmo dominio
      awk -v d="$HERMES_DOMAIN {" '$0==d {skip=1; next} skip && $0=="}" {skip=0; next} !skip' "$cf" > "$rest"
    fi
  else
    : > "$rest"
  fi
  {
    caddy_block
    # remove linhas em branco do inicio e repetidas do restante
    awk 'NF {started=1} started {if (NF) {blank=0; print} else if (!blank) {blank=1; print}}' "$rest" | sed '1{/^$/d}' | \
      { if IFS= read -r first; then echo; printf '%s\n' "$first"; cat; fi; }
  } > "$tmp"
  cat "$tmp" > "$cf"
  rm -f "$tmp" "$rest"
  # guarda so as 5 copias mais recentes
  ls -1t "$cf".copia.* 2>/dev/null | tail -n +6 | xargs -r rm -f
}

step_caddy() {
  log "Instalando o Caddy (HTTPS automatico)"
  if is_dry; then echo "      [dry-run] instalaria o Caddy e gravaria /etc/caddy/Caddyfile"; return; fi
  export DEBIAN_FRONTEND=noninteractive
  if ! command -v caddy >/dev/null 2>&1; then
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | \
      gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
      > /etc/apt/sources.list.d/caddy-stable.list
    chmod o+r /usr/share/keyrings/caddy-stable-archive-keyring.gpg /etc/apt/sources.list.d/caddy-stable.list
    apt-get update -y >/dev/null
    apt-get install -y caddy >/dev/null
    ok "Caddy instalado ($(caddy version | awk '{print $1}'))"
  else
    ok "Caddy ja instalado ($(caddy version | awk '{print $1}'))"
  fi

  local cf="/etc/caddy/Caddyfile"
  write_caddyfile "$cf"
  caddy validate --config "$cf" --adapter caddyfile >/dev/null 2>&1 || die "Caddyfile invalido. Veja: caddy validate --config $cf"
  systemctl enable caddy >/dev/null 2>&1 || true
  systemctl restart caddy
  ok "Caddy configurado para $HERMES_DOMAIN"
}

step_firewall() {
  command -v ufw >/dev/null 2>&1 || return 0
  ufw status 2>/dev/null | grep -q "Status: active" || return 0
  log "Firewall UFW ativo: liberando as portas 80 e 443"
  run ufw allow 80/tcp  >/dev/null
  run ufw allow 443/tcp >/dev/null
  ok "Portas liberadas no UFW"
}

step_sudo() {
  local f="/etc/sudoers.d/hermes-agent"
  if [ "$HERMES_SUDO" = "1" ]; then
    log "Dando permissao de administrador (sudo) ao agente"
    if is_dry; then echo "      [dry-run] criaria $f"; return; fi
    echo "$HERMES_SYSTEM_USER ALL=(ALL) NOPASSWD:ALL" > "$f"
    chmod 440 "$f"
    if visudo -cf "$f" >/dev/null 2>&1; then
      ok "O agente pode executar comandos como root (sudo sem senha)"
    else
      rm -f "$f"; warn "Nao foi possivel validar o arquivo de sudo; permissao nao concedida."
    fi
  else
    if [ -f "$f" ] && ! is_dry; then rm -f "$f"; ok "Permissao de sudo do agente removida"; fi
  fi
}

step_install_plugins() {
  local p out failed=0 had=0
  [ "$INSTALL_PLUGINS" = "1" ] || { ok "Instalacao de plugins desativada (INSTALL_PLUGINS=0)"; return; }
  if is_dry; then
    for p in $PLUGINS; do echo "      [dry-run] hermes plugins install $PLUGINS_REPO/$p --enable"; done
    return
  fi
  log "Instalando plugins do repositorio $PLUGINS_REPO"
  for p in $PLUGINS; do
    # Plugin ja instalado: reinstala a versao atual do repositorio. A copia antiga fica guardada e
    # volta se a instalacao falhar. ("plugins update" nao funciona em toda versao do Hermes.)
    had=0; rm -rf "$HERMES_HOME_DIR/plugins/.$p.anterior"
    if [ -d "$HERMES_HOME_DIR/plugins/$p" ]; then
      had=1; mv "$HERMES_HOME_DIR/plugins/$p" "$HERMES_HOME_DIR/plugins/.$p.anterior"
    fi
    out="$(as_hermes "hermes plugins install '$PLUGINS_REPO/$p' --enable" 2>&1 < /dev/null || true)"
    if [ -f "$HERMES_HOME_DIR/plugins/$p/plugin.yaml" ]; then
      rm -rf "$HERMES_HOME_DIR/plugins/.$p.anterior"
      [ "$had" = "1" ] && ok "Plugin '$p' atualizado" || ok "Plugin '$p' instalado e habilitado"
    else
      if [ "$had" = "1" ]; then
        rm -rf "$HERMES_HOME_DIR/plugins/$p"; mv "$HERMES_HOME_DIR/plugins/.$p.anterior" "$HERMES_HOME_DIR/plugins/$p"
        warn "Nao foi possivel atualizar o plugin '$p'; a versao anterior foi mantida."
        continue
      fi
      failed=1
      err "Falha ao instalar o plugin '$p':"
      echo "$out" | grep -viE 'warning' | tail -n 5 | sed 's/^/      /'
    fi
  done

  log "Reiniciando o Hermes para carregar os plugins"
  systemctl restart hermes-gateway.service hermes-dashboard.service
  sleep 3
  if wait_hermes 300; then ok "Hermes reiniciado"; else warn "O Hermes demorou a voltar. Verifique: journalctl -u hermes-dashboard"; fi

  local ck tabs
  ck="$(mktemp)"
  curl -s -c "$ck" -o /dev/null --max-time 10 -H "Host: $HERMES_DOMAIN" -H "X-Forwarded-Proto: https" \
    -X POST "http://127.0.0.1:$DASHBOARD_PORT/auth/password-login" -H 'Content-Type: application/json' \
    -d "{\"provider\":\"basic\",\"username\":\"$HERMES_USER\",\"password\":\"$HERMES_PASSWORD\"}" || true
  # o cookie e marcado como "Secure"; aqui falamos com 127.0.0.1 em HTTP, entao ele vai no cabecalho
  local cookie
  cookie="$(awk '!/^#/ || /^#HttpOnly_/ {if (NF>=7) printf "%s=%s; ", $6, $7}' "$ck")"
  tabs="$(curl -s --max-time 10 -H "Host: $HERMES_DOMAIN" -H "X-Forwarded-Proto: https" -H "Cookie: $cookie" \
          "http://127.0.0.1:$DASHBOARD_PORT/api/dashboard/plugins" || true)"
  rm -f "$ck"
  for p in $PLUGINS; do
    if echo "$tabs" | grep -q "\"name\": *\"$p\""; then
      ok "Aba do plugin '$p' ativa no painel"
    else
      warn "Aba do plugin '$p' nao apareceu no painel"; failed=1
    fi
  done
  [ "$failed" = "0" ] || warn "Houve falha em algum plugin. Tente: su - $HERMES_SYSTEM_USER -c 'hermes plugins install $PLUGINS_REPO/<plugin> --enable'"
}

step_verify_public() {
  is_dry && { echo "      [dry-run] conferiria o HTTPS publico"; return; }
  log "Conferindo o acesso publico com HTTPS (emissao do certificado)"
  local i code
  for i in $(seq 1 40); do
    # --resolve evita depender de o servidor conseguir acessar o proprio IP publico
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 \
            --resolve "$HERMES_DOMAIN:443:127.0.0.1" "https://$HERMES_DOMAIN/login" 2>/dev/null || true)"
    if [ "$code" = "200" ]; then
      SSL_OK="sim"
      ok "https://$HERMES_DOMAIN respondendo com certificado valido"
      return
    fi
    sleep 3
  done
  SSL_OK="nao"
  warn "O certificado SSL ainda nao foi emitido. Confira o DNS e as portas 80/443. Veja: journalctl -u caddy"
}

# ---------------------------------------------------------------------------
# Resumo final
# ---------------------------------------------------------------------------
print_access() {
  local line="============================================================"
  local out=""
  out+="$line\n"
  out+="  DADOS DE ACESSO  ($(date '+%d/%m/%Y %H:%M'))\n"
  out+="$line\n\n"
  out+="  HERMES AGENT (painel)\n"
  out+="    Endereco : https://$HERMES_DOMAIN\n"
  out+="    Usuario  : $HERMES_USER\n"
  out+="    Senha    : $HERMES_PASSWORD\n"
  if [ "$SSL_OK" = "nao" ]; then
    out+="    ATENCAO  : o certificado SSL ainda nao foi emitido. Confira o DNS do subdominio.\n"
  fi
  if [ "$INSTALL_PLUGINS" = "1" ]; then
    out+="\n  HERMES - APP DE CELULAR (PWA)\n"
    out+="    Endereco : https://$HERMES_DOMAIN/pwa\n"
    out+="    Login    : o mesmo do painel\n"
    out+="\n  HERMES - CONECTAR ASSINATURA (ChatGPT/Codex ou Claude)\n"
    out+="    Endereco : https://$HERMES_DOMAIN/codex\n"
    out+="    Passo    : clique em \"Conectar\", abra o link e informe o codigo exibido.\n"
    out+="\n  HERMES - ATENDIMENTO PELO CHATWOOT (opcional)\n"
    out+="    Endereco : https://$HERMES_DOMAIN/chatwoot\n"
    out+="    Passo    : informe o endereco do Chatwoot, o ID da conta e o token de administrador.\n"
  fi
  out+="\n  HERMES - API (compativel com OpenAI)\n"
  out+="    Endereco : https://$HERMES_DOMAIN/v1\n"
  out+="    Chave    : $HERMES_API_KEY\n"
  out+="    Modelo   : hermes-agent\n"
  out+="\n  NO SERVIDOR\n"
  out+="    Usuario Linux do agente : $HERMES_SYSTEM_USER\n"
  out+="    Dados do Hermes         : $HERMES_HOME_DIR\n"
  out+="    Sudo para o agente      : $([ "$HERMES_SUDO" = "1" ] && echo "SIM (sem senha)" || echo "nao")\n"
  out+="    Usar o Hermes no terminal: su - $HERMES_SYSTEM_USER   e depois   hermes\n"
  out+="\n$line\n"

  echo
  echo -e "${C_GREEN}${C_BOLD}"
  echo -e "$out"
  echo -e "${C_RESET}"

  if ! is_dry; then
    umask 077
    echo -e "$out" > "$ACCESS_FILE"
    chmod 600 "$ACCESS_FILE"
    ok "Dados de acesso salvos em $ACCESS_FILE (somente root le)"
  fi
  echo
  echo "  Proximo passo: abra o painel do Hermes e conecte um provedor de IA"
  echo "  (aba \"Codex / Claude\" para assinatura, ou \"Keys\" para chave de API)."
  echo
  echo "  Comandos uteis:"
  echo "    systemctl status hermes-gateway hermes-dashboard caddy"
  echo "    journalctl -u hermes-gateway -f"
  echo "    journalctl -u hermes-dashboard -f"
  echo "    systemctl restart hermes-gateway hermes-dashboard"
  echo "    su - $HERMES_SYSTEM_USER -c 'hermes update'"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  is_dry || require_root
  require_supported_os

  echo -e "${C_GREEN}"
  echo "============================================================"
  echo "  Auto Instalador NATIVO (sem Docker)"
  echo "  Hermes Agent + Caddy (HTTPS) + plugins"
  echo "============================================================"
  echo -e "${C_RESET}"
  is_dry && warn "MODO SIMULACAO (DRY_RUN=1): nada sera alterado no sistema."

  local __v
  for __v in ACME_EMAIL HERMES_DOMAIN HERMES_USER HERMES_SYSTEM_USER; do
    printf -v "$__v" '%s' "$(echo "${!__v}" | tr -d '[:space:]')"
  done

  SERVER_IP="$(detect_public_ip)"
  [ -n "$SERVER_IP" ] || die "Nao foi possivel detectar o IP do servidor."

  echo "  Antes de continuar, crie um registro DNS tipo A apontando para $SERVER_IP."
  echo "  O subdominio e obrigatorio: o painel so e publicado com HTTPS."
  echo

  ask HERMES_DOMAIN "Subdominio do Hermes (ex.: hermes.seudominio.com.br)" "$HERMES_DOMAIN"
  HERMES_DOMAIN="$(echo "$HERMES_DOMAIN" | tr -d '[:space:]' | tr 'A-Z' 'a-z')"
  validate_domain "Subdominio do Hermes" "$HERMES_DOMAIN"

  # O e-mail do Let's Encrypt e opcional e nao e perguntado. Para informar um: ACME_EMAIL=voce@dominio.com
  if [ -n "$ACME_EMAIL" ]; then
    ACME_EMAIL="$(clean_input "$ACME_EMAIL")"
    [[ "$ACME_EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || die "ACME_EMAIL invalido: '$ACME_EMAIL'"
  fi

  if [ "$ASSUME_YES" != "1" ] && [ "$INSTALL_PLUGINS_SET" != "1" ]; then
    if confirm "Instalar os plugins do Hermes (login por assinatura e app de celular)?" s; then
      INSTALL_PLUGINS=1; else INSTALL_PLUGINS=0; fi
  fi
  if [ "$ASSUME_YES" != "1" ] && [ "$HERMES_SUDO_SET" != "1" ]; then
    echo
    echo "  O agente roda com um usuario proprio ('$HERMES_SYSTEM_USER'), sem poderes de administrador."
    echo "  Com sudo ele pode instalar programas e administrar o servidor inteiro,"
    echo "  mas um comando errado dele tambem pode afetar o servidor inteiro."
    if confirm "Dar permissao de administrador (sudo) ao agente?" n; then HERMES_SUDO=1; else HERMES_SUDO=0; fi
  fi

  [[ "$HERMES_SYSTEM_USER" =~ ^[a-z_][a-z0-9_-]{0,30}$ ]] || die "HERMES_SYSTEM_USER invalido: $HERMES_SYSTEM_USER"
  [ "$HERMES_SYSTEM_USER" != "root" ] || die "O agente nao pode rodar como root. Use HERMES_SUDO=1 se quiser dar poderes de administrador."

  load_state
  if [ "$ASSUME_YES" = "1" ] && [ "$HERMES_SUDO_SET" != "1" ] && [ -f /etc/sudoers.d/hermes-agent ] && \
     ! grep -q "^HERMES_SUDO=" "$STATE_FILE" 2>/dev/null; then
    HERMES_SUDO=1
  fi
  prepare_secrets

  echo
  log "Resumo da configuracao:"
  echo "    IP do servidor ..... $SERVER_IP"
  echo "    Hermes ............. https://$HERMES_DOMAIN"
  echo "    E-mail SSL ......... ${ACME_EMAIL:-(sem e-mail)}"
  echo "    Usuario Linux ...... $HERMES_SYSTEM_USER"
  echo "    Sudo para o agente . $([ "$HERMES_SUDO" = "1" ] && echo "SIM" || echo "nao")"
  echo "    Plugins ............ $([ "$INSTALL_PLUGINS" = "1" ] && echo "$PLUGINS" || echo "nao instalar")"
  echo
  check_dns "$HERMES_DOMAIN"
  echo
  confirm "Continuar com a instalacao?" s || die "Instalacao cancelada pelo usuario"

  step_preflight
  step_packages
  step_user
  save_state
  step_install_hermes
  step_configure
  step_services
  step_wait_and_secure
  step_firewall
  step_caddy
  step_sudo
  step_install_plugins
  step_verify_public

  echo
  echo -e "${C_GREEN}============================================================${C_RESET}"
  ok "Instalacao concluida!"
  print_access
}

main "$@"

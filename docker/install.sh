#!/usr/bin/env bash
#
# Auto instalador: Docker Swarm + Traefik + Portainer + Hermes Agent (com plugins)
#
# Uso interativo:
#   sudo bash install.sh
#
# Uso nao-interativo (tudo por variaveis de ambiente):
#   sudo ASSUME_YES=1 \
#        ACME_EMAIL=seu@email.com \
#        HERMES_DOMAIN=hermes.seudominio.com.br \
#        PORTAINER_DOMAIN=portainer.seudominio.com.br \
#        bash install.sh
#
# O subdominio do PORTAINER e opcional: vazio = acesso por https://IP:9443.
# O subdominio do HERMES e OBRIGATORIO: o painel so e publicado com HTTPS.
#
# Outras variaveis: veja a secao "Defaults" abaixo ou o README.md.
# Simulacao sem alterar o sistema:  DRY_RUN=1 bash install.sh

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults (podem ser sobrescritos por variaveis de ambiente)
# ---------------------------------------------------------------------------
HOSTNAME_NODE="${HOSTNAME_NODE-manager1}"          # vazio = nao altera o hostname
DOCKER_VERSION="${DOCKER_VERSION:-28.5.2}"
ADVERTISE_ADDR="${ADVERTISE_ADDR:-auto}"
NETWORK_NAME="${NETWORK_NAME:-network_public}"
ASSUME_YES="${ASSUME_YES:-0}"
DRY_RUN="${DRY_RUN:-0}"

ACME_EMAIL="${ACME_EMAIL:-}"

PORTAINER_DOMAIN="${PORTAINER_DOMAIN:-}"           # vazio = acesso por IP:porta
PORTAINER_PORT="${PORTAINER_PORT:-9443}"
PORTAINER_USER="admin"                             # fixo no Portainer (--admin-password-file)
PORTAINER_PASSWORD="${PORTAINER_PASSWORD:-}"       # vazio = gerada automaticamente

INSTALL_HERMES_SET=0;  [ -n "${INSTALL_HERMES+x}" ]  && INSTALL_HERMES_SET=1
INSTALL_PLUGINS_SET=0; [ -n "${INSTALL_PLUGINS+x}" ] && INSTALL_PLUGINS_SET=1
INSTALL_HERMES="${INSTALL_HERMES:-1}"
HERMES_DOMAIN="${HERMES_DOMAIN:-}"                 # OBRIGATORIO quando INSTALL_HERMES=1
HERMES_USER="${HERMES_USER:-admin}"
HERMES_PASSWORD="${HERMES_PASSWORD:-}"             # vazio = gerada automaticamente
HERMES_IMAGE="${HERMES_IMAGE:-nousresearch/hermes-agent:latest}"
HERMES_DATA_DIR="${HERMES_DATA_DIR:-/opt/hermes/data}"

INSTALL_PLUGINS="${INSTALL_PLUGINS:-1}"
PLUGINS_REPO="${PLUGINS_REPO:-AstraOnlineWeb/hermes-plugins}"
PLUGINS="${PLUGINS:-codex-oauth hermes-pwa}"

HELPER_IMAGE="${HELPER_IMAGE:-traefik:v3.7}"         # usada so para checar o Portainer
CURL_IMAGE="${CURL_IMAGE:-curlimages/curl:8.11.1}"   # usada para falar com a API do Portainer
HERMES_VIA_PORTAINER="${HERMES_VIA_PORTAINER:-1}"    # 1 = stack do Hermes criada pela API do Portainer
STATE_DIR="${STATE_DIR:-/opt/autoinstall}"
STATE_FILE="$STATE_DIR/credenciais.env"
ACCESS_FILE="${ACCESS_FILE:-/root/acessos.txt}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKDIR="${WORKDIR:-$SCRIPT_DIR}"

# preenchidas em tempo de execucao
SERVER_IP=""
HERMES_AUTH_SECRET=""
HERMES_API_KEY=""
PORTAINER_PASSWORD_OK="nao verificado"
PORTAINER_JWT=""
HERMES_STACK_MODE=""
PLUGINS_OK=""

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

# run <comando...>: executa, ou apenas mostra quando DRY_RUN=1
run() {
  if is_dry; then echo "      [dry-run] $*"; else "$@"; fi
}

ask() {
  # ask <variavel> <pergunta> [default]        -> resposta obrigatoria
  local __var="$1" __prompt="$2" __default="${3:-}" __input=""
  local __current="${!__var:-}"
  [ -n "$__current" ] && __default="$__current"
  if [ "$ASSUME_YES" = "1" ]; then
    [ -z "$__default" ] && die "Modo nao-interativo: defina a variavel $__var"
    printf -v "$__var" '%s' "$__default"
    return
  fi
  if [ -n "$__default" ]; then
    read -r -p "$(echo -e "${C_YELLOW}?${C_RESET} $__prompt [$__default]: ")" __input
    __input="${__input:-$__default}"
  else
    while [ -z "$__input" ]; do
      read -r -p "$(echo -e "${C_YELLOW}?${C_RESET} $__prompt: ")" __input
    done
  fi
  printf -v "$__var" '%s' "$__input"
}

ask_optional() {
  # ask_optional <variavel> <pergunta>         -> ENTER vazio e aceito
  local __var="$1" __prompt="$2" __input=""
  local __current="${!__var:-}"
  if [ "$ASSUME_YES" = "1" ]; then
    printf -v "$__var" '%s' "$__current"
    return
  fi
  if [ -n "$__current" ]; then
    read -r -p "$(echo -e "${C_YELLOW}?${C_RESET} $__prompt [$__current] (digite - para deixar vazio): ")" __input
    [ "$__input" = "-" ] && __input="" || __input="${__input:-$__current}"
  else
    read -r -p "$(echo -e "${C_YELLOW}?${C_RESET} $__prompt (ENTER para pular): ")" __input
  fi
  printf -v "$__var" '%s' "$__input"
}

confirm() {
  # confirm <pergunta> [default s|n]
  local __def="${2:-n}" __reply="" __hint="[s/N]"
  [ "$__def" = "s" ] && __hint="[S/n]"
  [ "$ASSUME_YES" = "1" ] && return 0
  read -r -p "$(echo -e "${C_YELLOW}?${C_RESET} $1 $__hint: ")" __reply
  __reply="${__reply:-$__def}"
  [[ "$__reply" =~ ^([sS]|[yY])$ ]]
}

require_root() {
  [ "$(id -u)" -eq 0 ] || die "Execute como root (use: sudo bash install.sh)"
}

require_supported_os() {
  command -v apt-get >/dev/null 2>&1 || die "Este instalador suporta apenas Debian/Ubuntu (apt-get nao encontrado)."
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
  # 20 caracteres alfanumericos (seguro para YAML, sed e JSON)
  local p=""
  while [ "${#p}" -lt 20 ]; do
    p="$p$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9')"
  done
  echo "${p:0:20}"
}

gen_hex() { openssl rand -hex 32; }

validate_secret() {
  # validate_secret <nome> <valor> <tamanho minimo>
  local name="$1" value="$2" min="$3"
  [ "${#value}" -ge "$min" ] || die "$name precisa ter pelo menos $min caracteres."
  [[ "$value" =~ ^[A-Za-z0-9@%+=_.-]+$ ]] || \
    die "$name contem caracteres nao permitidos. Use apenas letras, numeros e @ % + = _ . -"
}

validate_domain() {
  local name="$1" value="$2"
  [ -z "$value" ] && return 0
  [[ "$value" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]] || \
    die "$name invalido: '$value' (informe apenas o dominio, sem http:// e sem barra)"
}

validate_port() {
  local name="$1" value="$2"
  [[ "$value" =~ ^[0-9]+$ ]] && [ "$value" -ge 1 ] && [ "$value" -le 65535 ] || die "$name invalida: $value"
}

check_dns() {
  # Avisa se o dominio nao aponta para este servidor (o certificado nao sera emitido)
  local domain="$1" resolved=""
  [ -z "$domain" ] && return 0
  resolved="$( (getent ahostsv4 "$domain" 2>/dev/null || true) | awk '{print $1}' | sort -u | tr '\n' ' ')"
  if [ -z "$resolved" ]; then
    warn "DNS: '$domain' ainda nao resolve. Crie um registro A apontando para $SERVER_IP."
  elif ! echo " $resolved" | grep -q " $SERVER_IP "; then
    warn "DNS: '$domain' aponta para [ $resolved] e nao para $SERVER_IP. O certificado SSL nao sera emitido ate corrigir."
  else
    ok "DNS: '$domain' aponta para $SERVER_IP"
  fi
}

port_in_use() {
  local port="$1"
  ss -ltnH 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}\$"
}

# ---------------------------------------------------------------------------
# Estado (credenciais geradas sao reutilizadas se o instalador rodar de novo)
# ---------------------------------------------------------------------------
load_state() {
  [ -f "$STATE_FILE" ] || return 0
  local k v
  while IFS='=' read -r k v; do
    case "$k" in
      PORTAINER_PASSWORD) [ -z "$PORTAINER_PASSWORD" ] && PORTAINER_PASSWORD="$v" ;;
      HERMES_PASSWORD)    [ -z "$HERMES_PASSWORD" ]    && HERMES_PASSWORD="$v" ;;
      HERMES_AUTH_SECRET) HERMES_AUTH_SECRET="$v" ;;
      HERMES_API_KEY)     HERMES_API_KEY="$v" ;;
    esac
  done < "$STATE_FILE"
  ok "Credenciais de uma instalacao anterior reaproveitadas ($STATE_FILE)"
}

save_state() {
  is_dry && return 0
  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR"
  umask 077
  {
    echo "PORTAINER_PASSWORD=$PORTAINER_PASSWORD"
    echo "HERMES_PASSWORD=$HERMES_PASSWORD"
    echo "HERMES_AUTH_SECRET=$HERMES_AUTH_SECRET"
    echo "HERMES_API_KEY=$HERMES_API_KEY"
  } > "$STATE_FILE"
  chmod 600 "$STATE_FILE"
}

prepare_secrets() {
  [ -n "$PORTAINER_PASSWORD" ] || PORTAINER_PASSWORD="$(gen_password)"
  [ -n "$HERMES_PASSWORD" ]    || HERMES_PASSWORD="$(gen_password)"
  [ -n "$HERMES_AUTH_SECRET" ] || HERMES_AUTH_SECRET="$(gen_hex)"
  [ -n "$HERMES_API_KEY" ]     || HERMES_API_KEY="$(gen_hex)"
  validate_secret "PORTAINER_PASSWORD" "$PORTAINER_PASSWORD" 12
  validate_secret "HERMES_PASSWORD" "$HERMES_PASSWORD" 8
  validate_secret "HERMES_USER" "$HERMES_USER" 3
}

# ---------------------------------------------------------------------------
# Renderizacao de modelos
# ---------------------------------------------------------------------------
GENERATED_FILE=""

render() {
  # render <modelo> <saida> CHAVE=valor [CHAVE=valor ...]
  local tpl="$SCRIPT_DIR/$1" out="$WORKDIR/$2"; shift 2
  [ -f "$tpl" ] || die "Modelo nao encontrado: $tpl"
  local content pair key val
  content="$(tr -d '\r' < "$tpl")"
  # bash >= 5.2: impede que '&' no valor seja tratado como "texto casado"
  shopt -u patsub_replacement 2>/dev/null || true
  for pair in "$@"; do
    key="${pair%%=*}"; val="${pair#*=}"
    content="${content//__${key}__/$val}"
  done
  if echo "$content" | grep -qE '__[A-Z_]+__'; then
    die "Placeholders nao preenchidos em $1: $(echo "$content" | grep -oE '__[A-Z_]+__' | sort -u | tr '\n' ' ')"
  fi
  umask 077
  printf '%s\n' "$content" > "$out"
  chmod 600 "$out"
  GENERATED_FILE="$out"
}

# ---------------------------------------------------------------------------
# Etapas de sistema
# ---------------------------------------------------------------------------
step_packages() {
  log "Atualizando pacotes e instalando dependencias"
  export DEBIAN_FRONTEND=noninteractive
  run apt-get update -y
  run apt-get install -y apparmor-utils curl ca-certificates openssl iproute2 jq
  ok "Pacotes instalados"
}

step_hostname() {
  if [ -z "$HOSTNAME_NODE" ]; then
    ok "Hostname mantido ($(hostname))"
    return
  fi
  log "Configurando hostname para '$HOSTNAME_NODE'"
  run hostnamectl set-hostname "$HOSTNAME_NODE"
  if ! grep -qE "^127\.0\.0\.1[[:space:]]+$HOSTNAME_NODE\b" /etc/hosts; then
    if is_dry; then echo "      [dry-run] adicionaria '127.0.0.1 $HOSTNAME_NODE' em /etc/hosts"
    else echo "127.0.0.1 $HOSTNAME_NODE" >> /etc/hosts; ok "Entrada adicionada em /etc/hosts"; fi
  else
    ok "/etc/hosts ja contem $HOSTNAME_NODE"
  fi
}

step_docker() {
  if command -v docker >/dev/null 2>&1; then
    ok "Docker ja instalado ($(docker --version))"
    run systemctl enable --now docker >/dev/null 2>&1 || true
    return
  fi
  if is_dry; then echo "      [dry-run] instalaria o Docker $DOCKER_VERSION"; return; fi

  local script="/tmp/get-docker.sh"
  log "Baixando script oficial de instalacao do Docker"
  curl -fsSL https://get.docker.com -o "$script"

  if [ -n "$DOCKER_VERSION" ] && [ "$DOCKER_VERSION" != "latest" ]; then
    log "Instalando Docker (versao $DOCKER_VERSION)"
    if VERSION="$DOCKER_VERSION" sh "$script"; then
      ok "Docker $DOCKER_VERSION instalado"
    else
      warn "Versao '$DOCKER_VERSION' indisponivel no repositorio desta distro."
      if command -v apt-cache >/dev/null 2>&1; then
        warn "Versoes docker-ce disponiveis:"
        apt-cache madison docker-ce 2>/dev/null | awk '{print "      - "$3}' | head -n 10 || true
      fi
      log "Instalando a versao mais recente disponivel"
      sh "$script"
      ok "Docker instalado (versao mais recente disponivel)"
    fi
  else
    log "Instalando Docker (versao mais recente)"
    sh "$script"
    ok "Docker instalado (versao mais recente)"
  fi

  systemctl enable --now docker >/dev/null 2>&1 || true
}

step_swarm() {
  if is_dry && ! command -v docker >/dev/null 2>&1; then echo "      [dry-run] iniciaria o Swarm"; return; fi
  if docker info 2>/dev/null | grep -q "Swarm: active"; then
    ok "Swarm ja esta ativo"
  else
    local addr="$ADVERTISE_ADDR"
    [ "$addr" = "auto" ] && addr="$(detect_ip)"
    [ -z "$addr" ] && die "Nao foi possivel detectar o IP. Defina ADVERTISE_ADDR."
    log "Inicializando Docker Swarm (advertise-addr: $addr)"
    run docker swarm init --advertise-addr "$addr"
    ok "Swarm inicializado"
  fi
}

step_network() {
  if is_dry && ! command -v docker >/dev/null 2>&1; then echo "      [dry-run] criaria a rede $NETWORK_NAME"; return; fi
  if docker network inspect "$NETWORK_NAME" >/dev/null 2>&1; then
    ok "Rede '$NETWORK_NAME' ja existe"
  else
    log "Criando rede overlay '$NETWORK_NAME'"
    run docker network create --driver=overlay --attachable "$NETWORK_NAME"
    ok "Rede criada"
  fi
}

step_volumes() {
  log "Criando volumes externos necessarios"
  if is_dry && ! command -v docker >/dev/null 2>&1; then echo "      [dry-run] criaria os volumes"; return; fi
  local vols=("volume_swarm_shared" "volume_swarm_certificates" "portainer_data")
  local v
  for v in "${vols[@]}"; do
    if docker volume inspect "$v" >/dev/null 2>&1; then
      ok "Volume '$v' ja existe"
    else
      if is_dry; then echo "      [dry-run] docker volume create $v"; continue; fi
      docker volume create "$v" >/dev/null
      ok "Volume '$v' criado"
    fi
  done
}

step_firewall() {
  command -v ufw >/dev/null 2>&1 || return 0
  ufw status 2>/dev/null | grep -q "Status: active" || return 0
  log "Firewall UFW ativo: liberando as portas necessarias"
  run ufw allow 80/tcp  >/dev/null
  run ufw allow 443/tcp >/dev/null
  if [ -z "$PORTAINER_DOMAIN" ]; then run ufw allow "${PORTAINER_PORT}/tcp" >/dev/null; fi
  ok "Portas liberadas no UFW"
}

deploy_stack() {
  # deploy_stack <nome> <arquivo> [timeout em segundos]
  # Espera o servico convergir. Falha ou demora aqui vira aviso: quem decide se a
  # instalacao deu certo sao as verificacoes feitas depois (login, painel, API).
  local name="$1" file="$2" limit="${3:-600}" rc=0
  if is_dry; then
    echo "      [dry-run] docker stack deploy --detach=false --prune --resolve-image always -c $file $name"
    return 0
  fi
  timeout "$limit" docker stack deploy --detach=false --prune --resolve-image always -c "$file" "$name" || rc=$?
  if [ "$rc" -ne 0 ]; then
    warn "O deploy da stack '$name' nao convergiu dentro do esperado (codigo $rc). Continuando com as verificacoes."
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Traefik
# ---------------------------------------------------------------------------
step_deploy_traefik() {
  log "Gerando traefik.generated.yaml"
  render traefik.yaml traefik.generated.yaml \
    "ACME_EMAIL=${ACME_EMAIL:-sem-email}" "NETWORK_NAME=$NETWORK_NAME"
  if [ -z "$ACME_EMAIL" ]; then
    sed -i '/#ACME/d' "$GENERATED_FILE"
    warn "Sem e-mail ACME: Traefik instalado sem Let's Encrypt (nenhum subdominio foi informado)."
  else
    sed -i 's/[[:space:]]*#ACME$//' "$GENERATED_FILE"
  fi
  ok "Arquivo gerado: $GENERATED_FILE"
  log "Fazendo deploy da stack 'traefik'"
  deploy_stack traefik "$GENERATED_FILE" 300
  ok "Traefik implantado"
}

# ---------------------------------------------------------------------------
# Portainer
# ---------------------------------------------------------------------------
step_portainer_secret() {
  if is_dry; then echo "      [dry-run] criaria o secret portainer_admin_password"; return; fi
  if docker secret inspect portainer_admin_password >/dev/null 2>&1; then
    ok "Secret 'portainer_admin_password' ja existe (mantido)"
  else
    printf '%s' "$PORTAINER_PASSWORD" | docker secret create portainer_admin_password - >/dev/null
    ok "Secret 'portainer_admin_password' criado"
  fi
}

step_deploy_portainer() {
  step_portainer_secret
  if [ -n "$PORTAINER_DOMAIN" ]; then
    log "Gerando portainer.generated.yaml (dominio: $PORTAINER_DOMAIN)"
    render portainer.yaml portainer.generated.yaml \
      "PORTAINER_DOMAIN=$PORTAINER_DOMAIN" "NETWORK_NAME=$NETWORK_NAME"
  else
    log "Gerando portainer.generated.yaml (acesso por IP, porta $PORTAINER_PORT)"
    render portainer-ip.yaml portainer.generated.yaml \
      "PORTAINER_PORT=$PORTAINER_PORT" "NETWORK_NAME=$NETWORK_NAME"
  fi
  ok "Arquivo gerado: $GENERATED_FILE"
  log "Fazendo deploy da stack 'portainer'"
  deploy_stack portainer "$GENERATED_FILE" 420
  ok "Portainer implantado"
}

portainer_api() {
  # portainer_api <caminho> [json]  -> corpo da resposta (via rede interna do Swarm)
  local path="$1" data="${2:-}"
  local args=(-q -O - -T 8)
  if [ -n "$data" ]; then
    args+=(--header "Content-Type: application/json" --post-data "$data")
  fi
  # Porta 9000 (HTTP) so e alcancavel dentro da rede overlay; nao e publicada.
  docker run --rm --network "$NETWORK_NAME" --entrypoint wget "$HELPER_IMAGE" \
    "${args[@]}" "http://portainer_portainer:9000$path" 2>&1 || true
}

step_verify_portainer() {
  is_dry && { echo "      [dry-run] validaria o login do Portainer"; return; }
  log "Aguardando o Portainer ficar pronto e validando o login"
  local i out rejected=0 responded=0
  local payload="{\"username\":\"$PORTAINER_USER\",\"password\":\"$PORTAINER_PASSWORD\"}"
  for i in $(seq 1 60); do
    out="$(portainer_api /api/auth "$payload")"
    if echo "$out" | grep -q '"jwt"'; then
      PORTAINER_PASSWORD_OK="sim"
      PORTAINER_JWT="$(echo "$out" | grep -oE '"jwt":"[^"]+"' | head -n1 | cut -d'"' -f4)"
      ok "Login do Portainer validado (usuario '$PORTAINER_USER')"
      return
    fi
    if echo "$out" | grep -qE 'HTTP/[0-9.]+ (401|403|422)'; then
      responded=1
      rejected=$((rejected + 1))
      # 5 recusas seguidas: o Portainer esta no ar e a senha realmente nao confere
      [ "$rejected" -ge 5 ] && break
    else
      rejected=0
    fi
    sleep 3
  done
  if [ "$responded" = "1" ]; then
    PORTAINER_PASSWORD_OK="nao"
    warn "A senha gerada NAO foi aceita: ja existia um Portainer neste servidor (volume portainer_data)."
    warn "Use a senha antiga, ou apague o volume portainer_data e rode o instalador de novo."
  else
    PORTAINER_PASSWORD_OK="nao verificado"
    warn "Portainer nao respondeu em 3 minutos. Verifique: docker service logs portainer_portainer"
  fi
}

# ---------------------------------------------------------------------------
# Stacks pela API do Portainer
# ---------------------------------------------------------------------------
portainer_call() {
  # portainer_call <METODO> <caminho> [tempo maximo]   (corpo JSON opcional pela entrada padrao)
  # Imprime o corpo da resposta e, na ultima linha, o codigo HTTP.
  local method="$1" path="$2" limit="${3:-30}"
  local args=(-sS -X "$method" --max-time "$limit" -w '\n%{http_code}'
              -H "Authorization: Bearer $PORTAINER_JWT")
  if [ "$method" = "POST" ] || [ "$method" = "PUT" ]; then
    args+=(-H "Content-Type: application/json" --data-binary @-)
    docker run --rm -i --network "$NETWORK_NAME" "$CURL_IMAGE" \
      "${args[@]}" "http://portainer_portainer:9000$path" 2>&1 || true
  else
    docker run --rm --network "$NETWORK_NAME" "$CURL_IMAGE" \
      "${args[@]}" "http://portainer_portainer:9000$path" 2>&1 < /dev/null || true
  fi
}

remove_cli_stack() {
  # Remove uma stack criada por linha de comando, para recria-la pelo Portainer. Os dados ficam no disco.
  local name="$1" i
  docker stack rm "$name" >/dev/null 2>&1 || true
  for i in $(seq 1 60); do
    if [ -z "$(docker service ls -q --filter "label=com.docker.stack.namespace=$name" 2>/dev/null)" ] && \
       [ -z "$(docker ps -aq --filter "label=com.docker.stack.namespace=$name" 2>/dev/null)" ]; then
      return 0
    fi
    sleep 2
  done
  return 1
}

step_portainer_endpoint() {
  # Garante que o Portainer ja tenha o ambiente do Swarm cadastrado. Na primeira subida o
  # Portainer pode iniciar antes do agente e ficar sem ambiente (pediria o assistente inicial).
  is_dry && { echo "      [dry-run] garantiria o ambiente 'primary' no Portainer"; return; }
  [ "$PORTAINER_PASSWORD_OK" = "sim" ] && [ -n "$PORTAINER_JWT" ] || return 0
  local out code body i
  out="$(portainer_call GET /api/endpoints)"
  code="$(echo "$out" | tail -n1)"; body="$(echo "$out" | sed '$d')"
  [ "$code" = "200" ] || { warn "Nao foi possivel consultar os ambientes do Portainer (codigo $code)."; return 0; }
  if [ "$(echo "$body" | jq 'length' 2>/dev/null || echo 0)" -gt 0 ]; then
    ok "Ambiente do Portainer ja cadastrado"
    return 0
  fi
  log "Cadastrando o ambiente do Swarm no Portainer"
  for i in $(seq 1 20); do
    out="$(docker run --rm --network "$NETWORK_NAME" "$CURL_IMAGE" -sS --max-time 30 -w '\n%{http_code}' \
            -X POST -H "Authorization: Bearer $PORTAINER_JWT" \
            -F Name=primary -F EndpointCreationType=2 -F "URL=tcp://tasks.agent:9001" \
            -F TLS=true -F TLSSkipVerify=true -F TLSSkipClientVerify=true \
            "http://portainer_portainer:9000/api/endpoints" 2>&1 < /dev/null || true)"
    code="$(echo "$out" | tail -n1)"
    if [ "$code" = "200" ]; then
      ok "Ambiente 'primary' cadastrado no Portainer"
      return 0
    fi
    sleep 3
  done
  warn "Nao foi possivel cadastrar o ambiente no Portainer (codigo $code). Ele pedira o cadastro no primeiro acesso."
}

deploy_stack_portainer() {
  # deploy_stack_portainer <nome> <arquivo> [timeout]  -> 0 se a stack ficou sob controle do Portainer
  local name="$1" file="$2" limit="${3:-1500}"
  local out code body endpoint swarm stack_id

  [ -n "$PORTAINER_JWT" ] || { warn "Sem sessao na API do Portainer."; return 1; }

  out="$(portainer_call GET /api/endpoints)"
  code="$(echo "$out" | tail -n1)"; body="$(echo "$out" | sed '$d')"
  endpoint="$(echo "$body" | jq -r '.[0].Id // empty' 2>/dev/null || true)"
  [ "$code" = "200" ] && [ -n "$endpoint" ] || { warn "A API do Portainer nao informou o ambiente (codigo $code)."; return 1; }

  out="$(portainer_call GET "/api/endpoints/$endpoint/docker/swarm")"
  code="$(echo "$out" | tail -n1)"; body="$(echo "$out" | sed '$d')"
  swarm="$(echo "$body" | jq -r '.ID // empty' 2>/dev/null || true)"
  [ "$code" = "200" ] && [ -n "$swarm" ] || { warn "A API do Portainer nao informou o Swarm (codigo $code)."; return 1; }

  out="$(portainer_call GET /api/stacks)"
  code="$(echo "$out" | tail -n1)"; body="$(echo "$out" | sed '$d')"
  [ "$code" = "200" ] || [ "$code" = "204" ] || { warn "A API do Portainer nao listou as stacks (codigo $code)."; return 1; }
  stack_id="$(echo "$body" | jq -r --arg n "$name" '.[]? | select(.Name == $n) | .Id' 2>/dev/null | head -n1 || true)"

  if [ -n "$stack_id" ]; then
    log "Atualizando a stack '$name' pelo Portainer"
    out="$(jq -n --rawfile f "$file" '{stackFileContent: $f, env: [], prune: true, pullImage: true}' | \
           portainer_call PUT "/api/stacks/$stack_id?endpointId=$endpoint" "$limit")"
  else
    if docker stack ls --format '{{.Name}}' 2>/dev/null | grep -qx "$name"; then
      log "A stack '$name' foi criada fora do Portainer; recriando pelo Portainer (os dados sao mantidos)"
      remove_cli_stack "$name" || warn "A stack antiga demorou a ser removida."
    fi
    log "Criando a stack '$name' pelo Portainer"
    out="$(jq -n --rawfile f "$file" --arg n "$name" --arg s "$swarm" \
             '{name: $n, swarmID: $s, stackFileContent: $f, env: []}' | \
           portainer_call POST "/api/stacks/create/swarm/string?endpointId=$endpoint" "$limit")"
  fi
  code="$(echo "$out" | tail -n1)"
  if [ "$code" = "200" ]; then
    return 0
  fi
  warn "A API do Portainer recusou a stack '$name' (codigo $code): $(echo "$out" | sed '$d' | head -c 300)"
  return 1
}

# ---------------------------------------------------------------------------
# Hermes
# ---------------------------------------------------------------------------
hermes_container() {
  docker ps -q -f name=hermes_hermes -f status=running 2>/dev/null | head -n1
}

wait_hermes() {
  # Espera o painel (9119) e o API server (8642) responderem dentro do conteiner
  local timeout="${1:-420}" t0 c code
  t0="$(date +%s)"
  while [ $(( $(date +%s) - t0 )) -lt "$timeout" ]; do
    c="$(hermes_container)"
    if [ -n "$c" ]; then
      code="$(docker exec "$c" curl -s -o /dev/null -w '%{http_code}' --max-time 4 http://127.0.0.1:9119/login 2>/dev/null || true)"
      if [ "$code" = "200" ]; then
        code="$(docker exec "$c" curl -s -o /dev/null -w '%{http_code}' --max-time 4 http://127.0.0.1:8642/v1/health 2>/dev/null || true)"
        [ "$code" = "200" ] && return 0
      fi
    fi
    sleep 4
  done
  return 1
}

step_hermes_data() {
  log "Preparando diretorio de dados do Hermes ($HERMES_DATA_DIR)"
  run mkdir -p "$HERMES_DATA_DIR"
  if [ ! -f "$HERMES_DATA_DIR/config.yaml" ]; then
    local subnet=""
    if ! is_dry || command -v docker >/dev/null 2>&1; then
      subnet="$(docker network inspect "$NETWORK_NAME" -f '{{(index .IPAM.Config 0).Subnet}}' 2>/dev/null || true)"
    fi
    [ -z "$subnet" ] && subnet="10.0.0.0/8"
    if is_dry; then
      echo "      [dry-run] gravaria config.yaml com trusted_proxies=$subnet"
    else
      cat > "$HERMES_DATA_DIR/config.yaml" <<EOF
# Gerado pelo auto instalador. O Hermes mescla este arquivo com os valores padrao.
dashboard:
  public_url: "https://$HERMES_DOMAIN"
  trusted_proxies:
    - "$subnet"
EOF
    fi
    ok "config.yaml criado (proxy confiavel: $subnet)"
  fi
  run chown -R 10000:10000 "$HERMES_DATA_DIR"
}

step_deploy_hermes() {
  step_hermes_data
  local common=(
    "HERMES_USER=$HERMES_USER" "HERMES_PASSWORD=$HERMES_PASSWORD"
    "HERMES_AUTH_SECRET=$HERMES_AUTH_SECRET" "HERMES_API_KEY=$HERMES_API_KEY"
    "HERMES_DATA_DIR=$HERMES_DATA_DIR" "HERMES_IMAGE=$HERMES_IMAGE" "NETWORK_NAME=$NETWORK_NAME"
  )
  log "Gerando hermes.generated.yaml (dominio: $HERMES_DOMAIN)"
  render hermes.yaml hermes.generated.yaml "HERMES_DOMAIN=$HERMES_DOMAIN" "${common[@]}"
  ok "Arquivo gerado: $GENERATED_FILE"
  log "Fazendo deploy da stack 'hermes' (a imagem tem ~3 GB; o primeiro download pode levar alguns minutos)"
  if is_dry; then
    [ "$HERMES_VIA_PORTAINER" = "1" ] && echo "      [dry-run] criaria a stack 'hermes' pela API do Portainer"
    deploy_stack hermes "$GENERATED_FILE" 1500
    return 0
  fi
  HERMES_STACK_MODE="cli"
  if [ "$HERMES_VIA_PORTAINER" = "1" ] && [ "$PORTAINER_PASSWORD_OK" = "sim" ]; then
    if deploy_stack_portainer hermes "$GENERATED_FILE" 1500; then
      HERMES_STACK_MODE="portainer"
      ok "Stack 'hermes' sob controle do Portainer"
    else
      warn "Usando a linha de comando para subir o Hermes. No Portainer a stack aparece como 'Limited'."
    fi
  elif [ "$HERMES_VIA_PORTAINER" = "1" ]; then
    warn "Sem login valido no Portainer: o Hermes sera implantado por linha de comando (stack 'Limited' no Portainer)."
  fi
  if [ "$HERMES_STACK_MODE" = "cli" ]; then
    deploy_stack hermes "$GENERATED_FILE" 1500
  fi
  log "Aguardando o Hermes iniciar"
  if wait_hermes 900; then
    ok "Hermes no ar (painel e API respondendo)"
  else
    die "O Hermes nao iniciou em 15 minutos. Verifique: docker service ps hermes_hermes --no-trunc ; docker service logs hermes_hermes"
  fi
}

step_install_plugins() {
  local c p out failed=0
  [ "$INSTALL_PLUGINS" = "1" ] || { ok "Instalacao de plugins desativada (INSTALL_PLUGINS=0)"; return; }
  if is_dry; then
    for p in $PLUGINS; do echo "      [dry-run] hermes plugins install $PLUGINS_REPO/$p --enable"; done
    return
  fi
  c="$(hermes_container)"
  [ -n "$c" ] || die "Conteiner do Hermes nao encontrado para instalar os plugins."
  log "Instalando plugins do repositorio $PLUGINS_REPO"
  for p in $PLUGINS; do
    if [ -d "$HERMES_DATA_DIR/plugins/$p" ]; then
      out="$(docker exec -u 10000 -e HOME=/opt/data -e HERMES_HOME=/opt/data "$c" \
              /opt/hermes/.venv/bin/hermes plugins update "$p" 2>&1 || true)"
      docker exec -u 10000 -e HOME=/opt/data -e HERMES_HOME=/opt/data "$c" \
        /opt/hermes/.venv/bin/hermes plugins enable "$p" >/dev/null 2>&1 || true
      ok "Plugin '$p' ja instalado (atualizado)"
      continue
    fi
    out="$(docker exec -u 10000 -e HOME=/opt/data -e HERMES_HOME=/opt/data "$c" \
            /opt/hermes/.venv/bin/hermes plugins install "$PLUGINS_REPO/$p" --enable 2>&1 || true)"
    if [ -f "$HERMES_DATA_DIR/plugins/$p/plugin.yaml" ]; then
      ok "Plugin '$p' instalado e habilitado"
    else
      failed=1
      err "Falha ao instalar o plugin '$p':"
      echo "$out" | grep -viE 'warning' | tail -n 5 | sed 's/^/      /'
    fi
  done

  log "Reiniciando o Hermes para carregar os plugins"
  docker service update --force --detach=false hermes_hermes >/dev/null 2>&1 || \
    warn "O reinicio do servico retornou erro; conferindo se o Hermes voltou mesmo assim."
  if wait_hermes 600; then
    ok "Hermes reiniciado"
  else
    warn "O Hermes demorou a voltar apos o reinicio. Verifique: docker service logs hermes_hermes"
  fi

  # Confere as abas dos plugins pelo proprio painel
  c="$(hermes_container)"
  local tabs=""
  if [ -n "$c" ]; then
    tabs="$(docker exec "$c" sh -c "
      curl -s -c /tmp/.ck -o /dev/null -X POST http://127.0.0.1:9119/auth/password-login \
        -H 'Content-Type: application/json' \
        -d '{\"provider\":\"basic\",\"username\":\"$HERMES_USER\",\"password\":\"$HERMES_PASSWORD\"}';
      curl -s -b /tmp/.ck http://127.0.0.1:9119/api/dashboard/plugins; rm -f /tmp/.ck" 2>/dev/null || true)"
  fi
  PLUGINS_OK=""
  for p in $PLUGINS; do
    if echo "$tabs" | grep -q "\"name\": *\"$p\""; then
      PLUGINS_OK="$PLUGINS_OK $p"
      ok "Aba do plugin '$p' ativa no painel"
    else
      warn "Aba do plugin '$p' nao apareceu no painel"
      failed=1
    fi
  done
  [ "$failed" = "0" ] || warn "Houve falha em algum plugin. Tente depois: docker exec <conteiner> hermes plugins install $PLUGINS_REPO/<plugin> --enable"
}

# ---------------------------------------------------------------------------
# Resumo final
# ---------------------------------------------------------------------------
portainer_url() {
  if [ -n "$PORTAINER_DOMAIN" ]; then echo "https://$PORTAINER_DOMAIN"; else echo "https://$SERVER_IP:$PORTAINER_PORT"; fi
}
hermes_url() { echo "https://$HERMES_DOMAIN"; }

print_access() {
  local line="============================================================"
  local out=""
  out+="$line\n"
  out+="  DADOS DE ACESSO  ($(date '+%d/%m/%Y %H:%M'))\n"
  out+="$line\n\n"
  out+="  PORTAINER\n"
  out+="    Endereco : $(portainer_url)\n"
  out+="    Usuario  : $PORTAINER_USER\n"
  out+="    Senha    : $PORTAINER_PASSWORD\n"
  if [ "$PORTAINER_PASSWORD_OK" = "nao" ]; then
    out+="    ATENCAO  : ja existia um Portainer neste servidor; a senha acima NAO foi aplicada.\n"
  fi
  if [ -z "$PORTAINER_DOMAIN" ]; then
    out+="    Obs.     : digite o endereco completo, comecando por https://\n"
    out+="               Certificado autoassinado: no aviso do navegador, clique em\n"
    out+="               \"Avancado\" e depois em \"Continuar\".\n"
  fi
  if [ "$INSTALL_HERMES" = "1" ]; then
    out+="\n  HERMES AGENT (painel)\n"
    out+="    Endereco : $(hermes_url)\n"
    out+="    Usuario  : $HERMES_USER\n"
    out+="    Senha    : $HERMES_PASSWORD\n"
    if [ "$INSTALL_PLUGINS" = "1" ]; then
      out+="\n  HERMES - APP DE CELULAR (PWA)\n"
      out+="    Endereco : $(hermes_url)/pwa\n"
      out+="    Login    : o mesmo do painel\n"
      out+="\n  HERMES - CONECTAR ASSINATURA (ChatGPT/Codex ou Claude)\n"
      out+="    Endereco : $(hermes_url)/codex\n"
      out+="    Passo    : clique em \"Conectar\", abra o link e informe o codigo exibido.\n"
    fi
    out+="\n  HERMES - API (compativel com OpenAI)\n"
    out+="    Endereco : https://$HERMES_DOMAIN/v1\n"
    out+="    Chave    : $HERMES_API_KEY\n"
    out+="    Modelo   : hermes-agent\n"
    out+="\n  Dados do Hermes no servidor: $HERMES_DATA_DIR\n"
    if [ "$HERMES_STACK_MODE" = "portainer" ]; then
      out+="  Stack do Hermes: gerenciada pelo Portainer (menu Stacks > hermes)\n"
    fi
  fi
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

  if [ -n "$PORTAINER_DOMAIN$HERMES_DOMAIN" ]; then
    echo
    warn "Os enderecos com subdominio levam 1 a 2 minutos para receber o certificado SSL."
  fi
  if [ "$INSTALL_HERMES" = "1" ]; then
    echo
    echo "  Proximo passo: abra o painel do Hermes e conecte um provedor de IA"
    echo "  (aba \"Codex / Claude\" para assinatura, ou \"Keys\" para chave de API)."
  fi
  echo
  echo "  Comandos uteis:"
  echo "    docker service ls"
  echo "    docker service logs -f hermes_hermes"
  echo "    docker service logs -f portainer_portainer"
  echo "    docker service logs -f traefik_traefik"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  is_dry || require_root
  require_supported_os

  echo -e "${C_GREEN}"
  echo "============================================================"
  echo "  Auto Instalador"
  echo "  Docker Swarm + Traefik + Portainer + Hermes Agent"
  echo "============================================================"
  echo -e "${C_RESET}"
  is_dry && warn "MODO SIMULACAO (DRY_RUN=1): nada sera alterado no sistema."

  # remove espacos acidentais das entradas
  local __v
  for __v in ACME_EMAIL PORTAINER_DOMAIN HERMES_DOMAIN PORTAINER_PORT HERMES_USER; do
    printf -v "$__v" '%s' "$(echo "${!__v}" | tr -d '[:space:]')"
  done

  SERVER_IP="$(detect_public_ip)"
  [ -n "$SERVER_IP" ] || die "Nao foi possivel detectar o IP do servidor."

  echo "  Antes de continuar, crie os registros DNS tipo A apontando para $SERVER_IP:"
  echo "    - Hermes ...... subdominio OBRIGATORIO (o painel so e publicado com HTTPS)"
  echo "    - Portainer ... subdominio opcional (sem ele, acesso por https://$SERVER_IP:$PORTAINER_PORT)"
  echo

  ask_optional PORTAINER_DOMAIN "Subdominio do Portainer (ex.: portainer.seudominio.com.br)"
  PORTAINER_DOMAIN="$(echo "$PORTAINER_DOMAIN" | tr -d '[:space:]' | tr 'A-Z' 'a-z')"
  validate_domain "Subdominio do Portainer" "$PORTAINER_DOMAIN"

  if [ "$ASSUME_YES" != "1" ] && [ "$INSTALL_HERMES_SET" != "1" ]; then
    if confirm "Instalar o Hermes Agent?" s; then INSTALL_HERMES=1; else INSTALL_HERMES=0; fi
  fi
  if [ "$INSTALL_HERMES" = "1" ]; then
    ask HERMES_DOMAIN "Subdominio do Hermes, obrigatorio (ex.: hermes.seudominio.com.br)" "$HERMES_DOMAIN"
    HERMES_DOMAIN="$(echo "$HERMES_DOMAIN" | tr -d '[:space:]' | tr 'A-Z' 'a-z')"
    [ -n "$HERMES_DOMAIN" ] || die "O subdominio do Hermes e obrigatorio (defina HERMES_DOMAIN)."
    validate_domain "Subdominio do Hermes" "$HERMES_DOMAIN"
    if [ "$HERMES_DOMAIN" = "$PORTAINER_DOMAIN" ]; then
      die "Portainer e Hermes precisam de subdominios diferentes."
    fi
    if [ "$ASSUME_YES" != "1" ] && [ "$INSTALL_PLUGINS_SET" != "1" ]; then
      if confirm "Instalar os plugins do Hermes (login por assinatura e app de celular)?" s; then
        INSTALL_PLUGINS=1; else INSTALL_PLUGINS=0; fi
    fi
  else
    HERMES_DOMAIN=""; INSTALL_PLUGINS=0
  fi

  if [ -n "$PORTAINER_DOMAIN$HERMES_DOMAIN" ]; then
    ask ACME_EMAIL "E-mail para o certificado SSL (Let's Encrypt)" "$ACME_EMAIL"
    ACME_EMAIL="$(echo "$ACME_EMAIL" | tr -d '[:space:]')"
    [[ "$ACME_EMAIL" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || die "E-mail invalido: $ACME_EMAIL"
  fi

  validate_port "Porta do Portainer" "$PORTAINER_PORT"

  load_state
  prepare_secrets

  echo
  log "Resumo da configuracao:"
  echo "    IP do servidor ..... $SERVER_IP"
  echo "    Hostname ........... ${HOSTNAME_NODE:-(nao alterar)}"
  echo "    Docker ............. $DOCKER_VERSION"
  echo "    Rede ............... $NETWORK_NAME"
  echo "    E-mail SSL ......... ${ACME_EMAIL:-(nao usado)}"
  echo "    Portainer .......... $(portainer_url)"
  if [ "$INSTALL_HERMES" = "1" ]; then
    echo "    Hermes ............. $(hermes_url)"
    echo "    Plugins ............ $([ "$INSTALL_PLUGINS" = "1" ] && echo "$PLUGINS" || echo "nao instalar")"
  else
    echo "    Hermes ............. nao instalar"
  fi
  echo
  check_dns "$PORTAINER_DOMAIN"
  check_dns "$HERMES_DOMAIN"
  if [ -z "$PORTAINER_DOMAIN" ] && port_in_use "$PORTAINER_PORT" && \
     ! docker service inspect portainer_portainer >/dev/null 2>&1; then
    warn "A porta $PORTAINER_PORT ja esta em uso neste servidor (defina PORTAINER_PORT para trocar)."
  fi
  echo
  confirm "Continuar com a instalacao?" s || die "Instalacao cancelada pelo usuario"

  step_packages
  step_hostname
  step_docker
  step_swarm
  step_network
  step_volumes
  step_firewall
  save_state
  step_deploy_traefik
  step_deploy_portainer
  step_verify_portainer
  step_portainer_endpoint
  if [ "$INSTALL_HERMES" = "1" ]; then
    step_deploy_hermes
    step_install_plugins
  fi

  echo
  echo -e "${C_GREEN}============================================================${C_RESET}"
  ok "Instalacao concluida!"
  print_access
}

main "$@"

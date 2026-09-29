# Auto instalador nativo: Hermes Agent sem Docker

Instala o [Hermes Agent](https://github.com/NousResearch/hermes-agent) direto na VPS, como serviço do sistema:

- Hermes Agent, pelo instalador oficial, em um usuário Linux próprio (`hermes`)
- Dois serviços no systemd: `hermes-gateway` (canais, API, agendamentos) e `hermes-dashboard` (painel)
- Caddy como proxy, com certificado SSL automático (Let's Encrypt)
- Painel protegido por usuário e senha
- Plugins do Hermes: login por assinatura (ChatGPT/Codex e Claude) e app de celular (PWA)

No final, o instalador mostra todos os endereços, usuários e senhas.

## Requisitos

- VPS com Debian ou Ubuntu, acesso root e systemd.
- Mínimo de 2 vCPU, 4 GB de RAM e 8 GB de disco livres. O Hermes ocupa cerca de 3 GB.
- Portas 80 e 443 livres. Se a VPS já usa Traefik, Nginx ou Apache nessas portas, use o modo Docker
  ou libere as portas antes.
- Um subdomínio para o Hermes, com registro DNS tipo A apontando para o IP da VPS. **É obrigatório.**

## Uso

```bash
curl -fsSL https://raw.githubusercontent.com/AstraOnlineWeb/hermes-autoinstall/main/install.sh | sudo bash -s -- nativo
```

Ou, com o repositório já baixado: `sudo bash install.sh` dentro desta pasta.

O instalador pergunta:

| Pergunta | Obrigatório | Padrão |
|---|---|---|
| Subdomínio do Hermes | **sim** | não prossegue sem ele |
| E-mail para o certificado SSL | sim | |
| Instalar os plugins? | sim ou não | sim |
| Dar permissão de administrador (sudo) ao agente? | sim ou não | **não** |

### Sobre o sudo

O agente roda com o usuário `hermes`, que não é administrador. Ele lê e grava na própria pasta,
executa programas e acessa a internet, mas não altera o sistema.

Respondendo **sim**, o agente ganha `sudo` sem senha: pode instalar pacotes, mexer em serviços e
administrar o servidor inteiro. É o modo de maior liberdade, e também o de maior risco: um comando
errado do agente afeta o servidor todo. Use apenas em VPS dedicada ao agente.

Para mudar depois, rode o instalador de novo com `HERMES_SUDO=1` ou `HERMES_SUDO=0`.

## Modo não-interativo

```bash
sudo ASSUME_YES=1 \
     ACME_EMAIL=seu@email.com \
     HERMES_DOMAIN=hermes.seudominio.com.br \
     bash install.sh
```

## Variáveis

| Variável | Padrão | Descrição |
|---|---|---|
| `HERMES_DOMAIN` | obrigatório | subdomínio do Hermes |
| `ACME_EMAIL` | obrigatório | e-mail do Let's Encrypt |
| `HERMES_USER` | `admin` | usuário do painel |
| `HERMES_PASSWORD` | gerada | senha do painel, mínimo de 8 caracteres |
| `HERMES_SYSTEM_USER` | `hermes` | usuário Linux que roda o agente |
| `HERMES_SUDO` | `0` | `1` dá sudo sem senha ao agente |
| `INSTALL_PLUGINS` | `1` | `0` não instala plugins |
| `PLUGINS_REPO` | `AstraOnlineWeb/hermes-plugins` | repositório dos plugins |
| `PLUGINS` | `codex-oauth hermes-pwa` | plugins a instalar |
| `DASHBOARD_PORT` | `9119` | porta interna do painel (só em 127.0.0.1) |
| `API_PORT` | `8642` | porta interna da API (só em 127.0.0.1) |
| `ASSUME_YES` | `0` | `1` não faz perguntas |
| `DRY_RUN` | `0` | `1` simula e não altera o sistema |

Senhas aceitam letras, números e os símbolos `@ % + = _ . -`.

## Depois da instalação

| Arquivo | Conteúdo |
|---|---|
| `/root/acessos.txt` | endereços, usuários e senhas. Só o root lê |
| `/opt/autoinstall/credenciais-nativo.env` | segredos gerados, reaproveitados se o instalador rodar de novo |
| `/home/hermes/.hermes` | dados do Hermes: sessões, perfis, plugins, configuração |
| `/home/hermes/.hermes/.env` | chaves e o bloco de configuração gravado pelo instalador |
| `/etc/caddy/Caddyfile` | configuração do proxy HTTPS |
| `/etc/systemd/system/hermes-*.service` | serviços do Hermes |

O próximo passo é conectar um provedor de IA no painel do Hermes: aba **Codex / Claude**
para usar uma assinatura, ou **Keys** para uma chave de API.

## Comandos do dia a dia

```bash
systemctl status hermes-gateway hermes-dashboard caddy   # situação dos serviços
systemctl restart hermes-gateway hermes-dashboard        # reiniciar o Hermes
journalctl -u hermes-gateway -f                          # acompanhar os logs
su - hermes                                              # entrar como o usuário do agente
hermes                                                   # conversar com o agente no terminal
hermes update                                            # atualizar o Hermes
```

Depois de `hermes update`, reinicie os serviços.

## Rodar de novo

O instalador pode ser executado mais de uma vez. Ele mantém o Hermes instalado, os dados e as senhas,
e reaplica a configuração. Serve para trocar o subdomínio ou ligar e desligar o sudo do agente.

## Segurança

O painel do Hermes, quando escuta só em `127.0.0.1` e não conhece o endereço público, dispensa o login.
Colocar um proxy na frente dele nessa condição deixaria o painel aberto na internet.

Por isso o instalador grava o endereço público e o login na configuração, e **confere três coisas antes
de ligar o HTTPS**: o painel declara que exige login, a página não entrega token de sessão e as rotas
internas respondem 401 sem login. Se alguma falhar, o painel é parado e nada é publicado.

O painel e a API escutam apenas em `127.0.0.1`. Da internet, só o Caddy é alcançado, nas portas 80 e 443.

## Problemas comuns

**Certificado SSL não é emitido.** O subdomínio precisa apontar para o IP da VPS antes da instalação,
e as portas 80 e 443 precisam estar abertas no firewall do provedor. Veja `journalctl -u caddy`.

**Porta 80 ou 443 em uso.** Outro servidor web está rodando. O instalador informa qual é.
Pare esse serviço ou use o modo Docker.

**Hermes não inicia.** Veja `journalctl -u hermes-dashboard -u hermes-gateway -n 50`.

**O instalador oficial do Hermes falhou.** O log completo fica em `/var/log/hermes-autoinstall-oficial.log`.

**Aba do plugin não aparece.** Rode
`su - hermes -c 'hermes plugins install AstraOnlineWeb/hermes-plugins/<plugin> --enable'`
e depois `systemctl restart hermes-gateway hermes-dashboard`.

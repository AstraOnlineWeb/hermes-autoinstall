# Auto instalador: Docker Swarm + Traefik + Portainer + Hermes Agent

Instala, em uma VPS Debian ou Ubuntu limpa, tudo o que é preciso para rodar o
[Hermes Agent](https://github.com/NousResearch/hermes-agent) em produção:

- Docker e Docker Swarm
- Traefik, com certificado SSL automático (Let's Encrypt)
- Portainer, já com usuário e senha criados
- Hermes Agent, com painel protegido por senha
- Plugins do Hermes: login por assinatura (ChatGPT/Codex e Claude) e app de celular (PWA)

No final, o instalador mostra todos os endereços, usuários e senhas.

## Requisitos

- VPS com Debian ou Ubuntu, acesso root.
- Mínimo de 2 vCPU, 4 GB de RAM e 20 GB de disco. A imagem do Hermes ocupa cerca de 3 GB.
- Portas 80 e 443 livres.
- Um subdomínio para o Hermes, com registro DNS tipo A apontando para o IP da VPS. Para o Portainer é opcional.

## Uso

```bash
curl -fsSL https://raw.githubusercontent.com/AstraOnlineWeb/hermes-autoinstall/main/install.sh | sudo bash -s -- docker
```

Ou, com o repositório já baixado: `sudo bash install.sh` dentro desta pasta.

O instalador pergunta:

| Pergunta | Obrigatório | Se deixar vazio |
|---|---|---|
| Subdomínio do Portainer | não | acesso por `https://IP:9443` |
| Instalar o Hermes Agent? | sim ou não | padrão: sim |
| Subdomínio do Hermes | **sim** | não prossegue |
| Instalar os plugins? | sim ou não | padrão: sim |

### Subdomínios

O **Hermes exige subdomínio**. O painel dá acesso a chaves, terminal e arquivos do agente, então só é
publicado com HTTPS e certificado válido. O app de celular também depende disso para ser instalado
e para usar o microfone.

O **Portainer aceita os dois modos**:

| | Com subdomínio | Sem subdomínio |
|---|---|---|
| Endereço | `https://portainer.seudominio.com.br` | `https://IP:9443` |
| Certificado | válido, do Let's Encrypt | autoassinado, o navegador mostra aviso |

## Modo não-interativo

```bash
sudo ASSUME_YES=1 \
     PORTAINER_DOMAIN=portainer.seudominio.com.br \
     HERMES_DOMAIN=hermes.seudominio.com.br \
     bash install.sh
```

Portainer por IP, só o Hermes com subdomínio:

```bash
sudo ASSUME_YES=1 HERMES_DOMAIN=hermes.seudominio.com.br bash install.sh
```

## Variáveis

| Variável | Padrão | Descrição |
|---|---|---|
| `PORTAINER_DOMAIN` | vazio | subdomínio do Portainer |
| `PORTAINER_PORT` | `9443` | porta do Portainer quando não há subdomínio |
| `PORTAINER_PASSWORD` | gerada | senha do usuário `admin`, mínimo de 12 caracteres |
| `INSTALL_HERMES` | `1` | `0` instala só Docker, Traefik e Portainer |
| `HERMES_DOMAIN` | obrigatório | subdomínio do Hermes |
| `HERMES_USER` | `admin` | usuário do painel |
| `HERMES_PASSWORD` | gerada | senha do painel |
| `HERMES_DATA_DIR` | `/opt/hermes/data` | pasta de dados no servidor |
| `HERMES_IMAGE` | `nousresearch/hermes-agent:latest` | imagem do Hermes |
| `HERMES_VIA_PORTAINER` | `1` | stack do Hermes criada pela API do Portainer. `0` usa linha de comando |
| `INSTALL_PLUGINS` | `1` | `0` não instala plugins |
| `PLUGINS_REPO` | `AstraOnlineWeb/hermes-plugins` | repositório dos plugins |
| `PLUGINS` | `codex-oauth hermes-pwa` | plugins a instalar |
| `ACME_EMAIL` | vazio | e-mail de contato no Let's Encrypt. Opcional, não é perguntado |
| `HOSTNAME_NODE` | `manager1` | hostname da VPS. Vazio não altera |
| `DOCKER_VERSION` | `28.5.2` | versão do Docker. `latest` usa a mais recente |
| `NETWORK_NAME` | `network_public` | rede overlay compartilhada |
| `ASSUME_YES` | `0` | `1` não faz perguntas |
| `DRY_RUN` | `0` | `1` simula, gera os arquivos e não altera o sistema |

Senhas aceitam letras, números e os símbolos `@ % + = _ . -`.

## Depois da instalação

| Arquivo | Conteúdo |
|---|---|
| `/root/acessos.txt` | endereços, usuários e senhas. Só o root lê |
| `/opt/autoinstall/credenciais.env` | segredos gerados, reaproveitados se o instalador rodar de novo |
| `*.generated.yaml` nesta pasta | stacks efetivamente implantadas |
| `/opt/hermes/data` | dados do Hermes: sessões, perfis, plugins, configuração |

O próximo passo é conectar um provedor de IA no painel do Hermes: aba **Codex / Claude**
para usar uma assinatura, ou **Keys** para uma chave de API.

## Stack do Hermes no Portainer

A stack do Hermes é criada pela API do Portainer. Ela aparece em **Stacks > hermes** com controle total:
dá para editar o compose, mudar variáveis e reimplantar pelo painel. Traefik e Portainer sobem por linha
de comando e aparecem como "Limited".

Quem instalou com uma versão anterior pode rodar o instalador de novo: a stack é recriada pelo Portainer
e os dados são mantidos.

O endereço do Portainer por IP precisa ser digitado começando por `https://`.

## Rodar de novo

O instalador pode ser executado mais de uma vez. Ele reaproveita Docker, Swarm, rede, volumes e
senhas já criados, e reimplanta as stacks. Serve para trocar de IP para subdomínio, por exemplo.

Se já existia um Portainer no servidor, a senha antiga dele continua valendo. O instalador avisa.

## Arquivos

| Arquivo | Função |
|---|---|
| `install.sh` | instalador |
| `traefik.yaml` | modelo da stack do Traefik |
| `portainer.yaml`, `portainer-ip.yaml` | Portainer com subdomínio e por IP |
| `hermes.yaml` | Hermes, sempre com subdomínio |

## Problemas comuns

**Certificado SSL não é emitido.** O subdomínio precisa apontar para o IP da VPS antes da instalação,
e as portas 80 e 443 precisam estar abertas no firewall do provedor.

**Hermes não inicia.** Veja `docker service ps hermes_hermes --no-trunc` e
`docker service logs hermes_hermes`. O motivo mais comum é falta de memória ou de disco.

**Aba do plugin não aparece.** Rode
`docker exec <contêiner> hermes plugins install AstraOnlineWeb/hermes-plugins/<plugin> --enable`
e depois `docker service update --force hermes_hermes`.

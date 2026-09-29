# Hermes Agent: auto instalador

Instala o [Hermes Agent](https://github.com/NousResearch/hermes-agent) em uma VPS limpa com **um comando**.
No final você recebe o endereço do painel com HTTPS, o usuário e a senha.

```bash
curl -fsSL https://raw.githubusercontent.com/AstraOnlineWeb/hermes-autoinstall/main/install.sh | sudo bash
```

O instalador pergunta o modo de instalação, o subdomínio e o e-mail para o certificado. O resto é automático.

## Os dois modos

| | **Docker** | **Nativo** (sem Docker) |
|---|---|---|
| O que instala | Docker Swarm, Traefik, Portainer e o Hermes em container | Hermes direto na VPS, com Caddy para o HTTPS |
| Indicado para | VPS que também roda outros sistemas | VPS dedicada ao agente |
| Liberdade do agente | fica dentro do container | acessa o sistema; pode instalar e usar programas da máquina |
| Painel de gestão | Portainer (stack do Hermes com controle total) | systemd (`systemctl`, `journalctl`) |
| Tempo de instalação | cerca de 3 minutos | cerca de 5 minutos |
| Detalhes | [docker/README.md](docker/README.md) | [nativo/README.md](nativo/README.md) |

Para escolher o modo direto no comando:

```bash
# Docker
curl -fsSL https://raw.githubusercontent.com/AstraOnlineWeb/hermes-autoinstall/main/install.sh | sudo bash -s -- docker

# Nativo
curl -fsSL https://raw.githubusercontent.com/AstraOnlineWeb/hermes-autoinstall/main/install.sh | sudo bash -s -- nativo
```

Os dois modos entregam:



- Painel do Hermes em `https://seu-subdominio`, protegido por usuário e senha.
- Certificado SSL automático (Let's Encrypt).
- API compatível com OpenAI em `https://seu-subdominio/v1`.
- Plugins da [AstraOnlineWeb/hermes-plugins](https://github.com/AstraOnlineWeb/hermes-plugins):
  login por assinatura (ChatGPT/Codex e Claude) e app de celular (PWA) em `/pwa`.
- Dados de acesso mostrados no final e salvos em `/root/acessos.txt`.

## Antes de começar

1. VPS com **Ubuntu ou Debian**, acesso root, portas 80 e 443 livres.
   Recomendado: 2 vCPU, 4 GB de RAM e 20 GB de disco.
2. Um **subdomínio para o Hermes** com registro DNS tipo **A** apontando para o IP da VPS.
   É obrigatório: o painel dá acesso a chaves, terminal e arquivos, por isso só é publicado com HTTPS.
3. No modo Docker, o subdomínio do Portainer é opcional. Sem ele, o acesso é por `https://IP:9443`.

## Sem nenhuma pergunta

```bash
curl -fsSL https://raw.githubusercontent.com/AstraOnlineWeb/hermes-autoinstall/main/install.sh | \
  sudo ASSUME_YES=1 \
       ACME_EMAIL=seu@email.com \
       HERMES_DOMAIN=hermes.seudominio.com.br \
       bash -s -- docker
```

Troque `docker` por `nativo` para instalar sem Docker. No modo Docker, acrescente `PORTAINER_DOMAIN=portainer.seudominio.com.br` se quiser o Portainer com subdomínio.
Sem ele, o Portainer fica em `https://IP:9443`. As demais variáveis estão em [docker/README.md](docker/README.md).

## Depois de instalar

1. Abra o endereço do painel e entre com o usuário e a senha mostrados no final.
2. Conecte um provedor de IA: aba **Codex / Claude** para usar sua assinatura, ou **Keys** para chave de API.
3. No celular, abra `https://seu-subdominio/pwa` e instale o app.

Perdeu os dados de acesso? Eles estão em `/root/acessos.txt`.

## Rodar de novo

Pode repetir o comando à vontade. O instalador reaproveita as senhas já criadas, mantém os dados do Hermes
e aplica apenas o que mudou (por exemplo, a troca de subdomínio).

Os arquivos do instalador ficam em `/opt/hermes-autoinstall`.

## Segurança

- O painel do Hermes só é publicado com HTTPS e login. No modo nativo, o instalador confere isso antes de
  ligar o HTTPS e interrompe a instalação se o painel estiver aberto.
- O painel e a API do Hermes não têm porta aberta para a internet. O acesso passa pelo proxy (Traefik ou Caddy),
  nas portas 80 e 443.
- As senhas são geradas na hora, em cada instalação. Não há senha padrão.
- Os arquivos com senhas são legíveis apenas pelo root.

## Licença

MIT. Veja [LICENSE](LICENSE).

## Suporte e serviços

Precisa de ajuda para melhorar, customizar ou implementar o projeto?

📱 **WhatsApp:** [+55 61 9 9687-8959](https://wa.me/5561996878959)

💼 Temos uma equipe especializada para:

- ✅ Customizações e melhorias
- ✅ Implementação e deploy completo
- ✅ Configuração de arquitetura SaaS
- ✅ Integração com outras APIs
- ✅ Desenvolvimento de features específicas
- ✅ Suporte técnico dedicado
- ✅ Consultoria em automação WhatsApp
- ✅ Treinamento e documentação

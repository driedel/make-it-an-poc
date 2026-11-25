# Make it Static — POC E2E

Esta POC testa, **100% em Docker**, a comunicação de ponta a ponta entre o plugin WordPress **Make it Static** (cliente HTTP) e o serviço **Make it Static** (API FastAPI + worker RQ + Redis + S3 via LocalStack + nginx de preview). O fluxo coberto: publicar um post no WordPress dispara um `POST /publish` **assinado** (HMAC-SHA256 do body raw + header `X-Timestamp`) para a API; um poller via WP-Cron consulta o status a cada 30s; o worker raspa o site pela rede interna com `wget`, otimiza os assets e sobe o site estático para o bucket S3, que o nginx de preview serve na porta 8301.

```
                 POST /publish (HMAC-SHA256 do body raw + X-Timestamp)
┌──────────────┐ ─────────────────────────────────▶ ┌────────────┐
│              │                                    │ API        │
│  WordPress   │ ◀───────────────────────────────── │ (FastAPI)  │
│  + plugin    │   GET /jobs/{id} — poller 30s      └─────┬──────┘
│  Make it     │        (via sidecar `cron`)              │ enqueue
│  Static      │                                          ▼
└──────┬───────┘                                    ┌────────────┐
       │                                            │   Redis    │
       │                                            └─────┬──────┘
       │                                                  │ dequeue
       │   scrape: wget http://wordpress                  ▼
       │   (rede interna)  ◀────────────────────── ┌────────────┐
       │                                           │ worker RQ  │
       │                                           │ scrape +   │
       │                                           │ otimização │
       │                                           └─────┬──────┘
       │                                                 │ upload otimizado
       │                                                 │ bucket my-static-site
       │                                                 │ prefixo wordpress/
       │                                                 ▼
       │                                           ┌────────────┐     ┌────────────┐
       │   http://localhost:8301                   │ LocalStack │ ──▶ │ nginx      │
       └──────────────────────────────────────────▶│ (S3)       │     │ preview    │
                                                   └────────────┘     └────────────┘

Sidecar `cron`: roda `wp cron event run --due-now` em loop a cada 30s. É ele quem
dispara o publish agendado (debounce de 15s) e o poller de status — containers sem
tráfego HTTP não disparam WP-Cron sozinhos.
```

## Pré-requisitos

- **Docker Desktop** instalado e rodando (com `docker compose` v2).
- **Clone irmão do plugin** no mesmo diretório pai desta POC: `../make-it-static-wp-plugin` (`/Users/mediaserver/projects/github/make-it-static-wp-plugin`) — o plugin entra no WordPress via bind mount.
- **Imagens do serviço no Docker Hub** (públicas, namespace `driedel`): a API e o worker usam `driedel/make-it-static-api` e `driedel/make-it-static-worker`, tag definida por `MIS_VERSION` no `.env` (default `0.2.2`; as tags **não** levam o prefixo `v`). O `make up` faz o pull automaticamente; `make pull` atualiza as imagens manualmente. O clone `../make-it-static` **não** é mais pré-requisito para rodar — segue útil para desenvolver o serviço (build local comentado no `docker-compose.yml`).
- **Portas 8300–8304 livres** no host (o `make up` valida e avisa qual está ocupada).
- **Stack dev do make-it-static parada**, para não conflitar portas nem a rede `make-it-static-network`.

## Quickstart

```bash
# 1. Crie o .env e gere o segredo HMAC
cp .env.example .env
openssl rand -hex 32        # copie o valor gerado para HMAC_SECRET no .env

# 2. Suba o stack (garante a rede, valida .env e portas, faz pull das imagens)
make up

# 3. Aguarde tudo ficar de pé (db healthy, wordpress running)
make ps

# 4. Popule o WordPress com conteúdo de teste (leva alguns minutos)
make seed

# 5. Abra o site no navegador
open http://localhost:8300
```

O `make seed` importa o **WordPress Theme Unit Test Data**, remove posts que contenham **Query Loop blocks** (`wp:query`) — a paginação `?query-N-page=M` deles é uma armadilha de crawl infinita para o `wget --level=0` do worker (o reject-regex do `scrape.sh` cobre `/page/N/`, mas não query vars, e o job estouraria o timeout de scrape de 300s) — e **apara o conteúdo para os 25 posts e 8 páginas mais recentes** (o test data completo gera ~500 requests de scrape, ~97% do orçamento de 300s; o corte deixa o scrape em ~40% e mantém ≥20 posts e ≥5 páginas). Em seguida baixa imagens destacadas, configura permalinks `/%postname%/` e `posts_per_page=25` (o scrape rejeita `/page/N/`), cria o menu primário com Home + páginas, ativa um tema twenty* (twentytwentyone), ativa o plugin Make it Static e grava as settings (`mis_settings`) apontando para a API interna — incluindo `extra_cdn=wpthemetestdata.files.wordpress.com`, o domínio das imagens externas do Theme Unit Test que o importer não baixa: com ele na lista, o worker baixa esses assets e o postprocess os relativiza. **O banco não é modificado**: o `post_content` importado mantém as URLs absolutas `http://localhost:8300/...` gravadas pelo importer — exatamente como um banco WordPress real (veja "URLs absolutas no conteúdo" abaixo).

## Credenciais de teste

| Serviço | Credencial | Onde |
|---|---|---|
| WordPress admin | usuário `admin` / senha `mis-poc-2026` (email `poc@example.com`) | http://localhost:8300/wp-admin/ |
| MariaDB | db `wordpress`, user `wordpress`, senha `wordpress`; root: `rootpassword` | host externo `localhost:8304` |
| LocalStack (S3) | aceita **qualquer** credencial (o compose usa `test`/`test`) | http://localhost:8303 |
| HMAC secret | gerado por você no `.env` com `openssl rand -hex 32` | **nunca commite o `.env`** — ele já está no `.gitignore` |

## URLs

| O quê | URL |
|---|---|
| Site WP / admin | http://localhost:8300 (admin em `/wp-admin`) |
| Preview do site estático | http://localhost:8301 |
| API | http://localhost:8302 (`/health` → `{"ok":true,"redis":true}`) |
| LocalStack S3 | http://localhost:8303 (no dia a dia: `make bucket-ls`) |
| MariaDB | `localhost:8304` |

## Como funciona

1. Ao criar/atualizar um **post publicado**, o plugin agenda o publish com **debounce de 15s** (evento WP-Cron `mis_run_publish`).
2. O evento dispara o `POST /publish` assinado para a API e grava uma row na tabela `wp_mis_jobs`.
3. O **poller** (`mis_poll_jobs`, a cada 30s) consulta o status até um estado terminal: `queued` → `started` → `finished` (ou `failed`/`expired`; o resultado de um job expira em ~1h no servidor).
4. O **sidecar `cron`** roda `wp cron event run --due-now` em loop a cada 30s — containers sem tráfego HTTP não disparam WP-Cron sozinhos, então é ele quem acorda tanto o publish agendado quanto o poller.
5. O **worker** consome o job da fila RQ, raspa o site em `http://wordpress` (rede interna `make-it-static-network`) com `wget`, otimiza (bundle de CSS/JS, compressão de imagens e HTML, conversão de fontes) e sobe tudo para o bucket `my-static-site` no LocalStack, sob o prefixo `wordpress/`.
6. O **nginx de preview** serve o bucket em http://localhost:8301.

Três decisões de configuração importantes:

- **`WP_HOME`/`WP_SITEURL` dinâmicos**: o `WORDPRESS_CONFIG_EXTRA` (serviço `wordpress`) define essas constantes a partir do `HTTP_HOST` da requisição. Sem isso, o HTML raspado pelo worker sairia com URLs `http://localhost:8300/...` — inalcançáveis de dentro da rede Docker — e o `wget` não baixaria os assets. Com o host dinâmico, o scrape em `http://wordpress` gera HTML com URLs `wordpress` (baixadas same-host e reescritas para relativas no post-process), enquanto o navegador em `localhost:8300` continua vendo URLs `localhost:8300`.
- **Auto-update do core desligado**: o mesmo `WORDPRESS_CONFIG_EXTRA` define `WP_AUTO_UPDATE_CORE` como `false`. Sem isso, o WP do volume auto-atualizou (6.9.4 → 7.1.5) entre publishes, mudando o HTML raspado sem nenhuma mudança de conteúdo.
- **Segredo HMAC fora do banco**: o seed grava a constante `MAKE_IT_STATIC_HMAC_SECRET` no `wp-config.php` com o valor do env `HMAC_SECRET` (`wp config set`). O segredo **nunca** é gravado na option `mis_settings` nem no banco — e por ser um define literal (não um `getenv()` via `WORDPRESS_CONFIG_EXTRA`), os alvos `make break-secret`/`make fix-secret` conseguem sobrescrevê-lo para o cenário de falha 1.

### URLs absolutas no conteúdo (sem maquiar o banco)

Bancos WordPress reais têm URLs absolutas do host público gravadas no `post_content` (o importer do Theme Unit Test grava `http://localhost:8300/wp-content/uploads/...`, pois o CLI não tem `HTTP_HOST`). A POC **não** reescreve essas URLs no banco — ela as trata pelo fluxo, como aconteceria em produção:

1. **Conteúdo realista, banco intacto**: o `post_content` mantém as URLs absolutas do host público. A prova: `SELECT COUNT(*) FROM wp_posts WHERE post_content LIKE '%localhost:8300%'` retorna > 0 antes e depois de qualquer publish.
2. **O plugin inclui o host do `home_url()` no `extra_cdn` automaticamente** quando ele difere do host do scrape base (fix em `MIS_Publisher::publish_now()`): como o conteúdo real tem URLs absolutas do host público e o serviço já baixa + reescreve hosts `extra_cdn` de ponta a ponta, basta adicionar `localhost:8300` à lista — o payload sai com `extra_cdn: ["wpthemetestdata.files.wordpress.com", "localhost:8300"]`.
3. **Shim `extra_hosts: ["localhost:host-gateway"]` no worker** (compose): em produção o host público do site é alcançável pelo worker; na POC o "host público" é o `localhost:8300` da máquina, então este shim faz o worker alcançá-lo — emula a condição real sem maquiar nada. É o que permite ao `wget` baixar os assets `localhost:8300` como page requisites.
4. **`WP_HOME`/`WP_SITEURL` dinâmicos seguem como receita de wp-config** para o scrape interno (não é alteração de banco): as URLs *geradas* pelo WP (menus, assets do tema) saem com o host do scrape e são relativizadas no post-process.

> **Estado conhecido das imagens (0.2.2)**: as imagens `driedel/make-it-static-*:0.2.2` **contêm todos os fixes** — postprocess (strip de host com fronteira, que mantém links `https://wordpress.org/...` intactos, e remoção do markup moderno de emoji) **e** `host:porta` no `--domains` do `wget` (a lista é montada sem porta — o wget compara o host da URL sem a porta — enquanto o postprocess recebe a lista original `host:porta` para reescrever as URLs). Evidência medida nesta POC: o log do scrape mostra `[scrape] wget --domains: wordpress,...,localhost` (sem porta) e o wget baixa as **35 mídias de conteúdo** referenciadas como `http://localhost:8300/...` (35 linhas de request), sem depender do fallback de URLs literais de `jobs.py` (0 downloads via fallback neste publish) nem de "carona" do host interno.

Telas do plugin no admin:

- **Settings → Make it Static** — http://localhost:8300/wp-admin/options-general.php?page=make-it-static (botão **Test connection** → `GET /health` **sem assinatura**).
- **Make it Static** (menu lateral) — http://localhost:8300/wp-admin/admin.php?page=mis-jobs (lista de jobs, botões **Cancel**/**Retry**, hint de logs em caso de falha).

## Dia a dia

| Comando | O que faz |
|---|---|
| `make help` | Lista os alvos disponíveis (alvo default) |
| `make up` | Sobe o stack completo (garante a rede, exige `.env`, valida portas 8300–8304, faz pull das imagens do serviço) |
| `make pull` | Atualiza as imagens do serviço (`driedel/make-it-static-*:${MIS_VERSION}`) |
| `make down` | Para e remove os containers (mantém os volumes/dados) |
| `make clean` | **Apaga tudo**, inclusive volumes (banco, bucket S3, uploads) |
| `make ps` | Status dos containers |
| `make seed` | Popula o WP com conteúdo de teste (`make seed FORCE=1` para rodar de novo) |
| `make health` | `GET /health` da API |
| `make logs-api` | Logs (follow) da API |
| `make logs-worker` | Logs (follow) do worker |
| `make logs-cron` | Logs (follow) do sidecar de WP-Cron |
| `make publish` | Cria e publica um post datado → dispara o fluxo real (debounce 15s) |
| `make publish-site` | Publica o site inteiro na hora (`MIS_Publisher::publish_now(0)`); imprime o job row id ou `WP_Error` |
| `make jobs` | Últimos 10 jobs da tabela `wp_mis_jobs` |
| `make bucket-ls` | Lista recursivamente o bucket `my-static-site` no LocalStack |
| `make preview` | HTTP status do preview (`:8301`) + hint para abrir no navegador |
| `make cron-run` | Força `wp cron event run --due-now` agora |
| `make break-secret` | Grava um segredo HMAC errado no `wp-config.php` (cenário 1) |
| `make fix-secret` | Restaura o segredo HMAC correto (lido do `.env`) |
| `make stop-api` | Para a API (cenário 2) |
| `make start-api` | Sobe a API novamente |

Fluxo típico: `make publish` → aguarde ~1 min → `make jobs` (status `finished`) → `make bucket-ls` → `make preview`.

## Cenários de falha

### 1. Segredo HMAC errado (401 `bad signature`)

```bash
make break-secret    # grava MAKE_IT_STATIC_HMAC_SECRET=poc-wrong-secret no wp-config.php
make publish-site    # deve imprimir WP_Error com 'bad signature' (o plugin trata o 401)
make fix-secret      # restaura o segredo correto, lido do .env
```

> **Nota:** o botão **Test connection** usa `GET /health` **sem assinatura**, então passa mesmo com o segredo errado — o 401 só aparece no publish.

### 2. API fora do ar

```bash
make stop-api
```

- Na tela **Settings → Make it Static** (http://localhost:8300/wp-admin/options-general.php?page=make-it-static), clique em **Test connection**: deve aparecer um `Connection failed: ...` amigável.
- `make publish-site` deve retornar `WP_Error` de conexão.

```bash
make start-api       # recupera o serviço
```

### 3. Job falho + retry

Quebre o scrape apontando o `scrape_url_base` para uma porta morta e zere os retries:

```bash
docker compose exec -T wpcli wp --allow-root --path=/var/www/html option update mis_settings --format=json '{"api_base_url":"http://make-it-static-api:8000","scrape_url_base":"http://wordpress:9999","cloudfront_distribution_id":"","extra_cdn":"wpthemetestdata.files.wordpress.com","options":{"bundle_css":true,"bundle_js":true,"compress_images":true,"compress_html":true,"convert_fonts":true},"retry_count":0,"debounce_interval":15,"post_types":["post","page"],"hmac_secret":""}'
```

Dispare e acompanhe até `failed`:

```bash
make publish-site    # anote o ROW_ID impresso
make jobs            # repita até o status virar 'failed'
```

A tela de jobs (http://localhost:8300/wp-admin/admin.php?page=mis-jobs) mostra a falha com **hint de logs**. Restaure as settings corretas:

```bash
docker compose exec -T wpcli wp --allow-root --path=/var/www/html option update mis_settings --format=json '{"api_base_url":"http://make-it-static-api:8000","scrape_url_base":"http://wordpress","cloudfront_distribution_id":"","extra_cdn":"wpthemetestdata.files.wordpress.com","options":{"bundle_css":true,"bundle_js":true,"compress_images":true,"compress_html":true,"convert_fonts":true},"retry_count":3,"debounce_interval":15,"post_types":["post","page"],"hmac_secret":""}'
```

> **Atenção — o Retry re-usa o payload gravado:** `MIS_Publisher::republish_row()` re-POSTa o payload **armazenado na row** (com a URL quebrada `http://wordpress:9999/`), então o retry de uma falha causada pelo *payload* volta a falhar — o retry foi feito para falhas *transitórias* (worker/S3 instável), em que o payload continua válido. Para a row falhar de novo e depois ir a `finished`, corrija o payload gravado antes de repetir o retry:

```bash
# Corrige a URL no payload gravado da row e dispara o retry (troque <ROW_ID>)
docker compose exec -T wpcli wp --allow-root --path=/var/www/html eval '
$row = MIS_Job_Store::get(<ROW_ID>);
$payload = $row["payload"];
$payload["url"] = "http://wordpress/";
MIS_Job_Store::update(<ROW_ID>, array("url" => "http://wordpress/", "payload" => $payload));
var_dump(MIS_Publisher::republish_row(MIS_Job_Store::get(<ROW_ID>)));
'
```

Acompanhe `make jobs` até `finished` (ou clique em **Retry** na tela de jobs depois de corrigir o payload).

## Estrutura do repo

```
make-it-an-poc/
├── docker-compose.yml          # stack: wordpress, wpcli, cron, db, redis, api, worker, localstack, preview
├── .env                        # segredos/config local — NÃO commitar (está no .gitignore)
├── .env.example                # template do .env (HMAC_SECRET com placeholder)
├── Makefile                    # automação do dia a dia — make help
├── README.md                   # este arquivo
├── seed/
│   └── seed.sh                 # popula o WP: importa conteúdo, ativa o plugin, grava mis_settings
├── localstack/
│   └── init-s3.sh              # cria o bucket my-static-site no boot do LocalStack
└── nginx/
    └── default.conf.template   # template do nginx de preview (:8301 → S3)
```

`localstack/init-s3.sh` e `nginx/default.conf.template` foram **copiados do clone do serviço** (`../make-it-static`) para a POC ser autocontida.

## Troubleshooting

- **Porta em uso**: o `make up` valida as portas 8300–8304 e diz qual está ocupada. Pare o processo conflitante (incluindo o stack dev do `make-it-static`) e tente de novo.
- **Rodar uma versão diferente do serviço**: ajuste `MIS_VERSION` no `.env` e rode `make pull && docker compose up -d`.
- **Build local do serviço (desenvolvimento)**: descomente as linhas `build:` de `make-it-static-api`/`make-it-static-worker` no `docker-compose.yml` (e comente os `image:`), exigindo o clone `../make-it-static`; depois `docker compose up --build -d`.
- **Ver logs**: `make logs-worker` (scrape/upload), `make logs-api`, `make logs-cron`.
- **Reset total**: `make clean && make up && make seed`.
- **Onde ficam os jobs**: no admin, menu lateral **Make it Static** (http://localhost:8300/wp-admin/admin.php?page=mis-jobs); no banco, tabela `wp_mis_jobs` (atalho: `make jobs`).
- **Cron parece parado**: o WP-Cron só dispara via sidecar `cron` (loop de 30s) ou manualmente com `make cron-run`.

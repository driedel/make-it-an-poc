.DEFAULT_GOAL := help

WP := docker compose exec -T wpcli wp --allow-root --path=/var/www/html

.PHONY: help up pull down clean ps seed health logs-api logs-worker logs-cron publish publish-site jobs bucket-ls preview cron-run break-secret fix-secret stop-api start-api benchmark

help: ## Lista os alvos disponíveis (este menu)
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

up: ## Sobe o stack completo (rede, .env, portas 8300-8304, imagens do Hub)
	@docker network inspect make-it-static-network >/dev/null 2>&1 || docker network create make-it-static-network
	@if [ ! -f .env ]; then \
		echo "Erro: arquivo .env não encontrado."; \
		echo "  1) cp .env.example .env"; \
		echo "  2) Gere o segredo HMAC com: openssl rand -hex 32"; \
		echo "  3) Preencha HMAC_SECRET no .env com o valor gerado."; \
		exit 1; \
	fi
	@for port in 8300 8301 8302 8303 8304; do \
		if lsof -nP -iTCP:$$port -sTCP:LISTEN >/dev/null 2>&1; then \
			echo "Erro: porta $$port já está em uso:"; \
			lsof -nP -iTCP:$$port -sTCP:LISTEN; \
			echo "Libere a porta (pare o processo ou o stack que a ocupa) e tente novamente."; \
			exit 1; \
		fi; \
	done
	docker compose up -d
	@echo ""
	@echo "Stack subindo. Acompanhe com: make ps"
	@echo "Quando o WordPress estiver no ar, popule o conteúdo com: make seed"

pull: ## Baixa imagens novas do Hub (ex.: após mudar MIS_VERSION no .env) e recria
	docker compose pull
	docker compose up -d

PLAYWRIGHT_IMAGE := mcr.microsoft.com/playwright:v1.64.1-noble

benchmark: ## Roda o benchmark WP dinâmico vs site estático (Playwright em Docker, ~96 page loads)
	docker run --rm --add-host=host.docker.internal:host-gateway \
		-v "$(PWD):/work" -w /work \
		-e PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 \
		$(PLAYWRIGHT_IMAGE) \
		sh -c "cd docs/benchmark && (test -d node_modules/playwright || npm install --no-audit --no-fund) && cd ../.. && node docs/benchmark/measure.mjs && node docs/benchmark/report.mjs"

down: ## Para e remove os containers (mantém os volumes/dados)
	docker compose down

clean: ## Derruba tudo e APAGA os volumes (banco, bucket S3 e uploads do WP)
	@echo "ATENÇÃO: apagando volumes — banco MariaDB, bucket S3 e arquivos do WP serão perdidos."
	docker compose down -v

ps: ## Mostra o status dos containers
	docker compose ps

seed: ## Popula o WP com conteúdo de teste (FORCE=1 para rodar de novo)
	docker compose exec -T wpcli sh /seed/seed.sh $(if $(filter 1,$(FORCE)),--force,)

health: ## Checa a saúde da API (esperado: {"ok":true,"redis":true})
	@curl -s http://localhost:8302/health; echo

logs-api: ## Segue os logs da API (make-it-static-api)
	docker compose logs -f make-it-static-api

logs-worker: ## Segue os logs do worker (scrape + upload S3)
	docker compose logs -f make-it-static-worker

logs-cron: ## Segue os logs do sidecar de WP-Cron
	docker compose logs -f cron

publish: ## Cria e publica um post datado (dispara o fluxo real de publish)
	@DATE=$$(date '+%Y-%m-%d %H:%M:%S'); \
	echo "Criando e publicando o post 'POC publish '$$DATE ..."; \
	docker compose exec -T wpcli wp --allow-root --path=/var/www/html post create --post_title="POC publish $$DATE" --post_status=publish --post_type=post
	@echo ""
	@echo "Post publicado. O plugin agenda o envio em ~15s (debounce) e o poller roda a cada 30s."
	@echo "Próximos passos:"
	@echo "  make jobs        # acompanhe o status até 'finished'"
	@echo "  make logs-cron   # disparo do WP-Cron e POST /publish"
	@echo "  make logs-worker # scrape e upload para o S3"
	@echo "  make preview     # confira o site estático gerado"

publish-site: ## Publica o site inteiro na hora (sem debounce); imprime o job row id ou WP_Error
	$(WP) eval 'var_dump(MIS_Publisher::publish_now(0));'

jobs: ## Lista os últimos 10 jobs da tabela wp_mis_jobs
	$(WP) db query "SELECT id, job_id, post_id, status, attempts, error, updated_at FROM wp_mis_jobs ORDER BY id DESC LIMIT 10"

bucket-ls: ## Lista recursivamente os objetos do bucket my-static-site (LocalStack)
	docker compose exec -T localstack awslocal s3 ls s3://my-static-site --recursive

preview: ## Testa o preview estático (HTTP status do nginx na :8301)
	@curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8301/
	@echo "Abra http://localhost:8301/ no navegador para ver o site estático."

cron-run: ## Executa agora os eventos WP-Cron pendentes
	$(WP) cron event run --due-now

break-secret: ## Grava um segredo HMAC errado no wp-config (cenário de falha: 401)
	$(WP) config set MAKE_IT_STATIC_HMAC_SECRET poc-wrong-secret --type=constant
	@echo ""
	@echo "Segredo quebrado: o próximo publish deve falhar com 'bad signature' (HTTP 401 tratado pelo plugin)."
	@echo "  Teste com:    make publish-site"
	@echo "  Restaure com: make fix-secret"

fix-secret: ## Restaura no wp-config o segredo HMAC lido do .env
	@SECRET=$$(grep '^HMAC_SECRET=' .env | cut -d= -f2-); \
	if [ -z "$$SECRET" ]; then \
		echo "Erro: HMAC_SECRET não encontrado no .env"; \
		exit 1; \
	fi; \
	docker compose exec -T wpcli wp --allow-root --path=/var/www/html config set MAKE_IT_STATIC_HMAC_SECRET "$$SECRET" --type=constant
	@echo "Segredo restaurado a partir do .env."

stop-api: ## Para a API (cenário de falha: serviço fora do ar)
	docker compose stop make-it-static-api

start-api: ## Sobe a API novamente (após stop-api)
	docker compose start make-it-static-api

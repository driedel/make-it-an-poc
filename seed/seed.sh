#!/bin/sh
#
# seed.sh — popula o WordPress da POC "Make it Static" com conteúdo de teste.
#
# Uso (dentro do container wpcli):
#   docker compose exec wpcli sh /seed/seed.sh [--force]
#
# Sem --force: se a option mis_poc_seeded já for 1, não faz nada (idempotente).
# Com --force: esvazia o site (wp site empty) e refaz todo o seed.
#
# Não usamos `set -e` de propósito: falhas pontuais de rede/download/imagem
# não podem abortar o seed. Os passos críticos (banco, instalação do WP,
# ativação do plugin e gravação de options) são verificados com die().

set -u

WP="wp --allow-root --path=/var/www/html"

POC_URL="http://localhost:8300"
SITE_TITLE="Make it Static POC"
ADMIN_USER="admin"
ADMIN_PASSWORD="mis-poc-2026"
ADMIN_EMAIL="poc@example.com"

MIN_POSTS=20
MIN_PAGES=5
MAX_FEATURED_IMAGES=20
# Teto de conteúdo para o scrape do worker caber com folga no timeout de 300s
# (wget --wait=0.5 ≈ 0,55s por request ⇒ ~540 requests; o Theme Unit Test
# completo gera ~500 e qualquer post a mais derruba o job no timeout).
MAX_POSTS=25
MAX_PAGES=8

XML_FILE="/tmp/theme-unit-test.xml"
THEME_UNIT_TEST_URLS="https://raw.githubusercontent.com/WordPress/theme-test-data/master/themeunittestdata.wordpress.xml https://raw.githubusercontent.com/WPTT/theme-unit-test/master/themeunittestdata.wordpress.xml"

# hmac_secret vai vazio de propósito: a constante MAKE_IT_STATIC_HMAC_SECRET
# (wp-config) tem precedência — o segredo nunca é gravado no banco.
# extra_cdn: o Theme Unit Test referencia imagens externas
# (wpthemetestdata.files.wordpress.com) que o importer não baixa; com o domínio
# na lista o worker baixa esses assets e o postprocess os relativiza.
MIS_SETTINGS_JSON='{"api_base_url":"http://make-it-static-api:8000","scrape_url_base":"http://wordpress","cloudfront_distribution_id":"","extra_cdn":"wpthemetestdata.files.wordpress.com","options":{"bundle_css":true,"bundle_js":true,"compress_images":true,"compress_html":true,"convert_fonts":true},"retry_count":3,"debounce_interval":15,"post_types":["post","page"],"hmac_secret":""}'

log() {
  printf '[seed] %s\n' "$*"
}

die() {
  printf '[seed] ERRO: %s\n' "$*" >&2
  exit 1
}

wait_for_db() {
  max=60
  attempt=1
  while [ "$attempt" -le "$max" ]; do
    if $WP db check >/dev/null 2>&1; then
      log "banco de dados respondendo"
      return 0
    fi
    log "aguardando o banco de dados... (tentativa $attempt/$max)"
    sleep 2
    attempt=$((attempt + 1))
  done
  die "o banco de dados não respondeu após $max tentativas"
}

ensure_wordpress_installed() {
  if $WP core is-installed >/dev/null 2>&1; then
    log "WordPress já instalado"
    return 0
  fi
  log "instalando o WordPress ($SITE_TITLE em $POC_URL)"
  $WP core install \
    --url="$POC_URL" \
    --title="$SITE_TITLE" \
    --admin_user="$ADMIN_USER" \
    --admin_password="$ADMIN_PASSWORD" \
    --admin_email="$ADMIN_EMAIL" \
    --skip-email || die "falha ao instalar o WordPress (wp core install)"
  log "WordPress instalado (usuário admin: $ADMIN_USER)"
}

fetch() {
  url=$1
  out=$2
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --max-time 120 "$url" -o "$out"
  elif command -v wget >/dev/null 2>&1; then
    wget -q -T 120 -O "$out" "$url"
  else
    $WP eval "file_put_contents('$out', file_get_contents('$url'));" >/dev/null 2>&1
  fi
}

import_theme_unit_test() {
  downloaded=""
  for url in $THEME_UNIT_TEST_URLS; do
    log "baixando o Theme Unit Test: $url"
    rm -f "$XML_FILE"
    if fetch "$url" "$XML_FILE" && [ -s "$XML_FILE" ] && grep -q '<rss' "$XML_FILE"; then
      downloaded=1
      break
    fi
    log "aviso: download falhou ou arquivo inválido em $url"
  done

  if [ -z "$downloaded" ]; then
    log "aviso: sem acesso ao Theme Unit Test; o conteúdo mínimo será gerado localmente"
    return 0
  fi

  if $WP plugin is-installed wordpress-importer >/dev/null 2>&1; then
    $WP plugin activate wordpress-importer >/dev/null 2>&1 || true
  elif ! $WP plugin install wordpress-importer --activate; then
    log "aviso: falha ao instalar o plugin wordpress-importer; importação pulada"
    return 0
  fi

  log "importando o Theme Unit Test (falhas em anexos remotos são toleradas)"
  if $WP import "$XML_FILE" --authors=create; then
    log "importação do Theme Unit Test concluída"
  else
    log "aviso: wp import terminou com erros; seguindo o seed"
  fi
  return 0
}

remove_scrape_traps() {
  # Posts com Query Loop blocks (wp:query) renderizam paginação ?query-N-page=M —
  # armadilha de crawl infinita para o wget --level=0 do worker: o reject-regex do
  # scrape.sh cobre /page/N/, mas não query vars, e o job estoura o timeout de 300s.
  ids=$($WP db query "SELECT ID FROM wp_posts WHERE post_status='publish' AND post_content LIKE '%wp:query%'" 2>/dev/null | tail -n +2 || true)
  if [ -z "$ids" ]; then
    log "nenhum post com Query Loop block (wp:query) encontrado"
    return 0
  fi
  for id in $ids; do
    log "removendo o post $id (Query Loop block = armadilha de crawl para o scrape)"
    $WP post delete "$id" --force --defer-term-counting >/dev/null 2>&1 \
      || log "aviso: falha ao remover o post $id"
  done
  return 0
}

trim_content_for_scrape_budget() {
  # Mantém apenas os MAX_POSTS posts e MAX_PAGES páginas mais recentes: o Theme
  # Unit Test completo deixa o scrape a ~97% do timeout de 300s do worker.
  for spec in "post:$MAX_POSTS" "page:$MAX_PAGES"; do
    type=${spec%%:*}
    keep=${spec##*:}
    total=$(count_published "$type")
    if [ "$total" -le "$keep" ]; then
      log "$type publicados: $total (dentro do teto de $keep para o scrape)"
      continue
    fi
    excess=$((total - keep))
    log "aparando $type: $total publicados → mantendo os $keep mais recentes (orçamento do scrape)"
    ids=$($WP post list --post_type="$type" --post_status=publish --posts_per_page="$excess" --orderby=date --order=ASC --format=ids 2>/dev/null || true)
    for id in $ids; do
      $WP post delete "$id" --force --defer-term-counting >/dev/null 2>&1 \
        || log "aviso: falha ao remover o $type $id"
    done
  done
  return 0
}

count_published() {
  n=$($WP post list --post_type="$1" --post_status=publish --format=count 2>/dev/null || true)
  case "$n" in
    ''|*[!0-9]*) printf '0\n' ;;
    *) printf '%s\n' "$n" ;;
  esac
}

ensure_minimum_content() {
  posts=$(count_published post)
  if [ "$posts" -lt "$MIN_POSTS" ]; then
    missing=$((MIN_POSTS - posts))
    log "posts publicados: $posts — gerando mais $missing para atingir o mínimo de $MIN_POSTS"
    $WP post generate --count="$missing" --post_status=publish --post_title="POC Post" \
      || log "aviso: falha ao gerar posts"
  else
    log "posts publicados: $posts (mínimo de $MIN_POSTS ok)"
  fi

  pages=$(count_published page)
  if [ "$pages" -lt "$MIN_PAGES" ]; then
    missing=$((MIN_PAGES - pages))
    log "páginas publicadas: $pages — gerando mais $missing para atingir o mínimo de $MIN_PAGES"
    $WP post generate --count="$missing" --post_type=page --post_status=publish --post_title="POC Page" \
      || log "aviso: falha ao gerar páginas"
  else
    log "páginas publicadas: $pages (mínimo de $MIN_PAGES ok)"
  fi
}

generate_png() {
  # PNG sólido 1200x800 via GD — fallback offline do picsum.
  out=$1
  idx=$2
  $WP eval "
if (!function_exists('imagecreatetruecolor')) { exit(1); }
\$i = $idx;
\$im = imagecreatetruecolor(1200, 800);
\$bg = imagecolorallocate(\$im, (52 + \$i * 17) % 200, (90 + \$i * 29) % 200, (140 + \$i * 13) % 200);
imagefill(\$im, 0, 0, \$bg);
\$ok = imagepng(\$im, '$out');
imagedestroy(\$im);
exit(\$ok ? 0 : 1);
" >/dev/null 2>&1
}

add_featured_images() {
  ids=$($WP post list --post_type=post --post_status=publish --posts_per_page="$MAX_FEATURED_IMAGES" --format=ids 2>/dev/null || true)
  if [ -z "$ids" ]; then
    log "nenhum post publicado encontrado para imagens destacadas"
    return 0
  fi

  i=0
  for id in $ids; do
    thumb=$($WP post meta get "$id" _thumbnail_id 2>/dev/null || true)
    if [ -n "$thumb" ]; then
      continue
    fi
    i=$((i + 1))
    img_url="https://picsum.photos/seed/mis$i/1200/800.jpg"
    log "post $id: baixando imagem destacada ($img_url)"
    if $WP media import "$img_url" --post_id="$id" --featured_image --title="POC image $i" >/dev/null 2>&1; then
      continue
    fi
    log "post $id: download falhou; gerando PNG local via GD"
    png="/tmp/poc-image-$i.png"
    if generate_png "$png" "$i"; then
      $WP media import "$png" --post_id="$id" --featured_image --title="POC image $i" >/dev/null 2>&1 \
        || log "aviso: falha ao importar o PNG local para o post $id"
      rm -f "$png"
    else
      log "aviso: GD indisponível; o post $id ficará sem imagem destacada"
    fi
  done

  if [ "$i" -eq 0 ]; then
    log "os $MAX_FEATURED_IMAGES posts mais recentes já tinham imagem destacada"
  fi
  return 0
}

setup_theme() {
  if $WP theme is-active twentytwentyone >/dev/null 2>&1; then
    log "tema twentytwentyone já está ativo"
    return 0
  fi
  if $WP theme list --field=name 2>/dev/null | grep -qx 'twentytwentyone'; then
    log "ativando o tema twentytwentyone (já instalado)"
    $WP theme activate twentytwentyone && return 0
  else
    log "instalando e ativando o tema twentytwentyone"
    $WP theme install twentytwentyone --activate && return 0
  fi

  fallback=$($WP theme list --field=name 2>/dev/null | grep '^twenty' | head -n 1 || true)
  if [ -n "$fallback" ]; then
    log "aviso: twentytwentyone indisponível; ativando o tema $fallback"
    $WP theme activate "$fallback" || log "aviso: falha ao ativar o tema $fallback"
  else
    log "aviso: nenhum tema twenty* disponível; mantendo o tema atual"
  fi
  return 0
}

setup_options() {
  log "configurando posts_per_page=25, timezone e permalinks /%postname%/"
  $WP option update posts_per_page 25 || die "falha ao atualizar a option posts_per_page"
  $WP option update timezone_string America/Sao_Paulo || die "falha ao atualizar a option timezone_string"
  $WP rewrite structure '/%postname%/' || die "falha ao configurar os permalinks"
}

setup_menu() {
  if $WP menu get main >/dev/null 2>&1; then
    log "menu 'main' já existe"
  else
    log "criando o menu 'Main'"
    if ! $WP menu create Main >/dev/null; then
      log "aviso: não foi possível criar o menu 'Main'; pulando a configuração de menu"
      return 0
    fi
  fi

  # Home com URL relativa: um item custom com URL absoluta (http://localhost:8300/)
  # vazaria para o HTML raspado — o postprocess do worker só reescreve o host do
  # scrape (SCRAPE_INTERNAL_HOSTS não é lido pelo worker), e "/" funciona tanto no
  # WP (localhost:8300) quanto no preview estático (:8301).
  $WP menu item add-custom main Home "/" >/dev/null \
    || log "aviso: falha ao adicionar o item Home ao menu"
  for pid in $($WP post list --post_type=page --post_status=publish --format=ids 2>/dev/null || true); do
    $WP menu item add-post main "$pid" >/dev/null \
      || log "aviso: falha ao adicionar a página $pid ao menu"
  done

  # --format=csv inclui linha de cabeçalho ("location,description"): pular com tail.
  locations=$($WP menu location list --format=csv 2>/dev/null | tail -n +2 | cut -d, -f1 || true)
  if printf '%s\n' "$locations" | grep -qx 'primary'; then
    location="primary"
  else
    location=$(printf '%s\n' "$locations" | sed -n '1p')
  fi

  if [ -n "$location" ]; then
    log "atribuindo o menu 'main' à location '$location'"
    $WP menu location assign main "$location" >/dev/null \
      || log "aviso: falha ao atribuir o menu à location '$location'"
  else
    log "aviso: o tema ativo não registra locations de menu; menu 'main' criado sem location"
  fi
  return 0
}

setup_plugin() {
  log "ativando o plugin make-it-static"
  $WP plugin activate make-it-static \
    || die "falha ao ativar o plugin make-it-static (verifique o bind mount em wp-content/plugins/make-it-static)"

  # A constante é gravada no wp-config.php (nunca na option/banco). Precisa ser um
  # define literal — e não o eval do WORDPRESS_CONFIG_EXTRA — para que os alvos
  # `make break-secret`/`make fix-secret` consigam alterá-la com `wp config set`.
  log "gravando MAKE_IT_STATIC_HMAC_SECRET no wp-config.php (a partir do env HMAC_SECRET)"
  [ -n "${HMAC_SECRET:-}" ] || die "env HMAC_SECRET ausente no container wpcli"
  $WP config set MAKE_IT_STATIC_HMAC_SECRET "$HMAC_SECRET" --type=constant \
    || die "falha ao gravar MAKE_IT_STATIC_HMAC_SECRET no wp-config.php"

  log "gravando a option mis_settings com os valores da POC"
  $WP option update mis_settings --format=json "$MIS_SETTINGS_JSON" \
    || die "falha ao gravar a option mis_settings"
}

finish() {
  log "finalizando: flush de rewrite rules e permissões de uploads"
  $WP rewrite flush --hard >/dev/null 2>&1 || $WP rewrite flush >/dev/null 2>&1 \
    || log "aviso: rewrite flush falhou"
  chown -R www-data:www-data /var/www/html/wp-content/uploads 2>/dev/null || true
  $WP option update mis_poc_seeded 1 || die "falha ao gravar a option mis_poc_seeded"
}

report() {
  posts=$(count_published post)
  pages=$(count_published page)
  media=$($WP post list --post_type=attachment --post_status=inherit --format=count 2>/dev/null || true)
  theme=$($WP option get stylesheet 2>/dev/null || true)
  menu_items=$($WP menu item list main --format=count 2>/dev/null || true)

  log "---------------- relatório do seed ----------------"
  log "posts publicados:    $posts"
  log "páginas publicadas:  $pages"
  log "anexos (mídia):      ${media:-?}"
  log "tema ativo:          ${theme:-?}"
  log "itens no menu main:  ${menu_items:-?}"
  log "settings do plugin (option mis_settings):"
  $WP option get mis_settings --format=json 2>/dev/null | sed 's/^/[seed]   /' || true
  log "---------------------------------------------------"
}

FORCE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --force)
      FORCE=1
      ;;
    -h|--help)
      printf 'uso: sh /seed/seed.sh [--force]\n'
      exit 0
      ;;
    *)
      die "argumento desconhecido: $1 (uso: sh /seed/seed.sh [--force])"
      ;;
  esac
  shift
done

[ -d /var/www/html ] || die "rode dentro do container wpcli: docker compose exec wpcli sh /seed/seed.sh [--force]"

log "iniciando o seed da POC Make it Static"
if [ "$FORCE" -eq 1 ]; then
  log "modo --force: o conteúdo atual do site será apagado"
fi

wait_for_db

if [ "$FORCE" -eq 1 ]; then
  if $WP core is-installed >/dev/null 2>&1; then
    log "esvaziando o conteúdo atual do site (wp site empty)"
    $WP site empty --yes || die "falha ao esvaziar o site (wp site empty)"
  else
    log "o WordPress ainda não está instalado; seguindo com o seed normal"
  fi
else
  seeded=$($WP option get mis_poc_seeded 2>/dev/null || true)
  if [ "$seeded" = "1" ]; then
    log "seed já executado anteriormente (mis_poc_seeded=1); nada a fazer. Use --force para refazer."
    exit 0
  fi
fi

ensure_wordpress_installed
import_theme_unit_test
remove_scrape_traps
trim_content_for_scrape_budget
ensure_minimum_content
add_featured_images
setup_theme
setup_options
setup_menu
setup_plugin
finish
report

log "seed concluído com sucesso"
exit 0

# RASCUNHO — WordPress dinâmico vs site estático: medimos a diferença de verdade (e achamos 3 bugs no caminho)

> **Status: DRAFT** — rascunho de artigo para revisão. Os números são os da rodada de benchmark desta POC (idênticos a `benchmark/results/results.md`).

---

## O que é esta POC (e por que ela existe)

O **Make it Static** é um serviço que transforma um site WordPress em um site 100% estático: um plugin no WordPress avisa o serviço (um `POST /publish` assinado com HMAC) sempre que algo muda; um worker raspa o site com `wget`, otimiza tudo (bundle de CSS/JS, compressão de imagens e HTML, conversão de fontes) e sobe o resultado para um bucket S3 — que é o que os visitantes passam a ver.

A POC descrita aqui sobe **tudo em Docker** — WordPress real com o plugin, API, worker, Redis, S3 (LocalStack) e um nginx de preview — e exercita o fluxo de ponta a ponta, como um usuário real faria. A premissa é simples: **não dá para confiar em um pipeline desses sem vê-lo funcionar de verdade, com conteúdo de verdade** (usamos o WordPress Theme Unit Test Data, o mesmo conjunto de conteúdo que os temas oficiais usam para teste).

E "ver funcionando" inclui duas perguntas que só um teste E2E honesto responde:

1. **O site estático é mesmo mais rápido?** (o benchmark deste artigo)
2. **O pipeline aguenta um WordPress de verdade?** (a resposta curta: aguenta — mas só depois que o E2E expôs 3 bugs reais no serviço, que viraram as releases v0.2.1 e v0.2.2)

## Metodologia do benchmark

Comparamos o **WordPress dinâmico** (Apache + PHP + MariaDB, na porta 8300) com o **site estático** gerado pelo pipeline (nginx de preview, na porta 8301), lado a lado, na mesma máquina:

- **Páginas**: home (`/`), `/block-gallery/` (pesada em imagens), `/markup-image-alignment/` (imagens de conteúdo) e `/category/block/` (arquivo de categoria).
- **Coleta**: Playwright (Chromium) rodando em Docker, via CDP. Para cada alvo × página × perfil: **1 warmup + 5 runs medidos**, cada um em um contexto de navegador novo (**cache frio**). Os valores reportados são **medianas**.
- **Perfis**: `unthrottled` (rede local) e `throttled` (~1,6 Mbps de download / 750 Kbps de upload / 150 ms de RTT + CPU 4× mais lenta — algo como um 3G rápido).
- **Justiça de compressão**: os dois lados servem **gzip**. O WordPress (Apache) já comprimia; o preview nginx **não** — então adicionamos gzip ao preview, em paridade com a compressão de borda que o CloudFront faria em produção. Sem isso, a comparação de bytes seria desonesta.
- **Bytes** = `encodedDataLength` (tamanho no fio, já comprimido).

## Resultados

Mediana das 4 páginas (visão geral):

| Métrica | Perfil | WordPress dinâmico | Estático | Δ% |
|---|---|---|---|---|
| Requests | unthrottled | 11 | 8 | **−31,8%** |
| Requests | throttled | 11 | 7 | **−36,4%** |
| Bytes (fio) | ambos | 681,0 KB | 667,5 KB | −2,0% |
| TTFB | unthrottled | 45 ms | 6 ms | **−86,2%** |
| TTFB | throttled | 43 ms | 6 ms | **−86,7%** |
| FCP | unthrottled | 82 ms | 50 ms | **−39,0%** |
| LCP | unthrottled | 82 ms | 50 ms | **−39,0%** |
| DOMContentLoaded | unthrottled | 72 ms | 33 ms | **−54,2%** |
| Load | unthrottled | 73 ms | 36 ms | **−50,4%** |
| Load | throttled | 3698 ms | 3628 ms | −1,9% |

Recorte por página (unthrottled), para mostrar que o ganho de payload depende do conteúdo:

| Página | Bytes WP | Bytes estático | Δ% | Requests WP | Requests estático |
|---|---|---|---|---|---|
| `/` | 681,9 KB | 668,7 KB | −1,9% | 9 | 6 |
| `/block-gallery/` | 1,86 MB | 1,23 MB | **−33,9%** | 22 | 18 |
| `/markup-image-alignment/` | 209,9 KB | 119,7 KB | **−43,0%** | 13 | 9 |
| `/category/block/` | 680,1 KB | 666,4 KB | −2,0% | 9 | 6 |

**Leitura dos números.** O estático vence em toda métrica estrutural: **−86% de TTFB** (não há PHP nem banco no caminho da requisição), **~−33% de requests** (CSS e JS bundleados em um arquivo cada) e tempos de render praticamente **pela metade** sem throttling. O ganho de payload é **dependente de conteúdo**: os −2% gerais escondem que as páginas pesadas de imagem ganham muito (−34% a −43%), enquanto a home e a categoria são dominadas por JPEGs grandes que **já eram bem comprimidos** na origem — para esses, o AVIF do worker economiza pouco (ex.: uma imagem de 238,7 KB virou 234,9 KB). Onde a origem já é eficiente, o ganho de bytes é modesto; onde há imagem "crua", o AVIF brilha.

## Os 3 bugs que o E2E expôs (e como foram corrigidos)

A parte mais valiosa da POC não foi confirmar que o fluxo funciona — foi descobrir **onde ele quebrava com um WordPress de verdade**. Três bugs reais no serviço, todos invisíveis para os testes unitários, apareceram quando apontamos o pipeline para o Theme Unit Test:

**1. Strip de host sem fronteira quebrava links externos.** O postprocess reescrevia URLs do host de origem para caminhos relativos — mas casava o host como prefixo simples. Resultado: um link para `https://wordpress.org/...` virava `/.org/...` (404 garantido). O conteúdo de teste tem links para wordpress.org aos montes, então a quebra era impossível de não ver no HTML estático. **Correção**: o strip agora exige fronteira depois do host (lookahead) — `https://wordpress.org/` fica intacto. Publicado na **v0.2.1**.

**2. Markup moderno de emoji do WP vazava para o estático (e dava 404).** O WordPress 6.9+ injeta um conjunto novo de marcação de emoji (style inline, JSON de settings e um script loader com `_wpemojiSettings`/`wpEmojiSettingsSupports`). O postprocess removia o markup antigo, mas não o novo — que ficava no HTML apontando para arquivos que o scrape não baixa. **Correção**: o postprocess passou a remover as três partes do markup moderno. Também na **v0.2.1**.

**3. `--domains` do wget não casava host:porta.** Sites reais têm URLs absolutas do host público no conteúdo (ex.: `http://localhost:8300/wp-content/uploads/...`). O plugin passou a incluir o host do `home_url()` no `extra_cdn` automaticamente, e o worker recebe esse host com porta (`localhost:8300`). Só que o `--domains` do wget compara o host da URL **sem a porta** — então a entrada `localhost:8300` nunca casava, e o wget silenciosamente não baixava esses assets (a rodada com a v0.2.1 mostrou **0 downloads** wget para localhost:8300; 5 arquivos se salvaram por um fallback de varredura de URLs literais, e o resto passou "de carona" porque estava linkado também pelo host interno — cobertura por sorte, não por design). **Correção**: o `scrape.sh` passou a montar o `--domains` **sem porta** (o postprocess continua recebendo `host:porta` para reescrever as URLs). Publicado na **v0.2.2** — com a imagem nova, o wget baixa as **35 mídias de conteúdo** diretamente (35 linhas de request no log), sem depender de fallback nem de sorte.

Nenhum dos três apareceria em um teste que não fosse E2E com conteúdo realista: o primeiro exigia links externos no conteúdo; o segundo, um WP 6.9+ renderizando de verdade; o terceiro, um banco com URLs absolutas e um host com porta não-padrão.

## Ressalvas (para não nos enganarmos)

- **O WordPress aqui é local, em Docker** — mais rápido que uma hospedagem compartilhada típica. Os ganhos de **payload e nº de requests são exatos**; os ganhos de **tempo de servidor** (TTFB, Load) são **indicativos** — contra um WP hospedado de verdade, seriam *maiores*.
- Sob throttling, o FCP/DCL do estático ficou marginalmente **atrás** em algumas páginas (+5,8%/+4,4% na visão geral, ~55 ms): o JS bundleado perde o atributo `defer` na bundling e sai render-blocking no fim do `<head>`, enquanto os scripts do tema são deferidos. Load (−1,9%) e LCP (−0,3%) seguem a favor/empatados. Manter o `defer` no bundle é uma melhoria candidata no serviço.
- O benchmark mede **uma máquina, um conteúdo, dois perfis de rede**. É um indicativo sólido da estrutura (requests, bytes, TTFB), não uma promessa de números idênticos em qualquer site.

## Conclusão

O site estático é estruturalmente mais eficiente: **86% menos TTFB, um terço menos requests, render pela metade** — e o ganho de payload cresce com a "cruelza" das imagens de origem. Mas o aprendizado mais duradouro da POC foi outro: **um pipeline desses só é confiável depois de sobreviver a um WordPress real de ponta a ponta**. Os 3 bugs que o E2E expôs — e que agora estão corrigidos e publicados (v0.2.1/v0.2.2) — valem mais que qualquer número de benchmark.

Para reproduzir: `make up && make seed && make publish-site` (espere `finished`) e `make benchmark`. O detalhe completo, página a página, está em `benchmark/results/results.md`.

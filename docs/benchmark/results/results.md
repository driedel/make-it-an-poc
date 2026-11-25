# Benchmark results — dynamic WordPress vs static site

Generated: 2026-11-25T19:07:34.227Z

Method: 1 warmup + 5 measured runs per target × page × profile, each run in a fresh
browser context (cold cache). Values are medians. Bytes = `encodedDataLength` (wire
size, gzip on both sides). Δ% = static vs WP (negative = static is smaller/faster).

## Profile: unthrottled

### Overall (median of the 5 page medians)

| Metric | WordPress (dynamic) | Static | Δ% |
|---|---|---|---|
| Requests (total) | 13 | 9 | -30.8% |
| Bytes (total, wire) | 681.9 KB | 669.2 KB | -1.9% |
| TTFB | 38 ms | 5 ms | -85.9% |
| FCP | 80 ms | 48 ms | -40.0% |
| LCP | 80 ms | 48 ms | -40.0% |
| DOMContentLoaded | 79 ms | 31 ms | -60.1% |
| Load | 79 ms | 36 ms | -53.9% |

#### Requests by type (overall)

| Type | WP | Static | Δ% |
|---|---|---|---|
| document | 1 | 1 | 0.0% |
| script | 3 | 1 | -66.7% |
| stylesheet | 2 | 1 | -50.0% |
| image | 7 | 6 | -14.3% |
| media | 0 | 0 | — |

#### Bytes by type (overall)

| Type | WP | Static | Δ% |
|---|---|---|---|
| document | 17.6 KB | 17.5 KB | -0.6% |
| script | 3.2 KB | 5.2 KB | +62.0% |
| stylesheet | 24.5 KB | 24.9 KB | +1.5% |
| image | 636.6 KB | 621.5 KB | -2.4% |
| media | 0 B | 0 B | — |

### Per page (medians)

| Page | Metric | WP | Static | Δ% |
|---|---|---|---|---|
| / | Requests (total) | 9 | 6 | -33.3% |
| / | Bytes (total, wire) | 681.9 KB | 669.2 KB | -1.9% |
| / | TTFB | 52 ms | 7 ms | -87.2% |
| / | FCP | 88 ms | 52 ms | -40.9% |
| / | LCP | 88 ms | 52 ms | -40.9% |
| / | DOMContentLoaded | 80 ms | 31 ms | -61.5% |
| / | Load | 80 ms | 36 ms | -54.7% |
| /block-gallery/ | Requests (total) | 22 | 18 | -18.2% |
| /block-gallery/ | Bytes (total, wire) | 1.86 MB | 1.23 MB | -33.8% |
| /block-gallery/ | TTFB | 38 ms | 4 ms | -88.8% |
| /block-gallery/ | FCP | 76 ms | 44 ms | -42.1% |
| /block-gallery/ | LCP | 76 ms | 44 ms | -42.1% |
| /block-gallery/ | DOMContentLoaded | 67 ms | 38 ms | -43.0% |
| /block-gallery/ | Load | 68 ms | 39 ms | -42.2% |
| /markup-image-alignment/ | Requests (total) | 13 | 9 | -30.8% |
| /markup-image-alignment/ | Bytes (total, wire) | 209.9 KB | 120.4 KB | -42.6% |
| /markup-image-alignment/ | TTFB | 31 ms | 6 ms | -80.1% |
| /markup-image-alignment/ | FCP | 68 ms | 44 ms | -35.3% |
| /markup-image-alignment/ | LCP | 68 ms | 44 ms | -35.3% |
| /markup-image-alignment/ | DOMContentLoaded | 62 ms | 36 ms | -42.0% |
| /markup-image-alignment/ | Load | 62 ms | 36 ms | -41.9% |
| /category/block/ | Requests (total) | 9 | 6 | -33.3% |
| /category/block/ | Bytes (total, wire) | 680.1 KB | 666.9 KB | -1.9% |
| /category/block/ | TTFB | 49 ms | 5 ms | -89.1% |
| /category/block/ | FCP | 100 ms | 48 ms | -52.0% |
| /category/block/ | LCP | 100 ms | 48 ms | -52.0% |
| /category/block/ | DOMContentLoaded | 79 ms | 30 ms | -62.4% |
| /category/block/ | Load | 79 ms | 34 ms | -57.1% |
| /media-category-blocks/ | Requests (total) | 31 | 26 | -16.1% |
| /media-category-blocks/ | Bytes (total, wire) | 1.27 MB | 699.7 KB | -45.1% |
| /media-category-blocks/ | TTFB | 34 ms | 4 ms | -88.0% |
| /media-category-blocks/ | FCP | 80 ms | 60 ms | -25.0% |
| /media-category-blocks/ | LCP | 80 ms | 60 ms | -25.0% |
| /media-category-blocks/ | DOMContentLoaded | 81 ms | 31 ms | -61.2% |
| /media-category-blocks/ | Load | 125 ms | 75 ms | -40.1% |

## Profile: throttled

### Overall (median of the 5 page medians)

| Metric | WordPress (dynamic) | Static | Δ% |
|---|---|---|---|
| Requests (total) | 13 | 8 | -38.5% |
| Bytes (total, wire) | 681.9 KB | 666.9 KB | -2.2% |
| TTFB | 38 ms | 6 ms | -83.0% |
| FCP | 900 ms | 948 ms | +5.3% |
| LCP | 1080 ms | 948 ms | -12.2% |
| DOMContentLoaded | 900 ms | 945 ms | +4.9% |
| Load | 3701 ms | 3639 ms | -1.7% |

#### Requests by type (overall)

| Type | WP | Static | Δ% |
|---|---|---|---|
| document | 1 | 1 | 0.0% |
| script | 3 | 1 | -66.7% |
| stylesheet | 2 | 1 | -50.0% |
| image | 6 | 5 | -16.7% |
| media | 0 | 0 | — |

#### Bytes by type (overall)

| Type | WP | Static | Δ% |
|---|---|---|---|
| document | 17.6 KB | 17.5 KB | -0.6% |
| script | 3.2 KB | 5.2 KB | +62.0% |
| stylesheet | 24.5 KB | 24.9 KB | +1.5% |
| image | 636.6 KB | 621.5 KB | -2.4% |
| media | 0 B | 0 B | — |

### Per page (medians)

| Page | Metric | WP | Static | Δ% |
|---|---|---|---|---|
| / | Requests (total) | 9 | 6 | -33.3% |
| / | Bytes (total, wire) | 681.9 KB | 669.2 KB | -1.9% |
| / | TTFB | 71 ms | 7 ms | -90.2% |
| / | FCP | 888 ms | 956 ms | +7.7% |
| / | LCP | 3724 ms | 3684 ms | -1.1% |
| / | DOMContentLoaded | 886 ms | 945 ms | +6.6% |
| / | Load | 3701 ms | 3639 ms | -1.7% |
| /block-gallery/ | Requests (total) | 13 | 9 | -30.8% |
| /block-gallery/ | Bytes (total, wire) | 1.27 MB | 917.0 KB | -27.9% |
| /block-gallery/ | TTFB | 38 ms | 7 ms | -80.8% |
| /block-gallery/ | FCP | 992 ms | 984 ms | -0.8% |
| /block-gallery/ | LCP | 6500 ms | 4548 ms | -30.0% |
| /block-gallery/ | DOMContentLoaded | 989 ms | 989 ms | +0.0% |
| /block-gallery/ | Load | 6659 ms | 4890 ms | -26.6% |
| /markup-image-alignment/ | Requests (total) | 14 | 8 | -42.9% |
| /markup-image-alignment/ | Bytes (total, wire) | 209.9 KB | 116.9 KB | -44.3% |
| /markup-image-alignment/ | TTFB | 32 ms | 6 ms | -81.3% |
| /markup-image-alignment/ | FCP | 800 ms | 684 ms | -14.5% |
| /markup-image-alignment/ | LCP | 800 ms | 684 ms | -14.5% |
| /markup-image-alignment/ | DOMContentLoaded | 797 ms | 673 ms | -15.6% |
| /markup-image-alignment/ | Load | 1350 ms | 901 ms | -33.3% |
| /category/block/ | Requests (total) | 9 | 6 | -33.3% |
| /category/block/ | Bytes (total, wire) | 680.1 KB | 666.9 KB | -1.9% |
| /category/block/ | TTFB | 52 ms | 6 ms | -87.6% |
| /category/block/ | FCP | 900 ms | 948 ms | +5.3% |
| /category/block/ | LCP | 900 ms | 948 ms | +5.3% |
| /category/block/ | DOMContentLoaded | 900 ms | 932 ms | +3.5% |
| /category/block/ | Load | 3700 ms | 3636 ms | -1.7% |
| /media-category-blocks/ | Requests (total) | 27 | 22 | -18.5% |
| /media-category-blocks/ | Bytes (total, wire) | 1.19 MB | 631.0 KB | -46.8% |
| /media-category-blocks/ | TTFB | 38 ms | 6 ms | -83.2% |
| /media-category-blocks/ | FCP | 1080 ms | 944 ms | -12.6% |
| /media-category-blocks/ | LCP | 1080 ms | 944 ms | -12.6% |
| /media-category-blocks/ | DOMContentLoaded | 1099 ms | 961 ms | -12.5% |
| /media-category-blocks/ | Load | 6244 ms | 4158 ms | -33.4% |

# Benchmark results — dynamic WordPress vs static site

Generated: 2026-11-25T14:40:23.077Z

Method: 1 warmup + 5 measured runs per target × page × profile, each run in a fresh
browser context (cold cache). Values are medians. Bytes = `encodedDataLength` (wire
size, gzip on both sides). Δ% = static vs WP (negative = static is smaller/faster).

## Profile: unthrottled

### Overall (median of the 4 page medians)

| Metric | WordPress (dynamic) | Static | Δ% |
|---|---|---|---|
| Requests (total) | 11 | 8 | -31.8% |
| Bytes (total, wire) | 681.0 KB | 667.5 KB | -2.0% |
| TTFB | 45 ms | 6 ms | -86.2% |
| FCP | 82 ms | 50 ms | -39.0% |
| LCP | 82 ms | 50 ms | -39.0% |
| DOMContentLoaded | 72 ms | 33 ms | -54.2% |
| Load | 73 ms | 36 ms | -50.4% |

#### Requests by type (overall)

| Type | WP | Static | Δ% |
|---|---|---|---|
| document | 1 | 1 | 0.0% |
| script | 3 | 1 | -66.7% |
| stylesheet | 2 | 1 | -50.0% |
| image | 5 | 5 | -10.0% |

#### Bytes by type (overall)

| Type | WP | Static | Δ% |
|---|---|---|---|
| document | 16.6 KB | 16.4 KB | -1.7% |
| script | 3.2 KB | 5.2 KB | +59.3% |
| stylesheet | 24.5 KB | 24.8 KB | +1.2% |
| image | 636.6 KB | 621.2 KB | -2.4% |

### Per page (medians)

| Page | Metric | WP | Static | Δ% |
|---|---|---|---|---|
| / | Requests (total) | 9 | 6 | -33.3% |
| / | Bytes (total, wire) | 681.9 KB | 668.7 KB | -1.9% |
| / | TTFB | 55 ms | 6 ms | -88.5% |
| / | FCP | 88 ms | 48 ms | -45.5% |
| / | LCP | 88 ms | 48 ms | -45.5% |
| / | DOMContentLoaded | 83 ms | 35 ms | -57.2% |
| / | Load | 83 ms | 37 ms | -55.6% |
| /block-gallery/ | Requests (total) | 22 | 18 | -18.2% |
| /block-gallery/ | Bytes (total, wire) | 1.86 MB | 1.23 MB | -33.9% |
| /block-gallery/ | TTFB | 38 ms | 6 ms | -83.9% |
| /block-gallery/ | FCP | 80 ms | 52 ms | -35.0% |
| /block-gallery/ | LCP | 80 ms | 52 ms | -35.0% |
| /block-gallery/ | DOMContentLoaded | 74 ms | 31 ms | -58.3% |
| /block-gallery/ | Load | 75 ms | 36 ms | -51.8% |
| /markup-image-alignment/ | Requests (total) | 13 | 9 | -30.8% |
| /markup-image-alignment/ | Bytes (total, wire) | 209.9 KB | 119.7 KB | -43.0% |
| /markup-image-alignment/ | TTFB | 34 ms | 6 ms | -81.8% |
| /markup-image-alignment/ | FCP | 72 ms | 44 ms | -38.9% |
| /markup-image-alignment/ | LCP | 72 ms | 44 ms | -38.9% |
| /markup-image-alignment/ | DOMContentLoaded | 71 ms | 36 ms | -48.9% |
| /markup-image-alignment/ | Load | 71 ms | 36 ms | -49.0% |
| /category/block/ | Requests (total) | 9 | 6 | -33.3% |
| /category/block/ | Bytes (total, wire) | 680.1 KB | 666.4 KB | -2.0% |
| /category/block/ | TTFB | 52 ms | 6 ms | -87.9% |
| /category/block/ | FCP | 84 ms | 52 ms | -38.1% |
| /category/block/ | LCP | 84 ms | 52 ms | -38.1% |
| /category/block/ | DOMContentLoaded | 66 ms | 30 ms | -54.6% |
| /category/block/ | Load | 70 ms | 34 ms | -51.4% |

## Profile: throttled

### Overall (median of the 4 page medians)

| Metric | WordPress (dynamic) | Static | Δ% |
|---|---|---|---|
| Requests (total) | 11 | 7 | -36.4% |
| Bytes (total, wire) | 681.0 KB | 667.5 KB | -2.0% |
| TTFB | 43 ms | 6 ms | -86.7% |
| FCP | 898 ms | 950 ms | +5.8% |
| LCP | 2310 ms | 2304 ms | -0.3% |
| DOMContentLoaded | 899 ms | 938 ms | +4.4% |
| Load | 3698 ms | 3628 ms | -1.9% |

#### Requests by type (overall)

| Type | WP | Static | Δ% |
|---|---|---|---|
| document | 1 | 1 | 0.0% |
| script | 3 | 1 | -66.7% |
| stylesheet | 2 | 1 | -50.0% |
| image | 5 | 4 | -11.1% |

#### Bytes by type (overall)

| Type | WP | Static | Δ% |
|---|---|---|---|
| document | 16.6 KB | 16.4 KB | -1.7% |
| script | 3.2 KB | 5.2 KB | +59.3% |
| stylesheet | 24.5 KB | 24.8 KB | +1.2% |
| image | 636.6 KB | 621.2 KB | -2.4% |

### Per page (medians)

| Page | Metric | WP | Static | Δ% |
|---|---|---|---|---|
| / | Requests (total) | 9 | 6 | -33.3% |
| / | Bytes (total, wire) | 681.9 KB | 668.7 KB | -1.9% |
| / | TTFB | 53 ms | 5 ms | -89.8% |
| / | FCP | 900 ms | 956 ms | +6.2% |
| / | LCP | 3724 ms | 3656 ms | -1.8% |
| / | DOMContentLoaded | 896 ms | 940 ms | +4.9% |
| / | Load | 3698 ms | 3626 ms | -2.0% |
| /block-gallery/ | Requests (total) | 13 | 9 | -30.8% |
| /block-gallery/ | Bytes (total, wire) | 1.27 MB | 916.2 KB | -28.0% |
| /block-gallery/ | TTFB | 39 ms | 6 ms | -85.3% |
| /block-gallery/ | FCP | 976 ms | 948 ms | -2.9% |
| /block-gallery/ | LCP | 6492 ms | 4536 ms | -30.1% |
| /block-gallery/ | DOMContentLoaded | 975 ms | 949 ms | -2.6% |
| /block-gallery/ | Load | 6656 ms | 4879 ms | -26.7% |
| /markup-image-alignment/ | Requests (total) | 14 | 8 | -42.9% |
| /markup-image-alignment/ | Bytes (total, wire) | 209.9 KB | 116.3 KB | -44.6% |
| /markup-image-alignment/ | TTFB | 32 ms | 6 ms | -82.1% |
| /markup-image-alignment/ | FCP | 792 ms | 676 ms | -14.6% |
| /markup-image-alignment/ | LCP | 792 ms | 676 ms | -14.6% |
| /markup-image-alignment/ | DOMContentLoaded | 786 ms | 659 ms | -16.1% |
| /markup-image-alignment/ | Load | 1344 ms | 896 ms | -33.3% |
| /category/block/ | Requests (total) | 9 | 6 | -33.3% |
| /category/block/ | Bytes (total, wire) | 680.1 KB | 666.4 KB | -2.0% |
| /category/block/ | TTFB | 47 ms | 6 ms | -87.2% |
| /category/block/ | FCP | 896 ms | 952 ms | +6.3% |
| /category/block/ | LCP | 896 ms | 952 ms | +6.3% |
| /category/block/ | DOMContentLoaded | 902 ms | 937 ms | +3.9% |
| /category/block/ | Load | 3698 ms | 3630 ms | -1.8% |

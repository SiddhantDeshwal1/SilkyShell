#!/usr/bin/env python3
import sys, urllib.parse, urllib.request, io, json, os, colorsys

CACHE_FILE = "/tmp/quickshell-color-cache.json"

def get_cached(url):
    try:
        if os.path.exists(CACHE_FILE):
            with open(CACHE_FILE, 'r') as f:
                cache = json.load(f)
                return cache.get(url)
    except Exception:
        pass
    return None

def save_cache(url, colors):
    try:
        cache = {}
        if os.path.exists(CACHE_FILE):
            with open(CACHE_FILE, 'r') as f:
                cache = json.load(f)
        cache[url] = colors
        # Keep cache bounded to 200 items
        if len(cache) > 200:
            cache = dict(list(cache.items())[-100:])
        with open(CACHE_FILE, 'w') as f:
            json.dump(cache, f)
    except Exception:
        pass

def extract_vibrant_palette(img):
    # Downscale for rapid pixel analysis
    small = img.resize((64, 64), 0) # 0 is Resampling.NEAREST/BOX
    rgb_img = small.convert('RGB')
    width, height = rgb_img.size
    
    # Bucket pixels into 24 hue bins (15 deg each)
    hue_bins = [[] for _ in range(24)]
    scored_pixels = []
    
    for y in range(height):
        for x in range(width):
            r, g, b = rgb_img.getpixel((x, y))
            h, l, s = colorsys.rgb_to_hls(r / 255.0, g / 255.0, b / 255.0)
            
            # Skip extreme darks and extreme highlights
            if l < 0.10 or l > 0.92:
                continue
            
            # Vibrancy score prioritizing rich saturation and balanced lightness
            l_score = max(0.2, 1.0 - abs(l - 0.55) * 1.5)
            score = (s ** 1.3) * l_score
            bin_idx = int(h * 24) % 24
            hue_bins[bin_idx].append((score, h, l, s))
            scored_pixels.append((score, h, l, s))
    
    if not scored_pixels:
        return ["#67e8f9", "#818cf8", "#f472b6"]
    
    bin_scores = [(sum(p[0] for p in b), idx) for idx, b in enumerate(hue_bins) if b]
    bin_scores.sort(key=lambda x: x[0], reverse=True)
    
    if not bin_scores or bin_scores[0][0] < 0.05:
        # Monochrome / low-saturation art fallback (stylish luminous cyan/violet/rose)
        return ["#67e8f9", "#a5b4fc", "#f472b6"]
    
    top_bin = hue_bins[bin_scores[0][1]]
    top_bin.sort(key=lambda x: x[0], reverse=True)
    _, top_h, top_l, top_s = top_bin[0]
    
    # Check for a distinct secondary hue bin (at least 30 deg away)
    second_h = None
    top_bin_idx = bin_scores[0][1]
    for b_score, b_idx in bin_scores[1:]:
        dist = abs(b_idx - top_bin_idx)
        dist = min(dist, 24 - dist)
        if dist >= 2 and b_score > bin_scores[0][0] * 0.25:
            sec_bin = hue_bins[b_idx]
            sec_bin.sort(key=lambda x: x[0], reverse=True)
            second_h = sec_bin[0][1]
            break
            
    # Guarantee vivid saturation and high-contrast lightness on dark glass
    sat1 = max(0.70, min(0.95, top_s * 1.3))
    lit1 = max(0.55, min(0.72, top_l if top_l >= 0.5 else 0.52 + top_l * 0.25))
    
    r1, g1, b1 = colorsys.hls_to_rgb(top_h, lit1, sat1)
    
    if second_h is not None:
        h2 = second_h
    else:
        h2 = (top_h + 22.0 / 360.0) % 1.0
    r2, g2, b2 = colorsys.hls_to_rgb(h2, max(0.55, min(0.72, lit1 * 0.96)), max(0.70, sat1))
    
    h3 = (top_h - 22.0 / 360.0) % 1.0
    r3, g3, b3 = colorsys.hls_to_rgb(h3, max(0.58, min(0.75, lit1 * 1.05)), min(1.0, sat1 * 1.05))
    
    c1 = f"#{int(r1*255):02x}{int(g1*255):02x}{int(b1*255):02x}"
    c2 = f"#{int(r2*255):02x}{int(g2*255):02x}{int(b2*255):02x}"
    c3 = f"#{int(r3*255):02x}{int(g3*255):02x}{int(b3*255):02x}"
    return [c1, c2, c3]

def get_colors(url):
    if not url:
        return "#d79921 #cba6f7 #89b4fa"
        
    cached = get_cached(url)
    if cached:
        return cached
        
    try:
        from PIL import Image
        if url.startswith("file://"):
            parsed = urllib.parse.urlparse(url)
            path = urllib.parse.unquote(parsed.path)
            img = Image.open(path)
        elif url.startswith("http://") or url.startswith("https://"):
            req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
            data = urllib.request.urlopen(req, timeout=1.5).read()
            img = Image.open(io.BytesIO(data))
        else:
            img = Image.open(url)
            
        palette = extract_vibrant_palette(img)
        result = " ".join(palette)
        save_cache(url, result)
        return result
    except Exception:
        return "#d79921 #cba6f7 #89b4fa"

if __name__ == "__main__":
    raw_url = sys.argv[1].strip() if len(sys.argv) > 1 else ""
    print(get_colors(raw_url))

from pathlib import Path
import re

path = Path(__file__).with_name("PROJECT_OVERVIEW.html")
src = path.read_text(encoding="utf-8")
styles = re.search(r"<style>(.*?)</style>", src, re.S).group(1)
header = re.search(r'<header class="hero">.*?</header>', src, re.S).group(0)
footer = re.search(r"<footer>.*?</footer>", src, re.S).group(0)
main_inner = re.search(r"<main>(.*)</main>", src, re.S).group(1).strip()
chunks = re.split(r"(?=\n    <h2>)", "\n    " + main_inner)
chunks = [c.strip() for c in chunks if c.strip()]
if len(chunks) != 10:
    raise SystemExit(f"expected 10 sections, got {len(chunks)}")

deck_css = """
    body.pres-deck {
      overflow-x: hidden;
      margin: 0;
      min-height: 100vh;
      padding: clamp(1rem, 3vw, 2rem) clamp(0.75rem, 3vw, 1.5rem) 4.75rem;
    }
    .pres-toplink {
      position: fixed;
      top: clamp(0.5rem, 1.5vw, 0.75rem);
      right: clamp(0.5rem, 1.5vw, 0.75rem);
      z-index: 100;
      font-size: 0.82rem;
      font-weight: 600;
      color: var(--brand-dark);
      background: rgba(255, 255, 255, 0.95);
      padding: 0.35rem 0.75rem;
      border-radius: 10px;
      border: 1px solid rgba(23, 114, 69, 0.2);
      text-decoration: none;
      box-shadow: var(--shadow-sm);
    }
    .pres-toplink:hover { text-decoration: underline; }
    .deck { position: relative; min-height: 100vh; }
    section.slide {
      display: none;
      min-height: 100vh;
      padding: clamp(1rem, 3vw, 2rem) clamp(0.75rem, 3vw, 1.5rem) 4.75rem;
      overflow-y: auto;
      -webkit-overflow-scrolling: touch;
      box-sizing: border-box;
    }
    section.slide.active { display: block; }
    section.slide--title {
      display: none;
      align-items: center;
      justify-content: center;
    }
    section.slide--title.active { display: flex; }
    section.slide .page { max-width: 52rem; margin: 0 auto; width: 100%; }
    section.slide--title .page {
      display: flex;
      justify-content: center;
      align-items: center;
    }
    section.slide--title .hero { width: 100%; }
    .pres-nav {
      position: fixed;
      bottom: 0;
      left: 0;
      right: 0;
      z-index: 99;
      display: flex;
      flex-wrap: wrap;
      align-items: center;
      justify-content: center;
      gap: 0.5rem 1rem;
      padding: 0.6rem 1rem;
      background: rgba(255, 255, 255, 0.94);
      backdrop-filter: blur(14px);
      -webkit-backdrop-filter: blur(14px);
      border-top: 1px solid var(--border);
      box-shadow: 0 -4px 20px rgba(15, 77, 46, 0.06);
      font-size: 0.88rem;
      color: var(--muted);
    }
    .pres-nav button {
      font: inherit;
      cursor: pointer;
      padding: 0.45rem 1rem;
      border-radius: 10px;
      border: 1px solid rgba(23, 114, 69, 0.35);
      background: #fff;
      color: var(--brand-dark);
      font-weight: 600;
    }
    .pres-nav button:hover { background: #f0fdf4; }
    .pres-nav button:disabled { opacity: 0.45; cursor: not-allowed; }
    .pres-nav kbd {
      font-size: 0.75rem;
      padding: 0.1em 0.35em;
      border-radius: 4px;
      border: 1px solid var(--border);
      background: #f8fafc;
    }
    @media print {
      body.pres-deck { padding: 0; overflow: visible; }
      .pres-nav, .pres-toplink { display: none !important; }
      section.slide {
        display: block !important;
        page-break-after: always;
        min-height: auto;
        overflow: visible;
        padding: 1rem;
      }
      section.slide:last-child { page-break-after: auto; }
    }
"""

slides_html = []
slides_html.append(
    f"""    <section class="slide slide--title active" id="slide-0" tabindex="-1" aria-label="Title">
      <div class="page">
        {header}
      </div>
    </section>"""
)
for idx, ch in enumerate(chunks[:-1], start=1):
    slides_html.append(
        f"""    <section class="slide" id="slide-{idx}" tabindex="-1">
      <div class="page">
        <main>
{ch}
        </main>
      </div>
    </section>"""
    )
last = chunks[-1]
slides_html.append(
    f"""    <section class="slide" id="slide-10" tabindex="-1">
      <div class="page">
        <main>
{last}
        </main>
        {footer}
      </div>
    </section>"""
)

body = f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="description" content="U-Panel KIU slide deck matching project overview styling.">
  <title>U-Panel · KIU — Presentation</title>
  <style>
{styles}
{deck_css}
  </style>
</head>
<body class="pres-deck">
  <a class="pres-toplink" href="PROJECT_OVERVIEW.html">Full document</a>
  <div class="deck" id="deck">
"""
body += "\n".join(slides_html)
body += """
  </div>
  <nav class="pres-nav" aria-label="Slide navigation">
    <button type="button" id="pres-prev" aria-label="Previous slide">Previous</button>
    <button type="button" id="pres-next" aria-label="Next slide">Next</button>
    <span id="pres-counter" aria-live="polite"></span>
    <span><kbd>←</kbd> <kbd>→</kbd> or <kbd>Space</kbd></span>
  </nav>
  <script>
(function () {
  var slides = Array.prototype.slice.call(document.querySelectorAll("section.slide"));
  var i = 0;
  var c = document.getElementById("pres-counter");
  var prev = document.getElementById("pres-prev");
  var next = document.getElementById("pres-next");
  function show(n) {
    i = Math.max(0, Math.min(slides.length - 1, n));
    slides.forEach(function (s, j) { s.classList.toggle("active", j === i); });
    if (c) c.textContent = (i + 1) + " / " + slides.length;
    if (prev) prev.disabled = i === 0;
    if (next) next.disabled = i === slides.length - 1;
    slides[i].focus({ preventScroll: true });
  }
  function go(d) { show(i + d); }
  if (prev) prev.addEventListener("click", function () { go(-1); });
  if (next) next.addEventListener("click", function () { go(1); });
  document.addEventListener("keydown", function (e) {
    var tag = e.target && e.target.tagName;
    if (tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT" || e.target.isContentEditable) return;
    if (e.key === " " && (tag === "BUTTON" || tag === "A")) return;
    if (e.key === "ArrowRight" || e.key === "PageDown" || e.key === " ") {
      e.preventDefault();
      go(1);
    } else if (e.key === "ArrowLeft" || e.key === "PageUp") {
      e.preventDefault();
      go(-1);
    } else if (e.key === "Home") { e.preventDefault(); show(0); }
    else if (e.key === "End") { e.preventDefault(); show(slides.length - 1); }
  });
  show(0);
})();
  </script>
</body>
</html>
"""

out = Path(__file__).with_name("PROJECT_OVERVIEW_PRESENTATION.html")
out.write_text(body, encoding="utf-8")
print("Wrote", out.name, "with", len(slides_html), "slides")

// Super Screenshot website: drag-to-capture hero, Quick Access card, modes tabs, copy buttons.
(() => {
  const $ = (s, r = document) => r.querySelector(s);
  const $$ = (s, r = document) => [...r.querySelectorAll(s)];
  const reduced = matchMedia('(prefers-reduced-motion: reduce)');
  const clamp = (v, lo, hi) => Math.min(Math.max(v, lo), hi);
  const place = (el, x, y) => { el.style.transform = `translate(${x}px, ${y}px)`; };
  const spring = CSS.supports('transition-timing-function', 'linear(0, 1)')
    ? getComputedStyle(document.documentElement).getPropertyValue('--spring').trim()
    : 'cubic-bezier(.3, 1.35, .5, 1)';

  /* Copy buttons */
  $$('[data-copy]').forEach((btn) => {
    btn.setAttribute('aria-live', 'polite');
    btn.addEventListener('click', async () => {
      const code = document.getElementById(btn.dataset.copy);
      try {
        await navigator.clipboard.writeText(code.textContent.trim());
      } catch {
        getSelection().selectAllChildren(code);
        document.execCommand('copy');
      }
      btn.textContent = 'Copied';
      clearTimeout(btn.reset);
      btn.reset = setTimeout(() => { btn.textContent = 'Copy'; }, 1600);
    });
  });

  /* Capture stage */
  const stage = $('#stage');
  const nav = $('.nav');
  const cap = $('.cap', stage);
  const [xy, sel, wh, flash] = ['.cap-xy', '.cap-sel', '.cap-wh', '.cap-flash'].map((s) => $(s, cap));
  const qa = $('#qa');
  const tryBtn = $('#try');
  const NO_CAPTURE = 'a, button, input, textarea, select, label, [data-nocapture]';
  const MIN = 6;
  let drag = null;
  let demo = null;

  const onSurface = (t) => t instanceof Element && (stage.contains(t) || nav.contains(t)) && !t.closest(NO_CAPTURE);
  const point = (e) => {
    const r = stage.getBoundingClientRect();
    return { x: Math.round(clamp(e.clientX - r.left, 0, r.width)), y: Math.round(clamp(e.clientY - r.top, 0, r.height)) };
  };

  // "X, Y" pill 14 px below-right of the pointer, flipped at the edges (OverlayPanel.drawCoordinates).
  document.addEventListener('pointermove', (e) => {
    if (drag || demo || e.pointerType !== 'mouse') return;
    const on = onSurface(e.target);
    stage.classList.toggle('is-hover', on);
    if (!on) return;
    const p = point(e);
    xy.textContent = `${p.x}, ${p.y}`;
    const w = xy.offsetWidth;
    const h = xy.offsetHeight;
    place(xy, p.x + 14 + w > stage.clientWidth - 4 ? p.x - 14 - w : p.x + 14, p.y + 14 + h > stage.clientHeight - 4 ? p.y - 14 - h : p.y + 14);
  });
  document.addEventListener('pointerout', (e) => { if (!e.relatedTarget) stage.classList.remove('is-hover'); });
  addEventListener('scroll', () => stage.classList.remove('is-hover'), { passive: true });

  // Selection plus the "W × H" pill just outside the corner being dragged (SelectionGeometry.badgeFrame).
  function draw(r, cx, cy) {
    sel.style.width = `${r.w}px`;
    sel.style.height = `${r.h}px`;
    place(sel, r.x, r.y);
    wh.textContent = `${r.w} × ${r.h}`;
    const W = stage.clientWidth;
    const H = stage.clientHeight;
    const w = wh.offsetWidth;
    const h = wh.offsetHeight;
    let x = cx >= r.x + r.w / 2 ? cx + 12 : cx - 12 - w;
    let y = cy >= r.y + r.h / 2 ? cy + 12 : cy - 12 - h;
    if (x < 4) x = cx + 12; else if (x + w > W - 4) x = cx - 12 - w;
    if (y < 4) y = cy + 12; else if (y + h > H - 4) y = cy - 12 - h;
    place(wh, clamp(x, 4, W - w - 4), clamp(y, 4, H - h - 4));
  }

  function stop() {
    if (drag) { try { stage.releasePointerCapture(drag.id); } catch { /* already released */ } }
    drag = null;
    if (demo) { cancelAnimationFrame(demo.raf); clearTimeout(demo.timer); demo = null; }
    stage.classList.remove('is-sel');
  }

  document.addEventListener('pointerdown', (e) => {
    if (e.button !== 0 || drag || demo || !onSurface(e.target)) return;
    // Touch and pen start only on the empty space, so the copy below stays scrollable.
    if (e.pointerType !== 'mouse' && !e.target.closest('.pad')) return;
    const p = point(e);
    drag = { id: e.pointerId, x: p.x, y: p.y, active: false, r: null };
    if (e.pointerType === 'mouse') e.preventDefault();
    try { stage.setPointerCapture(e.pointerId); } catch { /* pointer already gone */ }
  });

  stage.addEventListener('pointermove', (e) => {
    if (!drag || e.pointerId !== drag.id) return;
    const p = point(e);
    if (!drag.active) {
      if (Math.hypot(p.x - drag.x, p.y - drag.y) < 4) return;
      drag.active = true;
      stage.classList.remove('is-hover');
      stage.classList.add('is-sel');
    }
    drag.r = { x: Math.min(p.x, drag.x), y: Math.min(p.y, drag.y), w: Math.abs(p.x - drag.x), h: Math.abs(p.y - drag.y) };
    draw(drag.r, p.x, p.y);
  });

  stage.addEventListener('pointerup', (e) => {
    if (!drag || e.pointerId !== drag.id) return;
    const { active, r } = drag;
    stop();
    if (active && r.w >= MIN && r.h >= MIN) shoot(r);
  });
  stage.addEventListener('pointercancel', () => { if (drag) stop(); });
  document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape' && (drag || demo)) { e.preventDefault(); stop(); }
  });

  /* Shutter, then the Quick Access card with a real thumbnail of the region */
  function shoot(r) {
    stage.classList.remove('is-sel');
    const shot = snapshot(r);
    if (reduced.matches) { show(shot, r); return; }
    flash.style.width = `${r.w}px`;
    flash.style.height = `${r.h}px`;
    place(flash, r.x, r.y);
    flash.animate([{ opacity: 1 }, { opacity: 0 }], { duration: 120, easing: 'ease-out' });
    setTimeout(() => show(shot, r), 120);
  }

  const MAX_W = 248;
  const MAX_H = 156;
  function snapshot(r) {
    const W = stage.offsetWidth;
    const H = stage.offsetHeight;
    const k = Math.min(MAX_W / r.w, MAX_H / r.h, 2);
    const src = document.createElement('div');
    src.className = 'qa-src';
    src.style.width = `${W}px`;
    src.style.height = `${H}px`;
    const s = stage.cloneNode(true);
    s.querySelector('.cap').remove();
    s.classList.remove('is-hover', 'is-sel');
    s.style.height = `${H}px`;
    src.append(s, nav.cloneNode(true));
    src.querySelectorAll('[id]').forEach((n) => n.removeAttribute('id'));
    src.setAttribute('aria-hidden', 'true');
    src.inert = true;
    src.style.transform = `scale(${k}) translate(${-r.x}px, ${-r.y}px)`;
    return { src, w: Math.max(1, Math.round(r.w * k)), h: Math.max(1, Math.round(r.h * k)) };
  }

  let card = null;
  let timer = 0;
  const arm = () => { clearTimeout(timer); timer = setTimeout(() => dismiss(), 4000); };

  function show(shot, r) {
    dismiss(true);
    card = document.createElement('div');
    card.className = 'qa-card';
    card.style.setProperty('--w', `${Math.max(shot.w, 208) + 12}px`);
    card.innerHTML = `<div class="qa-thumb" style="height:${shot.h}px"><div class="qa-shot" style="width:${shot.w}px"></div></div>`
      + `<div class="qa-foot"><span>Copied · ${r.w} × ${r.h}</span><button class="qa-x" type="button" aria-label="Dismiss capture"><svg class="ic" aria-hidden="true"><use href="#i-x"/></svg></button></div>`;
    $('.qa-shot', card).append(shot.src);
    $('.qa-x', card).addEventListener('click', () => dismiss());
    card.addEventListener('pointerenter', () => clearTimeout(timer));
    card.addEventListener('pointerleave', arm);
    card.addEventListener('focusin', () => clearTimeout(timer));
    card.addEventListener('focusout', arm);
    qa.append(card);
    if (!reduced.matches) {
      card.animate([{ transform: 'translateX(-69px)' }, { transform: 'none' }], { duration: 440, easing: spring });
      card.animate([{ opacity: 0 }, { opacity: 1 }], { duration: 250, easing: 'ease-out' });
    }
    arm();
  }

  function dismiss(instant) {
    clearTimeout(timer);
    const c = card;
    card = null;
    if (!c) return;
    if (c.contains(document.activeElement)) tryBtn.focus();
    if (instant || reduced.matches) { c.remove(); return; }
    c.animate([{ transform: 'none', opacity: 1 }, { transform: 'translateX(-69px)', opacity: 0 }], { duration: 200, easing: 'ease-in', fill: 'forwards' })
      .onfinish = () => c.remove();
  }

  /* Keyboard alternative: draw a selection over the headline */
  tryBtn.addEventListener('click', () => {
    if (drag || demo) return;
    const range = document.createRange();
    range.selectNodeContents($('.hero h1'));
    const t = range.getBoundingClientRect();
    const s = stage.getBoundingClientRect();
    const x = Math.round(clamp(t.left - s.left - 16, 0, s.width));
    const y = Math.round(clamp(t.top - s.top - 12, 0, s.height));
    const r = { x, y, w: Math.round(Math.min(t.width + 32, s.width - x)), h: Math.round(Math.min(t.height + 24, s.height - y)) };
    dismiss(true);
    stage.classList.remove('is-hover');
    stage.classList.add('is-sel');
    demo = { raf: 0, timer: 0 };
    const finish = () => { demo.timer = setTimeout(() => { demo = null; shoot(r); }, reduced.matches ? 500 : 260); };
    if (reduced.matches) { draw(r, r.x + r.w, r.y + r.h); finish(); return; }
    const t0 = performance.now();
    const step = (now) => {
      const p = Math.min((now - t0) / 700, 1);
      const e = 1 - (1 - p) ** 3;
      const cur = { x: r.x, y: r.y, w: Math.max(1, Math.round(r.w * e)), h: Math.max(1, Math.round(r.h * e)) };
      draw(cur, r.x + cur.w, r.y + cur.h);
      if (p < 1) demo.raf = requestAnimationFrame(step); else finish();
    };
    demo.raf = requestAnimationFrame(step);
  });

  /* Modes: a tablist that follows hover, focus and the arrow keys */
  const tabs = $$('.mtab');
  const mstage = $('.mstage');
  const phone = matchMedia('(max-width: 699px)');
  function select(tab, focus) {
    if (focus) tab.focus();
    if (tab.getAttribute('aria-selected') === 'true') return;
    tabs.forEach((t) => {
      const on = t === tab;
      t.setAttribute('aria-selected', String(on));
      t.tabIndex = on ? 0 : -1;
      document.getElementById(t.getAttribute('aria-controls')).hidden = !on;
    });
    mstage.dataset.mode = tab.id.slice(2);
    if (phone.matches) tab.scrollIntoView({ block: 'nearest', inline: 'nearest', behavior: reduced.matches ? 'auto' : 'smooth' });
  }
  tabs.forEach((t, i) => {
    t.addEventListener('click', () => select(t));
    t.addEventListener('pointerenter', (e) => { if (e.pointerType === 'mouse' && !phone.matches) select(t); });
    t.addEventListener('keydown', (e) => {
      const n = tabs.length;
      const to = { ArrowDown: i + 1, ArrowRight: i + 1, ArrowUp: i - 1, ArrowLeft: i - 1, Home: 0, End: n - 1 }[e.key];
      if (to === undefined) return;
      e.preventDefault();
      select(tabs[(to + n) % n], true);
    });
  });
  phone.addEventListener('change', () => $('.mlist').setAttribute('aria-orientation', phone.matches ? 'horizontal' : 'vertical'));
  if (phone.matches) $('.mlist').setAttribute('aria-orientation', 'horizontal');

  // The frame's own size, live.
  const frame = $('.mframe');
  const frameWh = $('.mframe-wh');
  new ResizeObserver(([entry]) => {
    const { width, height } = entry.contentRect;
    frameWh.textContent = `${Math.round(width)} × ${Math.round(height)}`;
  }).observe(frame);

  // Magnifier pixels: the rounded bottom-right corner of the card under the crosshair (15 × 15, centre cell = pointer).
  const N = 15;
  const C = 7;
  const R = 5;
  let px = '';
  for (let row = 0; row < N; row += 1) {
    for (let col = 0; col < N; col += 1) {
      const dr = row - (C - R - 1);
      const dc = col - (C - R - 1);
      const d = dr > 0 && dc > 0 ? Math.hypot(dr, dc) : Math.max(dr, dc);
      let cls = d <= R - 0.6 ? 'k' : d <= R + 0.4 ? 'e' : d <= R + 0.9 ? 'a' : '';
      if (row === C || col === C) cls += ' g';
      if (row === C && col === C) cls = 'x';
      px += `<i class="${cls.trim()}"></i>`;
    }
  }
  $('.loupe-px').innerHTML = px;
})();

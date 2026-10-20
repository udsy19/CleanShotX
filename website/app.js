// Super Screenshot website: header, menus, sliders, carousels, modals, the "How it works" player and copy buttons.
(() => {
  const $ = (s, r = document) => r.querySelector(s);
  const $$ = (s, r = document) => Array.from(r.querySelectorAll(s));
  const reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)');
  const finePointer = window.matchMedia('(hover: hover) and (pointer: fine)');

  /* Sticky header gets a background once the page scrolls */
  const header = $('.app-header');
  let ticking = false;
  const onScroll = () => {
    if (ticking) return;
    ticking = true;
    requestAnimationFrame(() => { header.classList.toggle('scrolled', window.scrollY > 12); ticking = false; });
  };
  window.addEventListener('scroll', onScroll, { passive: true });
  onScroll();

  /* Header dropdowns: hover with a mouse, click or keyboard everywhere */
  const drops = $$('.navigation .item.drop');
  const closeDrop = (li, focus) => {
    const btn = $('button', li);
    btn.setAttribute('aria-expanded', 'false');
    $('.dropdown', li).classList.remove('open');
    if (focus) btn.focus();
  };
  const openDrop = (li) => {
    drops.forEach((o) => o !== li && closeDrop(o));
    $('button', li).setAttribute('aria-expanded', 'true');
    $('.dropdown', li).classList.add('open');
  };
  drops.forEach((li) => {
    const btn = $('button', li);
    btn.addEventListener('click', () => (btn.getAttribute('aria-expanded') === 'true' ? closeDrop(li) : openDrop(li)));
    li.addEventListener('mouseenter', () => finePointer.matches && openDrop(li));
    li.addEventListener('mouseleave', () => finePointer.matches && closeDrop(li));
    li.addEventListener('focusout', (e) => { if (!li.contains(e.relatedTarget)) closeDrop(li); });
    li.addEventListener('keydown', (e) => {
      if (e.key === 'Escape') { closeDrop(li, true); return; }
      if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
        const links = $$('.dropdown a', li);
        if (!$('.dropdown', li).classList.contains('open')) openDrop(li);
        const i = links.indexOf(document.activeElement);
        const next = e.key === 'ArrowDown' ? (i + 1) % links.length : (i <= 0 ? links.length - 1 : i - 1);
        links[next].focus();
        e.preventDefault();
      }
    });
  });
  document.addEventListener('click', (e) => drops.forEach((li) => { if (!li.contains(e.target)) closeDrop(li); }));

  /* Focus trap shared by the mobile menu and the dialogs */
  const focusables = (root) => $$('a[href], button:not([disabled]), input, [tabindex]:not([tabindex="-1"])', root).filter((el) => el.offsetParent !== null || el === document.activeElement);
  const trap = (root, e) => {
    if (e.key !== 'Tab') return;
    const f = focusables(root);
    if (!f.length) return;
    const first = f[0], last = f[f.length - 1];
    if (e.shiftKey && document.activeElement === first) { last.focus(); e.preventDefault(); }
    else if (!e.shiftKey && document.activeElement === last) { first.focus(); e.preventDefault(); }
  };

  /* Mobile menu */
  const trigger = $('.m-header .trigger');
  const menu = $('#m-menu');
  const closeMenu = (restore = true) => {
    if (menu.hidden) return;
    menu.hidden = true;
    trigger.setAttribute('aria-expanded', 'false');
    document.body.classList.remove('locked');
    if (restore) trigger.focus();
  };
  trigger.addEventListener('click', () => {
    menu.hidden = false;
    trigger.setAttribute('aria-expanded', 'true');
    document.body.classList.add('locked');
    $('.close', menu).focus();
  });
  $('.close', menu).addEventListener('click', () => closeMenu());
  menu.addEventListener('keydown', (e) => { if (e.key === 'Escape') closeMenu(); trap(menu, e); });
  $$('a', menu).forEach((a) => a.addEventListener('click', () => closeMenu(false)));
  window.matchMedia('(width > 920px)').addEventListener('change', (m) => m.matches && closeMenu(false));

  /* Hero highlights: one card at a time, sliding left or right, looping */
  const facts = $$('.facts .fact');
  let factIndex = 0;
  const showFact = (dir) => {
    const from = facts[factIndex];
    factIndex = (factIndex + dir + facts.length) % facts.length;
    const to = facts[factIndex];
    facts.forEach((f) => f !== from && f !== to && f.classList.remove('current', 'prev', 'leaving'));
    // Place the incoming card on the side it enters from, without animating that jump.
    to.style.transition = 'none';
    to.classList.remove('current', 'leaving');
    to.classList.toggle('prev', dir < 0);
    void to.offsetWidth;
    to.style.transition = '';
    to.classList.remove('prev');
    to.classList.add('current');
    from.classList.remove('current');
    from.classList.add('leaving');
    from.classList.toggle('prev', dir > 0);
    from.addEventListener('transitionend', () => from.classList.remove('leaving'), { once: true });
  };
  $$('[data-fact]').forEach((b) => b.addEventListener('click', () => showFact(Number(b.dataset.fact))));
  // Swipe or drag the card, as Swiper allows on the reference.
  const factsBox = $('.facts');
  let swipe = null;
  factsBox.addEventListener('pointerdown', (e) => { if (!e.target.closest('button')) swipe = { x: e.clientX, y: e.clientY }; });
  factsBox.addEventListener('pointerup', (e) => {
    if (!swipe) return;
    const dx = e.clientX - swipe.x, dy = e.clientY - swipe.y;
    swipe = null;
    if (Math.abs(dx) > 40 && Math.abs(dx) > Math.abs(dy)) showFact(dx < 0 ? 1 : -1);
  });
  factsBox.addEventListener('pointercancel', () => { swipe = null; });

  /* Carousels: slide to slide in 300 ms with CSS "ease" (as Swiper does), drag with a mouse, scroll natively on touch and trackpads */
  // CSS "ease", cubic-bezier(.25, .1, .25, 1): solve x(a) = t by Newton's method, return y(a).
  const ease = (t) => {
    let a = t;
    for (let i = 0; i < 6; i++) {
      const x = .75 * a * (1 - a) ** 2 + .75 * a * a * (1 - a) + a ** 3 - t;
      const dx = .75 * (1 - a) ** 2 + 2.25 * a * a;
      if (Math.abs(x) < 1e-4) break;
      a -= x / dx;
    }
    return .3 * a * (1 - a) ** 2 + 3 * a * a * (1 - a) + a ** 3;
  };
  $$('[data-carousel]').forEach((c) => {
    const vp = $('.viewport', c);
    const slides = $$('.slide', vp);
    const [prev, next] = $$('.navigation .nav-btn', c);
    const max = () => vp.scrollWidth - vp.clientWidth;
    const stops = () => {
      const base = slides[0].getBoundingClientRect().left;
      return slides.map((s) => Math.min(max(), Math.round(s.getBoundingClientRect().left - base)));
    };
    const nearest = () => {
      const st = stops();
      return st.reduce((best, x, i) => (Math.abs(x - vp.scrollLeft) < Math.abs(st[best] - vp.scrollLeft) ? i : best), 0);
    };
    let anim = 0;
    const scrollToX = (x) => {
      cancelAnimationFrame(anim);
      const from = vp.scrollLeft, to = Math.max(0, Math.min(max(), x));
      if (reduceMotion.matches || Math.abs(to - from) < 1) { vp.scrollLeft = to; return; }
      vp.style.scrollSnapType = 'none';
      const t0 = performance.now();
      const tick = (now) => {
        const p = Math.min(1, (now - t0) / 300);
        vp.scrollLeft = from + (to - from) * ease(p);
        if (p < 1) anim = requestAnimationFrame(tick);
        else vp.style.scrollSnapType = '';
      };
      anim = requestAnimationFrame(tick);
    };
    const go = (dir) => {
      const st = stops();
      let i = nearest();
      if (dir > 0) while (i < st.length - 1 && st[i] <= vp.scrollLeft + 1) i++;
      else while (i > 0 && st[i] >= vp.scrollLeft - 1) i--;
      scrollToX(st[i]);
    };
    const update = () => {
      prev.disabled = vp.scrollLeft <= 2;
      next.disabled = vp.scrollLeft >= max() - 2;
    };
    prev.addEventListener('click', () => go(-1));
    next.addEventListener('click', () => go(1));
    vp.addEventListener('scroll', () => requestAnimationFrame(update), { passive: true });
    vp.addEventListener('keydown', (e) => {
      if (e.key === 'ArrowRight' || e.key === 'ArrowLeft') { go(e.key === 'ArrowRight' ? 1 : -1); e.preventDefault(); }
    });
    // Mouse drag; a quick flick moves one slide, a slow drag settles on the nearest one.
    let drag = null;
    vp.addEventListener('pointerdown', (e) => {
      if (e.pointerType !== 'mouse' || e.button !== 0) return;
      cancelAnimationFrame(anim);
      drag = { x: e.clientX, left: vp.scrollLeft, t: performance.now(), start: nearest(), moved: false };
    });
    vp.addEventListener('pointermove', (e) => {
      if (!drag) return;
      const dx = e.clientX - drag.x;
      if (!drag.moved && Math.abs(dx) > 4) { drag.moved = true; vp.setPointerCapture(e.pointerId); vp.style.scrollSnapType = 'none'; vp.classList.add('dragging'); }
      if (drag.moved) vp.scrollLeft = drag.left - dx;
    });
    const endDrag = (e) => {
      if (!drag) return;
      const d = drag; drag = null;
      vp.classList.remove('dragging');
      if (!d.moved) return;
      const dx = e.clientX - d.x, st = stops();
      const quick = performance.now() - d.t < 300 && Math.abs(dx) > 10;
      const i = quick ? Math.max(0, Math.min(st.length - 1, d.start + (dx < 0 ? 1 : -1))) : nearest();
      scrollToX(st[i]);
    };
    vp.addEventListener('pointerup', endDrag);
    vp.addEventListener('pointercancel', endDrag);
    vp.addEventListener('dragstart', (e) => e.preventDefault());
    window.addEventListener('resize', update);
    update();
  });

  /* Mockups play while at least a quarter is on screen, like the reference's in-view videos */
  const anims = $$('[data-anim]');
  if ('IntersectionObserver' in window) {
    const io = new IntersectionObserver((entries) => entries.forEach((en) => en.target.classList.toggle('on', en.isIntersecting)), { threshold: 0.25 });
    anims.forEach((el) => io.observe(el));
  } else {
    anims.forEach((el) => el.classList.add('on'));
  }

  /* Dialogs */
  let lastFocus = null;
  const openOverlay = (ov, onOpen) => {
    lastFocus = document.activeElement;
    ov.hidden = false;
    document.body.classList.add('locked');
    requestAnimationFrame(() => requestAnimationFrame(() => ov.classList.add('open')));
    $('[data-close]', ov).focus();
    if (onOpen) onOpen();
  };
  const closeOverlay = (ov, onClose) => {
    if (ov.hidden) return;
    ov.classList.remove('open');
    document.body.classList.remove('locked');
    if (onClose) onClose();
    setTimeout(() => { ov.hidden = true; }, reduceMotion.matches ? 0 : 200);
    if (lastFocus) lastFocus.focus();
  };
  const wire = (ov, onOpen, onClose) => {
    ov.addEventListener('click', (e) => { if (e.target === ov || e.target.closest('[data-close]')) closeOverlay(ov, onClose); });
    ov.addEventListener('keydown', (e) => { if (e.key === 'Escape') closeOverlay(ov, onClose); trap(ov, e); });
    return () => openOverlay(ov, onOpen);
  };

  const ossModal = $('#oss-modal');
  const openOss = wire(ossModal);
  $$('[data-open-modal="oss-modal"]').forEach((b) => b.addEventListener('click', openOss));

  /* "How it works" player: four scenes on a 14 second loop */
  const player = $('#player');
  const scenes = $$('.scene', player);
  const dots = $$('.steps i', player);
  const caption = $('.caption', player);
  const bar = $('.controls .bar i', player);
  const time = $('.controls .time', player);
  const pp = $('.controls .pp', player);
  const captions = [
    'Press <kbd>⌥⇧4</kbd> and drag over anything',
    'It waits in Quick Access, ready to use',
    'Mark it up with <kbd>⌘E</kbd>',
    'Drag the card into any app',
  ];
  const SCENE = 3500, TOTAL = SCENE * scenes.length;
  let t0 = 0, elapsed = 0, playing = false, raf = 0, current = -1;
  const fmt = (ms) => `0:${String(Math.floor(ms / 1000)).padStart(2, '0')}`;
  const setScene = (i) => {
    if (i === current) return;
    current = i;
    scenes.forEach((s, k) => s.classList.toggle('on', k === i));
    dots.forEach((d, k) => d.classList.toggle('on', k <= i));
    caption.innerHTML = `<b>${i + 1}</b><span>${captions[i]}</span>`;
  };
  const frame = (now) => {
    elapsed = (now - t0) % TOTAL;
    setScene(Math.floor(elapsed / SCENE));
    bar.style.width = `${(elapsed / TOTAL) * 100}%`;
    time.textContent = `${fmt(elapsed)} / ${fmt(TOTAL)}`;
    if (playing) raf = requestAnimationFrame(frame);
  };
  const play = () => {
    playing = true;
    t0 = performance.now() - elapsed;
    pp.setAttribute('aria-label', 'Pause');
    $('use', pp).setAttribute('href', '#i-pause-f');
    player.classList.remove('paused');
    raf = requestAnimationFrame(frame);
  };
  const pause = () => {
    playing = false;
    cancelAnimationFrame(raf);
    pp.setAttribute('aria-label', 'Play');
    $('use', pp).setAttribute('href', '#i-play-f');
    player.classList.add('paused');
  };
  pp.addEventListener('click', () => (playing ? pause() : play()));
  const openPlayer = wire(player, () => { elapsed = 0; current = -1; play(); }, pause);
  $$('[data-open-player]').forEach((b) => b.addEventListener('click', openPlayer));

  /* Copy the install command */
  const live = document.createElement('p');
  live.className = 'sr-only';
  live.setAttribute('aria-live', 'polite');
  document.body.append(live);
  $$('[data-copy]').forEach((btn) => {
    const label = btn.textContent;
    btn.addEventListener('click', async () => {
      const src = document.getElementById(btn.dataset.copy);
      const text = (src.value ?? src.textContent).trim();
      let ok = false;
      try { await navigator.clipboard.writeText(text); ok = true; } catch {
        const ta = Object.assign(document.createElement('textarea'), { value: text, readOnly: true });
        ta.style.cssText = 'position:fixed;opacity:0;pointer-events:none';
        document.body.append(ta);
        ta.select();
        try { ok = document.execCommand('copy'); } catch { ok = false; }
        ta.remove();
        btn.focus();
      }
      btn.textContent = ok ? 'Copied' : 'Select and copy';
      live.textContent = ok ? 'Install command copied to the clipboard' : '';
      clearTimeout(btn._t);
      btn._t = setTimeout(() => { btn.textContent = label; }, 1800);
    });
  });
  $$('.cmd-field').forEach((f) => f.addEventListener('focus', () => f.select()));
})();

(function () {
  "use strict";

  var project = document.body.dataset.project;
  document.querySelectorAll(
    ".ecosystem-rail__links [data-project], .ecosystem-grid [data-project]"
  ).forEach(function (link) {
    if (link.dataset.project === project) link.setAttribute("aria-current", "page");
  });

  var rail = document.querySelector(".ecosystem-rail");
  var projectToggle = rail && rail.querySelector(".ecosystem-rail__brand");
  var projectMenu = rail && rail.querySelector(".ecosystem-rail__links");
  var jumps = rail && rail.querySelector(".ecosystem-rail__jumps");
  var moreWrap = rail && rail.querySelector(".ecosystem-rail__more");
  var moreBtn = rail && rail.querySelector(".ecosystem-rail__more-btn");
  var morePanel = rail && rail.querySelector(".ecosystem-rail__more-panel");

  function setSections(open) {
    if (!moreBtn || !morePanel) return;
    rail.classList.toggle("is-sections", open);
    moreBtn.setAttribute("aria-expanded", String(open));
    if (open) morePanel.removeAttribute("hidden");
    else morePanel.setAttribute("hidden", "");
  }
  function setProjectMenu(open) {
    if (!rail || !projectToggle || !projectMenu) return;
    rail.classList.toggle("is-open", open);
    projectToggle.setAttribute("aria-expanded", String(open));
    projectToggle.setAttribute("aria-label", (open ? "Close" : "Open") + " workshop projects");
    projectMenu.setAttribute("aria-hidden", String(!open));
    if (open) {
      projectMenu.removeAttribute("inert");
      setSections(false);
    } else projectMenu.setAttribute("inert", "");
  }
  /* Keep every section name whole. Whatever does not fit the bar moves into
     the menu, instead of being sliced at the edge of the row. */
  function fitJumps() {
    if (!rail || !jumps || !moreWrap || !moreBtn || !morePanel) return;
    var links = Array.prototype.slice.call(jumps.querySelectorAll("a"));
    links.forEach(function (a) { a.hidden = false; });
    setSections(false);
    morePanel.textContent = "";
    moreWrap.hidden = true;
    rail.classList.add("is-managed");
    if (jumps.scrollWidth <= jumps.clientWidth) return;
    moreWrap.hidden = false;
    moreBtn.textContent = "Sections";
    var hidden = [];
    function clip() {
      var box = jumps.getBoundingClientRect().right;
      for (var i = links.length - 1; i >= 0; i--) {
        if (links[i].hidden) continue;
        if (links[i].getBoundingClientRect().right <= box + 0.5) break;
        links[i].hidden = true;
        hidden.unshift(links[i]);
      }
    }
    for (var i = links.length - 1; i >= 0 && jumps.scrollWidth > jumps.clientWidth; i--) {
      links[i].hidden = true;
      hidden.unshift(links[i]);
    }
    clip();
    moreBtn.textContent = hidden.length === links.length ? "Sections" : "More";
    clip();
    hidden.forEach(function (a) {
      var item = a.cloneNode(true);
      item.hidden = false;
      morePanel.appendChild(item);
    });
  }
  if (jumps && moreBtn) {
    fitJumps();
    addEventListener("resize", fitJumps);
    if (document.fonts && document.fonts.ready) document.fonts.ready.then(fitJumps);
    moreBtn.addEventListener("click", function () {
      var open = moreBtn.getAttribute("aria-expanded") === "true";
      setSections(!open);
    });
    morePanel.addEventListener("click", function (event) {
      if (event.target.closest("a")) setSections(false);
    });
  }
  if (projectToggle && projectMenu) {
    projectToggle.addEventListener("click", function () {
      setProjectMenu(projectToggle.getAttribute("aria-expanded") !== "true");
    });
    document.addEventListener("keydown", function (event) {
      if (event.key !== "Escape") return;
      if (moreBtn && moreBtn.getAttribute("aria-expanded") === "true") {
        setSections(false);
        moreBtn.focus();
      } else if (projectToggle.getAttribute("aria-expanded") === "true") {
        setProjectMenu(false);
        projectToggle.focus();
      }
    });
    document.addEventListener("click", function (event) {
      if (projectToggle.getAttribute("aria-expanded") === "true" && !rail.contains(event.target)) {
        setProjectMenu(false);
      }
      if (moreBtn && moreBtn.getAttribute("aria-expanded") === "true" &&
          moreWrap && !moreWrap.contains(event.target)) {
        setSections(false);
      }
    });
  }

  var progress = document.querySelector(".ecosystem-progress span");
  var ticking = false;
  function updateProgress() {
    if (progress) {
      var available = document.documentElement.scrollHeight - innerHeight;
      var amount = available > 0 ? Math.min(1, scrollY / available) : 0;
      progress.style.transform = "scaleX(" + amount + ")";
    }
    ticking = false;
  }
  addEventListener("scroll", function () {
    if (!ticking) {
      requestAnimationFrame(updateProgress);
      ticking = true;
    }
  }, { passive: true });
  updateProgress();

  document.querySelectorAll(".ecosystem-card").forEach(function (card) {
    card.addEventListener("pointermove", function (event) {
      var box = card.getBoundingClientRect();
      card.style.setProperty("--mx", (event.clientX - box.left) + "px");
      card.style.setProperty("--my", (event.clientY - box.top) + "px");
    });
  });

  /* A link to a folded section opens it: the address names the section,
     and arriving at a closed one would show a heading and nothing else. */
  function openTarget() {
    var id = decodeURIComponent(location.hash.slice(1));
    var target = id && document.getElementById(id);
    var fold = target && target.closest("details");
    if (fold && !fold.open) {
      fold.open = true;
      target.scrollIntoView();
    }
  }
  addEventListener("hashchange", openTarget);
  openTarget();

  /* A conversation in the app's own voice. Play runs every turn in order:
     the heard line appears as it would be recognised, a short wait for the
     end of the thought, then the voice, each word lit by its measured
     timing. Each turn can be played again on its own. */
  document.querySelectorAll("[data-voice-demo]").forEach(function (demo) {
    var play = demo.querySelector(".voice-demo__play");
    var turns = Array.prototype.slice.call(demo.querySelectorAll(".voice-demo__turn"));
    var reduced = matchMedia("(prefers-reduced-motion: reduce)").matches;
    var audio = new Audio();
    audio.preload = "none";
    var run = 0;
    var frame = 0;

    function wait(ms, token) {
      return new Promise(function (resolve, reject) {
        setTimeout(function () { token === run ? resolve() : reject(); }, ms);
      });
    }
    function reveal(turn, token) {
      var text = turn.querySelector(".voice-demo__text");
      if (!text) return Promise.resolve();
      if (reduced) return wait(500, token);
      var words = text.textContent.split(" ");
      text.innerHTML = words.map(function (w) { return '<span class="is-pending">' + w + "</span>"; }).join(" ");
      var spans = text.querySelectorAll("span");
      return words.reduce(function (p, _, i) {
        return p.then(function () { spans[i].classList.remove("is-pending"); return wait(230, token); });
      }, Promise.resolve()).then(function () { return wait(700, token); });
    }
    function speak(turn, token) {
      var words = Array.prototype.slice.call(turn.querySelectorAll(".voice-demo__word"));
      return new Promise(function (resolve, reject) {
        audio.src = turn.getAttribute("data-audio");
        function paint() {
          if (token !== run) return;
          var t = audio.currentTime;
          words.forEach(function (w) {
            var start = parseFloat(w.getAttribute("data-start"));
            var end = parseFloat(w.getAttribute("data-end"));
            w.classList.toggle("is-now", t >= start && t < end + 0.05);
            w.classList.toggle("is-said", t >= end + 0.05);
          });
          frame = requestAnimationFrame(paint);
        }
        audio.onended = function () {
          cancelAnimationFrame(frame);
          words.forEach(function (w) { w.classList.remove("is-now"); w.classList.add("is-said"); });
          token === run ? resolve() : reject();
        };
        audio.onerror = function () { cancelAnimationFrame(frame); reject(); };
        audio.play().then(paint, reject);
      });
    }
    function reset() {
      demo.classList.remove("is-playing");
      turns.forEach(function (turn) {
        turn.classList.remove("is-current");
        turn.querySelectorAll(".voice-demo__word").forEach(function (w) { w.classList.remove("is-now", "is-said"); });
        var text = turn.querySelector(".voice-demo__text");
        if (text) text.textContent = text.textContent;
      });
      play.setAttribute("aria-pressed", "false");
      play.textContent = "Play the conversation";
    }
    function stop() {
      run += 1;
      audio.pause();
      cancelAnimationFrame(frame);
      reset();
    }
    function perform(list) {
      stop();
      var token = run;
      demo.classList.add("is-playing");
      play.setAttribute("aria-pressed", "true");
      play.textContent = "Stop";
      return list.reduce(function (p, turn) {
        return p.then(function () {
          turns.forEach(function (t) { t.classList.toggle("is-current", t === turn); });
          return reveal(turn, token).then(function () { return speak(turn, token); });
        }).then(function () { return wait(450, token); });
      }, Promise.resolve()).then(function () { if (token === run) reset(); }, function () {});
    }

    play.hidden = false;
    play.addEventListener("click", function () {
      play.getAttribute("aria-pressed") === "true" ? stop() : perform(turns);
    });
    turns.forEach(function (turn) {
      var again = turn.querySelector(".voice-demo__again");
      again.hidden = false;
      again.addEventListener("click", function () { perform([turn]); });
    });
  });

  /* On the hub the paw eases through every project's accent, since the hub
     belongs to all of them: each stop holds, then smoothsteps into the next.
     A project page keeps its own accent, which the stylesheet already gives
     --eco-glow, and reduced motion keeps the hub on its own. */
  if (!document.querySelector(".ecosystem-mark")) return;
  if (document.body.getAttribute("data-project") !== "tools-core") return;

  var glowStops = [
    [182, 154, 255], /* gateway */
    [255, 188, 82],  /* voice */
    [113, 229, 210], /* protoke */
    [154, 230, 110], /* preflight */
    [122, 167, 255], /* siphon */
    [231, 155, 216], /* auto-sort */
    [79, 208, 240],  /* interpreter */
    [255, 138, 184], /* companion */
    [255, 118, 95],  /* tools */
    [255, 216, 79],  /* polyglot */
    [232, 168, 120], /* voice-core */
    [110, 217, 160], /* speech-core */
    [185, 195, 208]  /* site-core */
  ];
  var glowDwell = 5200;
  var glowFrame = 0;
  var glowStarted = performance.now();
  var glowReduced = matchMedia("(prefers-reduced-motion: reduce)");

  function glowEase(value) {
    return value * value * (3 - 2 * value);
  }
  function paintGlow(now) {
    var count = glowStops.length;
    var cycle = glowDwell * count;
    /* The first frame's timestamp can be earlier than the clock we sampled
       when the script ran, and a negative remainder walks off the palette. */
    var elapsed = (typeof now === "number" ? now : glowStarted) - glowStarted;
    if (!(elapsed >= 0)) elapsed = 0;
    elapsed = elapsed % cycle;
    var index = Math.min(count - 1, Math.max(0, Math.floor(elapsed / glowDwell)));
    var next = (index + 1) % count;
    var along = (elapsed % glowDwell) / glowDwell;
    var t = along < 0.42 ? 0 : glowEase((along - 0.42) / 0.58);
    var from = glowStops[index];
    var to = glowStops[next];
    var channels = [0, 1, 2].map(function (i) {
      return Math.round(from[i] + (to[i] - from[i]) * t);
    });
    document.body.style.setProperty(
      "--eco-glow",
      "rgb(" + channels[0] + "," + channels[1] + "," + channels[2] + ")"
    );
  }
  function tickGlow(now) {
    if (document.hidden || glowReduced.matches) {
      glowFrame = 0;
      return;
    }
    paintGlow(now);
    glowFrame = requestAnimationFrame(tickGlow);
  }
  function startGlow() {
    if (glowReduced.matches) {
      document.body.style.removeProperty("--eco-glow");
      if (glowFrame) cancelAnimationFrame(glowFrame);
      glowFrame = 0;
      return;
    }
    if (!glowFrame) glowFrame = requestAnimationFrame(tickGlow);
  }
  addEventListener("visibilitychange", function () {
    if (!document.hidden) startGlow();
  });
  if (glowReduced.addEventListener) glowReduced.addEventListener("change", startGlow);
  else glowReduced.addListener(startGlow);
  startGlow();
})();

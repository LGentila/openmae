// OpenMaé website: plays the conversation demos (the Mac window, the capsule, the iPhone) and their pause button.
//
// Each demo runs its own clock, in tenths of a second, through the four states of a conversation as the app's
// demo mode plays them: rest, you speak, Maé thinks, Maé answers. The markup holds every element; this script only
// sets the state and the words. The demos are hidden from screen readers: their figure says in words what they show.
(() => {
  "use strict";

  const french = (document.documentElement.lang || "fr").startsWith("fr");

  // Words are split on plain spaces only: a non-breaking space keeps "noté !" or "10 h" in one word.
  const TEXT = french
    ? {
        question: "Maé, rappelle-moi d’appeler Camille demain matin à dix heures, pour parler du voyage.",
        misheard: "Mais,",
        answer: "C’est noté ! Demain à 10 h, je te rappelle d’appeler Camille. Tu veux que je note aussi les idées du voyage ?",
        who: { ecoute: "Toi", reflexion: "Maé réfléchit…", parle: "Maé" },
        label: { repos: "Parler", ecoute: "Terminer", reflexion: "Annuler", parle: "Interrompre" },
        status: { ecoute: "Je t’écoute…", reflexion: "Je réfléchis…", parle: "Maé répond" },
        action: { ecoute: ["Terminer", "⌥ Espace"], reflexion: ["Annuler", "esc"], parle: ["Interrompre", "esc"] },
        pause: "Mettre l’animation en pause",
        play: "Reprendre l’animation",
      }
    : {
        question: "Maé, remind me to call Camille tomorrow morning at ten, to talk about the trip.",
        misheard: "May,",
        answer: "Done! Tomorrow at 10 a.m., I’ll remind you to call Camille. Do you want me to note your trip ideas too?",
        who: { ecoute: "You", reflexion: "Maé is thinking…", parle: "Maé" },
        label: { repos: "Talk", ecoute: "Finish", reflexion: "Cancel", parle: "Interrupt" },
        status: { ecoute: "I’m listening…", reflexion: "I’m thinking…", parle: "Maé is answering" },
        action: { ecoute: ["Finish", "⌥ Space"], reflexion: ["Cancel", "esc"], parle: ["Interrupt", "esc"] },
        pause: "Pause the animation",
        play: "Play the animation",
      };

  const QUESTION = TEXT.question.split(" ");
  const ANSWER = TEXT.answer.split(" ");

  // The app's demo timing: rest 2.2 s, you 5.8 s, thinking 2 s, answer 8.8 s.
  const REST = 22;
  const LISTEN = 58;
  const THINK = 20;
  const SPEAK = 88;
  const LOOP = REST + LISTEN + THINK + SPEAK;

  /// What the conversation looks like `tick` tenths of a second into the loop.
  function frame(tick) {
    const t = tick % LOOP;
    if (t < REST) return { state: "repos", sentence: "", words: [], fresh: 0 };
    if (t < REST + LISTEN) {
      // As speech recognition gives them: nothing for the first second, then two more words about every 0.6 s,
      // the first one misheard until more of the sentence is heard.
      const seconds = (t - REST) / 10;
      if (seconds < 1) return { state: "ecoute", sentence: "q", words: [], fresh: 0 };
      const count = Math.min(QUESTION.length, 2 + 2 * Math.floor((seconds - 1) / 0.6));
      const words = QUESTION.slice(0, count);
      if (count <= 4) words[0] = TEXT.misheard;
      return { state: "ecoute", sentence: "q", words, fresh: 2 };
    }
    if (t < REST + LISTEN + THINK) return { state: "reflexion", sentence: "q", words: QUESTION, fresh: 0 };
    const count = Math.min(ANSWER.length, Math.floor((t - REST - LISTEN - THINK) / 3.5) + 1);
    return { state: "parle", sentence: "a", words: ANSWER.slice(0, count), fresh: 2, previous: TEXT.question };
  }

  /// Shows `words` in `box`, adding a span per new word so that only new words rise in.
  function showWords(box, memo, sentence, words, fresh) {
    if (memo.sentence !== sentence) {
      box.textContent = "";
      memo.spans = [];
      memo.sentence = sentence;
    }
    words.forEach((word, index) => {
      let span = memo.spans[index];
      if (!span) {
        span = document.createElement("span");
        span.className = "w";
        box.append(span);
        memo.spans[index] = span;
      }
      if (span.textContent !== word) span.textContent = word;
      span.classList.toggle("fresh", index >= words.length - fresh);
    });
    while (memo.spans.length > words.length) memo.spans.pop().remove();
  }

  /// The Mac window and the iPhone: orb, who speaks, the words, the main button.
  function conversationView(root) {
    const live = root.querySelector(".tx-live");
    const who = root.querySelector(".tx-who");
    const previous = root.querySelector(".tx-prev");
    const label = root.querySelector(".fake-label");
    const memo = {};
    let state = root.dataset.state;
    return (f) => {
      if (f.state !== state) {
        state = f.state;
        root.dataset.state = state;
        if (label) label.textContent = TEXT.label[state];
        if (who && TEXT.who[state]) who.textContent = TEXT.who[state];
      }
      if (previous && previous.textContent !== (f.previous || "")) previous.textContent = f.previous || "";
      // At rest the words stay hidden until the next turn starts, as the app does.
      if (f.state !== "repos") showWords(live, memo, f.sentence, f.words, f.fresh);
    };
  }

  /// The capsule: status, the end of the sentence on one line (five words at most), the action and its key.
  function capsuleView(root) {
    const status = root.querySelector(".cap-status");
    const words = root.querySelector(".cap-words");
    const action = root.querySelector(".cap-action");
    const key = root.querySelector(".cap-kbd");
    let state = root.dataset.state;
    let shown = "";
    return (f) => {
      if (f.state !== state) {
        state = f.state;
        root.dataset.state = state;
        if (TEXT.status[state]) {
          status.textContent = TEXT.status[state];
          action.textContent = TEXT.action[state][0];
          key.textContent = TEXT.action[state][1];
        }
      }
      if (f.state === "repos") return; // the capsule leaves with its last words
      const last = f.words.slice(-5);
      const text = last.join(" ") + (f.words.length > 5 ? "+" : "") + f.fresh;
      if (text === shown) return;
      shown = text;
      words.textContent = "";
      if (f.words.length > 5) {
        const gap = document.createElement("span");
        gap.className = "gap";
        gap.textContent = "…";
        words.append(gap);
      }
      last.forEach((word, index) => {
        const span = document.createElement("span");
        span.textContent = word;
        if (index >= last.length - f.fresh) span.className = "fresh";
        words.append(span);
      });
      // On a narrow capsule, the end of the sentence matters: drop words from the start until the line fits.
      while (words.scrollWidth > words.clientWidth && words.querySelectorAll("span:not(.gap)").length > 1) {
        words.querySelector("span:not(.gap)").remove();
        if (!words.querySelector(".gap")) {
          const gap = document.createElement("span");
          gap.className = "gap";
          gap.textContent = "…";
          words.prepend(gap);
        }
      }
    };
  }

  // Pages written in both languages (the pairing link, the missing page) show the visitor's language, with a
  // button for the other one. Without the script, both stay visible.
  const blocks = [...document.querySelectorAll("[data-lang-block]")];
  if (blocks.length > 1) {
    const preferred = ((navigator.languages && navigator.languages[0]) || navigator.language || "fr").toLowerCase();
    const show = (lang) => {
      blocks.forEach((block) => {
        block.hidden = block.dataset.langBlock !== lang;
      });
      document.documentElement.lang = lang;
    };
    document.querySelectorAll("[data-lang-switch]").forEach((button) => {
      button.hidden = false;
      button.addEventListener("click", () => show(button.dataset.langSwitch));
    });
    show(preferred.startsWith("fr") ? "fr" : "en");
  }

  const demos = [...document.querySelectorAll("[data-demo]")].map((root) => {
    const view = root.dataset.demo === "capsule" ? capsuleView(root) : conversationView(root);
    const demo = { root, view, tick: Number(root.dataset.start || 0), visible: true };
    view(frame(demo.tick));
    return demo;
  });
  if (demos.length === 0) return;

  let paused = false;
  try {
    paused = localStorage.getItem("openmae-demo-paused") === "1";
  } catch {
    // storage unavailable (private window, blocked site data): the demos simply play
  }

  const buttons = [...document.querySelectorAll(".demo-pause")];
  function applyPause() {
    document.body.classList.toggle("is-paused", paused);
    buttons.forEach((button) => {
      button.setAttribute("aria-pressed", String(paused));
      const text = button.querySelector(".demo-pause-label");
      if (text) text.textContent = paused ? TEXT.play : TEXT.pause;
    });
  }
  buttons.forEach((button) =>
    button.addEventListener("click", () => {
      paused = !paused;
      applyPause();
      try {
        localStorage.setItem("openmae-demo-paused", paused ? "1" : "0");
      } catch {
        // not remembered, still applied
      }
    }),
  );
  applyPause();

  // A demo out of sight neither ticks nor animates.
  if ("IntersectionObserver" in window) {
    const observer = new IntersectionObserver((entries) => {
      entries.forEach((entry) => {
        const demo = demos.find((d) => d.root === entry.target);
        if (!demo) return;
        demo.visible = entry.isIntersecting;
        demo.root.classList.toggle("is-offscreen", !entry.isIntersecting);
      });
    });
    demos.forEach((demo) => observer.observe(demo.root));
  }

  setInterval(() => {
    if (paused || document.hidden) return;
    demos.forEach((demo) => {
      if (!demo.visible) return;
      demo.tick += 1;
      demo.view(frame(demo.tick));
    });
  }, 100);
})();

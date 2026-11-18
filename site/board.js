// Plays Overseer's loop in the hero: a ticket is filed into To Do, an agent
// picks it up, opens a PR whose checks pass, and the ticket lands in Done.
(() => {
  const board = document.querySelector(".board");
  if (!board || matchMedia("(prefers-reduced-motion: reduce)").matches) return;

  const col = (name) => board.querySelector(`[data-col="${name}"] .cards`);
  const status = board.querySelector("[data-status]");

  const tickets = [
    ["Settings toggles clip at large text", "ios-app"],
    ["Add a share button to receipts", "web"],
    ["Retry failed uploads in the background", "api"],
    ["Show the build number in About", "mac-app"],
    ["Empty state for the inbox", "ios-app"],
  ];
  let next = 0;
  let number = 412;
  let visible = true;

  const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

  function say(text, tone) {
    status.textContent = text;
    if (tone) status.dataset.tone = tone;
    else delete status.dataset.tone;
  }

  function counts() {
    board.querySelectorAll(".column").forEach((c) => {
      c.querySelector(".count").textContent = c.querySelectorAll(".card").length;
    });
  }

  function move(card, to, meta) {
    card.classList.remove("new");
    void card.offsetWidth;
    card.classList.add("new");
    card.querySelector(".meta .right").innerHTML = meta;
    col(to).prepend(card);
    counts();
  }

  function trim(name, max) {
    const cards = col(name);
    while (cards.children.length > max) cards.lastElementChild.remove();
  }

  async function run() {
    const [title, repo] = tickets[next++ % tickets.length];
    const id = number++;
    const card = document.createElement("li");
    card.className = "card live";
    card.innerHTML = '<div class="id"></div><div class="title"></div><div class="meta"><span class="repo"></span><span class="right"></span></div>';
    card.querySelector(".id").textContent = `${repo} #${id}`;
    card.querySelector(".title").textContent = title;
    card.querySelector(".repo").textContent = repo;

    say("⌘N  Filed into To Do", "busy");
    move(card, "todo", "just now");

    await wait(2000);
    say("An agent picked it up", "busy");
    move(card, "progress", "agent");

    await wait(2600);
    say(`PR #${id + 1} opened`, "busy");
    move(card, "review", '<span class="checks" data-checks="running">Checks</span>');

    await wait(2000);
    card.querySelector(".checks").dataset.checks = "passed";
    say("Checks passed", "done");

    await wait(1800);
    say("Merged", "done");
    move(card, "done", "merged");
    card.classList.remove("live");
    trim("done", 3);
    counts();
  }

  new IntersectionObserver(([entry]) => (visible = entry.isIntersecting)).observe(board);

  (async () => {
    await wait(1200);
    for (;;) {
      while (!visible || document.hidden) await wait(500);
      await run();
      await wait(3500);
    }
  })();
})();

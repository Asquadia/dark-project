// NexusPlay frontend — vanilla JS. Calls the ALB endpoints (same-origin).
const $ = (id) => document.getElementById(id);
const LS_KEY = "nexusplay.player";
let player = null; // {id, name}
let roundTimer = null, countdownTimer = null, roundLeft = 0, score = 0, playing = false;

async function api(path, opts = {}) {
  const r = await fetch(path, { headers: { "Content-Type": "application/json" }, ...opts });
  if (!r.ok) throw new Error(`${path} -> ${r.status}`);
  return r.json();
}

function loadPlayer() {
  try { return JSON.parse(localStorage.getItem(LS_KEY)); } catch { return null; }
}
function savePlayer(p) { localStorage.setItem(LS_KEY, JSON.stringify(p)); }

async function join() {
  const name = $("name").value.trim() || ("player-" + Math.floor(Math.random() * 9999));
  let p = loadPlayer();
  const id = p ? p.id : Math.floor(Math.random() * 1e9);
  $("join-msg").textContent = "Joining…";
  try {
    await api("/players", { method: "POST", body: JSON.stringify({ id, name, level: 1 }) });
    const st = await api(`/game/state/${id}`);
    player = { id, name };
    savePlayer(player);
    $("join-panel").classList.add("hidden");
    $("game-panel").classList.remove("hidden");
    $("hud-name").textContent = name;
    $("hud-best").textContent = st.state.best;
    $("hud-level").textContent = st.state.level;
    $("join-msg").textContent = "";
    refreshLeaderboard();
  } catch (e) {
    $("join-msg").textContent = "Failed to join: " + e.message;
  }
}

function placeTarget() {
  const arena = $("arena");
  const t = $("target");
  const w = arena.clientWidth - 60, h = arena.clientHeight - 60;
  t.style.left = Math.floor(Math.random() * w) + "px";
  t.style.top = Math.floor(Math.random() * h) + "px";
}

function startRound() {
  if (playing) return;
  playing = true; score = 0; roundLeft = 10;
  $("hud-score").textContent = "0";
  $("hud-time").textContent = "10";
  $("arena-overlay").classList.add("hidden");
  $("target").classList.remove("hidden");
  $("game-msg").textContent = "";
  placeTarget();
  countdownTimer = setInterval(() => {
    roundLeft--; $("hud-time").textContent = roundLeft;
    if (roundLeft <= 0) endRound();
  }, 1000);
}

function hitTarget() {
  if (!playing) return;
  score++; $("hud-score").textContent = score;
  placeTarget();
}

async function endRound() {
  playing = false;
  clearInterval(countdownTimer);
  $("target").classList.add("hidden");
  $("arena-overlay").classList.remove("hidden");
  $("start-btn").textContent = "Play again";
  $("game-msg").textContent = `Round over — you scored ${score}. Submitting…`;
  try {
    const res = await api(`/game/move/${player.id}`, { method: "POST", body: JSON.stringify({ score, level: Math.max(1, score / 5 | 0) }) });
    $("hud-best").textContent = res.best;
    $("hud-level").textContent = res.level;
    $("game-msg").textContent = score >= res.best ? `New best: ${res.best}! 🎯` : `Best stays ${res.best}.`;
    refreshLeaderboard();
  } catch (e) {
    $("game-msg").textContent = "Submit failed: " + e.message;
  }
}

async function refreshLeaderboard() {
  try {
    const { leaderboard } = await api("/game/leaderboard");
    const tb = $("leaderboard").querySelector("tbody");
    tb.innerHTML = "";
    if (leaderboard.length === 0) {
      tb.innerHTML = '<tr><td colspan="4" style="color:var(--muted);text-align:center">No scores yet — be the first!</td></tr>';
      return;
    }
    leaderboard.forEach((row, i) => {
      const tr = document.createElement("tr");
      tr.innerHTML = `<td>${i + 1}</td><td>${escapeHtml(row.name)}</td><td>${row.best}</td><td>${row.level}</td>`;
      tb.appendChild(tr);
    });
  } catch (e) {
    /* leaderboard unavailable — non-fatal */
  }
}
function escapeHtml(s) { return String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c])); }

async function showVersion() {
  try { const v = await api("/version"); $("version").textContent = `game ${v.version} · ${v.build}`; }
  catch { $("version").textContent = ""; }
}

// wire up
$("join-btn").addEventListener("click", join);
$("name").addEventListener("keydown", (e) => { if (e.key === "Enter") join(); });
$("start-btn").addEventListener("click", startRound);
$("target").addEventListener("click", hitTarget);

// restore session if the player already joined before
const saved = loadPlayer();
if (saved) {
  $("name").value = saved.name;
}
refreshLeaderboard();
showVersion();
setInterval(refreshLeaderboard, 5000);
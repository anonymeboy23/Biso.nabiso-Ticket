/* Biso.nabiso-Ticket : fonctions communes à toutes les pages */
(function () {
  const cfg = window.BISO_CONFIG || {};
  const configured = !!(cfg.SUPABASE_URL && !String(cfg.SUPABASE_URL).startsWith("COLLEZ") &&
                        cfg.SUPABASE_ANON_KEY && !String(cfg.SUPABASE_ANON_KEY).startsWith("COLLEZ"));
  const libOk = !!(window.supabase && window.supabase.createClient);
  const sb = configured && libOk ? window.supabase.createClient(cfg.SUPABASE_URL, cfg.SUPABASE_ANON_KEY) : null;

  const App = { sb, cfg, configured, libOk, _me: undefined };
  window.App = App;

  // Rend le site installable sur téléphone (PWA). Les données Supabase restent
  // toujours synchronisées dès que la connexion revient.
  if ("serviceWorker" in navigator) {
    window.addEventListener("load", () => navigator.serviceWorker.register("/sw.js").catch(() => {}));
  }
  if (!document.querySelector('link[rel="manifest"]')) {
    const manifest = document.createElement("link");
    manifest.rel = "manifest";
    manifest.href = "/manifest.webmanifest";
    document.head.appendChild(manifest);
  }

  /* ---------- Petits outils ---------- */
  App.esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

  App.money = (n, cur) => {
    const v = Number(n || 0);
    try {
      return new Intl.NumberFormat("fr-FR", { style: "currency", currency: cur || "USD",
        maximumFractionDigits: cur === "CDF" ? 0 : 2 }).format(v);
    } catch (e) { return v + " " + (cur || ""); }
  };

  App.fmtDate = (d) => new Date(d).toLocaleString("fr-FR",
    { weekday: "long", day: "numeric", month: "long", hour: "2-digit", minute: "2-digit" });
  App.fmtShort = (d) => new Date(d).toLocaleString("fr-FR",
    { day: "2-digit", month: "short", year: "numeric", hour: "2-digit", minute: "2-digit" });
  App.dayParts = (d) => {
    const x = new Date(d);
    return { day: x.getDate(), mon: x.toLocaleString("fr-FR", { month: "short" }).replace(".", "") };
  };
  App.toLocalInput = (d) => {
    const x = new Date(d);
    x.setMinutes(x.getMinutes() - x.getTimezoneOffset());
    return x.toISOString().slice(0, 16);
  };
  App.fromLocalInput = (v) => new Date(v).toISOString();
  // Affiche les images d'affiche (attribut data-poster) sans risque d'injection.
  App.applyPosters = (root) => {
    (root || document).querySelectorAll("[data-poster]").forEach((el) => {
      const u = el.getAttribute("data-poster");
      if (u && /^https?:\/\//i.test(u)) el.style.backgroundImage = 'url("' + encodeURI(u) + '")';
    });
  };
  App.qs = (name) => new URLSearchParams(location.search).get(name);
  App.go = (url) => { location.href = url; };
  App.$ = (sel, root) => (root || document).querySelector(sel);
  App.$$ = (sel, root) => Array.from((root || document).querySelectorAll(sel));

  App.EVENT_STATUS = {
    brouillon: ["Brouillon", ""],
    en_attente: ["En attente de validation", "warn"],
    publie: ["Publié", "ok"],
    complet: ["Complet", "gold"],
    termine: ["Terminé", ""],
    annule: ["Annulé", "bad"],
  };
  App.statusChip = (s) => {
    const [label, cls] = App.EVENT_STATUS[s] || [s, ""];
    return `<span class="chip ${cls}">${App.esc(label)}</span>`;
  };

  App.homeFor = (role) => ({
    proprietaire: "admin.html", organisateur: "organisateur.html",
    personnel: "scan.html", client: "index.html" }[role] || "index.html");

  /* ---------- Messages d'erreur lisibles ---------- */
  const FRIENDLY = [
    [/invalid login credentials/i, "Email ou mot de passe incorrect."],
    [/user already registered/i, "Un compte existe déjà avec cet email. Connectez-vous."],
    [/email not confirmed/i, "Confirmez d'abord votre email (regardez votre boîte de réception)."],
    [/password should be at least/i, "Le mot de passe doit contenir au moins 8 caractères."],
    [/failed to fetch|networkerror|load failed/i, "Connexion impossible. Vérifiez votre réseau et réessayez."],
    [/row-level security|permission denied/i, "Vous n'avez pas le droit de faire cette action."],
    [/duplicate key/i, "Cet élément existe déjà."],
  ];
  App.friendly = (e) => {
    const raw = (e && e.message) ? e.message : String(e);
    for (const [re, msg] of FRIENDLY) if (re.test(raw)) return msg;
    return raw;
  };

  App.toast = (msg, kind) => {
    let box = document.getElementById("toasts");
    if (!box) { box = document.createElement("div"); box.id = "toasts"; document.body.appendChild(box); }
    const t = document.createElement("div");
    t.className = "toast " + (kind || "");
    t.setAttribute("role", kind === "error" ? "alert" : "status");
    t.textContent = msg;
    box.appendChild(t);
    setTimeout(() => t.remove(), 5000);
  };

  // Erreur : notification + annonce par l'assistant
  App.error = (e) => {
    const msg = App.friendly(e);
    console.error(e);
    App.toast(msg, "error");
    if (window.Bot && Bot.announce) Bot.announce(msg, "error");
  };

  /* ---------- Accès à la base ---------- */
  App.rpc = async (name, args) => {
    const { data, error } = await sb.rpc(name, args || {});
    if (error) throw new Error(error.message);
    return data;
  };
  App.q = async (query) => {
    const { data, error } = await query;
    if (error) throw new Error(error.message);
    return data;
  };
  // Exécute une action en bloquant le bouton pendant ce temps.
  App.run = async (btn, fn) => {
    if (btn) btn.disabled = true;
    try { return await fn(); }
    catch (e) { App.error(e); }
    finally { if (btn) btn.disabled = false; }
  };

  App.me = async (force) => {
    if (App._me !== undefined && !force) return App._me;
    if (!sb) return (App._me = null);
    const { data: { session }, error: sessionError } = await sb.auth.getSession();
    if (sessionError) throw sessionError;
    if (!session) return (App._me = null);
    const { data, error } = await sb.from("profiles").select("*").eq("id", session.user.id).maybeSingle();
    if (error) throw error;
    App._me = data || null;
    return App._me;
  };

  App.logout = async () => { await sb.auth.signOut(); App.go("index.html"); };

  /* ---------- Navigation ---------- */
  const LOGO = `<svg width="30" height="22" viewBox="0 0 30 22" aria-hidden="true"><path d="M3 0h24a3 3 0 0 1 3 3v4.5a3.5 3.5 0 0 0 0 7V19a3 3 0 0 1-3 3H3a3 3 0 0 1-3-3v-4.5a3.5 3.5 0 0 0 0-7V3a3 3 0 0 1 3-3z" fill="#ffc83d"/><path d="M10 3.5v15" stroke="#0a0f26" stroke-width="1.6" stroke-dasharray="2 2.4"/></svg>`;

  App.renderNav = (active, me) => {
    const el = document.getElementById("nav");
    if (!el) return;
    const a = (href, label, key) =>
      `<a href="${href}" class="${active === key ? "active" : ""}">${label}</a>`;
    let items = a("index.html", "Événements", "home");
    if (me) {
      items += a("mes-billets.html", "Mes billets", "tickets");
      items += a("aide.html", "Guide", "guide");
      if (me.role === "client") items += a("partenaire.html", "Devenir partenaire", "partner");
      if (me.role === "organisateur") items += a("organisateur.html", "Espace organisateur", "org");
      if (me.role === "personnel" || me.role === "proprietaire") items += a("scan.html", "Scanner", "scan");
      if (me.role === "proprietaire") items += a("admin.html", "Administration", "admin");
      const first = (me.full_name || "").split(" ")[0] || "compte";
      items += `<button type="button" id="logout-btn">Se déconnecter (${App.esc(first)})</button>`;
    } else {
      items += a("aide.html", "Guide", "guide") + a("partenaire.html", "Devenir partenaire", "partner") + a("connexion.html", "Connexion", "login");
    }
    el.innerHTML = `<header class="topbar"><div class="wrap">
      <a class="logo" href="index.html">${LOGO}<span>${App.esc(cfg.APP_NAME || "Biso.nabiso-Ticket")}</span></a>
      <button class="menu-btn" id="menu-btn" aria-expanded="false" aria-controls="main-nav">Menu</button>
      <nav class="nav" id="main-nav">${items}</nav></div></header>`;
    const nav = document.getElementById("main-nav");
    document.getElementById("menu-btn").onclick = (ev) => {
      const open = nav.classList.toggle("open");
      ev.currentTarget.setAttribute("aria-expanded", open);
    };
    const lo = document.getElementById("logout-btn");
    if (lo) lo.onclick = App.logout;
  };

  App.showBlock = (html) => {
    const main = document.getElementById("main") || document.body;
    main.innerHTML = `<div class="wrap page"><div class="panel">${html}</div></div>`;
  };

  /* ---------- Démarrage d'une page ----------
     App.start({ active, roles })  ->  { ok, me }
     roles : liste des rôles autorisés (null = page publique) */
  App.start = async (opts) => {
    const { active = "", roles = null } = opts || {};
    if (!libOk) {
      App.renderNav(active, null);
      App.showBlock("<h2>Bibliothèque introuvable</h2><p>Le site n'a pas pu charger Supabase. Vérifiez votre connexion internet puis rechargez la page.</p>");
      return { ok: false, me: null };
    }
    if (!configured) {
      App.renderNav(active, null);
      App.showBlock("<h2>Base de données non connectée</h2><p>Ouvrez le fichier <b>scripts/config.js</b> et collez votre <b>Project URL</b> et votre <b>clé publishable</b> Supabase.</p>");
      return { ok: false, me: null };
    }
    let me = null;
    try {
      me = await App.me();
    } catch (e) {
      App.error(e);
      App.showBlock("<h2>Impossible de vérifier votre compte</h2><p>La session est peut-être valide, mais le profil client est inaccessible. Vérifiez que le script <b>database/schema.sql</b> a été exécuté dans Supabase et que la connexion fonctionne, puis rechargez la page.</p>");
      return { ok: false, me: null };
    }
    App.renderNav(active, me);
    if (roles && me && me.role === "organisateur" && me.role_expires_at &&
        Date.parse(me.role_expires_at) <= Date.now()) {
      App.showBlock("<h2>Accès organisateur expiré</h2><p>Votre accès a expiré. Contactez Biso.nabiso-Ticket pour le renouveler. Vos données sont conservées.</p><a class='btn' href='index.html'>Retour à l'accueil</a>");
      return { ok: false, me };
    }
    if (roles) {
      if (!me) { App.go("connexion.html?next=" + encodeURIComponent(location.pathname.split("/").pop() + location.search)); return { ok: false, me }; }
      if (!roles.includes(me.role)) {
        App.showBlock("<h2>Accès refusé</h2><p>Cette page n'est pas disponible pour votre compte.</p><a class='btn' href='index.html'>Retour à l'accueil</a>");
        return { ok: false, me };
      }
    }
    if (window.Bot && Bot.init) Bot.init(me);
    return { ok: true, me };
  };
})();
